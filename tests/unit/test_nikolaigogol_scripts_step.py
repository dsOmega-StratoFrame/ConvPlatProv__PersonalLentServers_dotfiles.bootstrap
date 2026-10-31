"""Unit tests for the `nikolaigogol_scripts` Phase-0 debug step.

The role is a debug surface, not a deployment dependency: it rsyncs the upstream
@NikolaiGogol checkout into `_scripts` on @terra and renders a standalone `.env`.
These tests parse the role/playbook YAML directly (no Ansible), mirroring
test_nixos_image_step.py and test_repo_structure.py.
"""
from __future__ import annotations

from pathlib import Path

import pytest
import yaml
from jinja2 import Template

REPO = Path(__file__).resolve().parents[2]
ROLE = REPO / "roles" / "nikolaigogol_scripts"
DEFAULTS = ROLE / "defaults" / "main.yml"
TASKS = ROLE / "tasks" / "main.yml"
ENV_TEMPLATE = ROLE / "templates" / "env.j2"
PLAYBOOK = REPO / "deploy-nikolaigogol.yml"
MAKEFILE = REPO / "Makefile.NixosScripts"

ENV_KEYS = (
    "PROJECT_NAME",
    "SYSTEM_NAME",
    "BOOKMARKS",
    "UNIX_DOTFILES",
    "VIRT_SCRIPTS_BOOTSTRAP",
    "HOME_ASSISTANT_IMAGE",
    "CONTAINER_USERNAME",
    "NAMESPACE",
    "IMAGE_BASE_NAME",
    "IMAGE_TAG",
    "IMAGE_NAME",
    "CONTAINER_NAME",
)


def load(path: Path):
    return yaml.safe_load(path.read_text())


def _iter_tasks(tasks: list):
    for task in tasks:
        yield task
        for key in ("block", "rescue", "always"):
            if key in task:
                yield from _iter_tasks(task[key])


def _find_task(tasks: list, needle: str) -> dict:
    for task in _iter_tasks(tasks):
        if needle in (task.get("name") or ""):
            return task
    raise AssertionError(f"no task containing {needle!r}")


@pytest.fixture(scope="module")
def defaults() -> dict:
    return load(DEFAULTS)


@pytest.fixture(scope="module")
def tasks() -> list:
    return load(TASKS)


@pytest.fixture(scope="module")
def deploy_play() -> dict:
    return load(PLAYBOOK)[0]


def _role_entry(play: dict) -> dict:
    for entry in play["roles"]:
        if isinstance(entry, dict) and entry.get("role") == "nikolaigogol_scripts":
            return entry
    raise AssertionError("deploy-nikolaigogol.yml does not enable nikolaigogol_scripts")


# --- role exists / interface --------------------------------------------------

def test_role_files_exist():
    for path in (DEFAULTS, TASKS, ENV_TEMPLATE):
        assert path.is_file(), f"missing {path.relative_to(REPO)}"


def test_role_vars_are_prefixed(defaults):
    assert defaults
    for key in defaults:
        assert key.startswith("nikolaigogol_scripts"), f"unprefixed role var: {key}"


def test_defaults_are_safe(defaults):
    assert defaults["nikolaigogol_scripts_enabled"] is True
    assert defaults["nikolaigogol_scripts_force"] is False
    assert defaults["nikolaigogol_scripts_source_dir"] == (
        "{{ lookup('env', 'HOME') }}/.bookmarks/shared-projects/ChronoIndex/2026/"
        "ConvPlatProv-HomeServer__HomeAssistant/@NikolaiGogol"
    )
    assert "@NikolaiGogol" in defaults["nikolaigogol_scripts_source_dir"]


def test_destination_is_the_absolute_scripts_dir(defaults):
    assert defaults["nikolaigogol_scripts_dir"] == (
        "{{ zterra_root }}/local-/Projects/@NikolaiGogol/_scripts"
    )
    rendered = Template(defaults["nikolaigogol_scripts_dir"]).render(
        zterra_root="/zterra"
    )
    assert rendered == "/zterra/local-/Projects/@NikolaiGogol/_scripts"


def test_excludes_cover_git_env_and_build_noise(defaults):
    excludes = defaults["nikolaigogol_scripts_rsync_excludes"]
    assert ".git" in excludes
    assert ".env" in excludes
    assert "result-*" in excludes
    assert "node_modules" in excludes
    assert ".yarn/cache" in excludes


# --- source validation --------------------------------------------------------

def test_source_is_asserted_with_actionable_message(tasks):
    check = _find_task(tasks, "Check the upstream scripts source")
    assert check["delegate_to"] == "localhost"
    assert check["become"] is False
    paths = check["loop"]
    assert "switch-nixos.sh" in " ".join(paths)
    assert "Makefile" in " ".join(paths)

    message = _find_task(tasks, "Assert the upstream scripts source")[
        "ansible.builtin.assert"
    ]["fail_msg"]
    assert "nikolaigogol_scripts_source_dir" in message


def test_deployment_dir_is_created_with_mode(tasks):
    task = _find_task(tasks, "Ensure the scripts deployment directory exists")
    assert task["ansible.builtin.file"]["state"] == "directory"
    assert task["ansible.builtin.file"]["mode"] == "0755"


# --- dirty-target guard -------------------------------------------------------

def test_manifest_is_read_and_written(tasks, defaults):
    assert "nikolaigogol_scripts_dir }}/.deploy-state" in TASKS.read_text()
    manifest = _find_task(tasks, "Record the deployment manifest")[
        "ansible.builtin.copy"
    ]
    assert manifest["dest"] == "{{ nikolaigogol_scripts_dir }}/.deploy-state"
    assert manifest["mode"] == "0600"
    for field in ("role:", "source:", "tree_sha256:", "deployed_at:", "files:"):
        assert field in manifest["content"], f"manifest missing {field!r}"


def test_force_guard_has_override(tasks, defaults):
    guard = _find_task(tasks, "Guard against overwriting local debug edits")
    conditions = " ".join(str(item) for item in guard["when"])
    assert "nikolaigogol_scripts_force" in conditions
    assert "deploy-state" in " ".join(
        str(task.get("ansible.builtin.stat", {}).get("path", ""))
        for task in _iter_tasks(tasks)
    )
    failed = _find_task(tasks, "Fail on a dirty target")["ansible.builtin.fail"]
    assert "-e nikolaigogol_scripts_force=true" in failed["msg"]


def test_guard_runs_before_rsync(tasks):
    names = [task.get("name", "") for task in _iter_tasks(tasks)]
    guard = next(i for i, name in enumerate(names) if "Guard against overwriting" in name)
    sync = next(i for i, name in enumerate(names) if "Sync the upstream scripts" in name)
    assert guard < sync


# --- rsync --------------------------------------------------------------------

def test_rsync_is_checksummed_and_never_deletes(tasks):
    sync = _find_task(tasks, "Sync the upstream scripts")["ansible.posix.synchronize"]
    assert sync["mode"] == "push"
    assert sync["archive"] is True
    assert sync["checksum"] is True
    assert sync["delete"] is False
    # synchronize needs a real list; the role passes the list var directly
    # (the same shape nixos_image_sync uses), never a stringified list.
    assert sync["rsync_opts"] == "{{ nikolaigogol_scripts_rsync_opts }}"


def test_rsync_opts_are_built_from_the_excludes(defaults):
    opts = defaults["nikolaigogol_scripts_rsync_opts"]
    assert "nikolaigogol_scripts_rsync_excludes" in opts
    assert "--exclude=" in opts
    assert "--omit-dir-times" in opts


# --- rendered .env ------------------------------------------------------------

def test_env_template_renders_every_key():
    text = ENV_TEMPLATE.read_text()
    for key in ENV_KEYS:
        assert f"{key}=" in text, f".env template missing {key}"


def test_env_template_static_values():
    text = ENV_TEMPLATE.read_text()
    assert "PROJECT_NAME=HomeServer__HomeAssistant" in text
    assert "SYSTEM_NAME=NikolaiGogol" in text
    assert "BOOKMARKS=/zterra" in text
    assert "NAMESPACE=ds-omega" in text
    assert "IMAGE_BASE_NAME=nikolai-gogol" in text
    assert "IMAGE_TAG=latest" in text
    assert "UNIX_DOTFILES={{ nixos_container_unix_dotfiles_dir }}" in text
    assert "VIRT_SCRIPTS_BOOTSTRAP={{ nixos_container_virt_scripts_dir }}" in text
    assert "HOME_ASSISTANT_IMAGE={{ nixos_container_home_assistant_image }}" in text
    assert "CONTAINER_USERNAME={{ nixos_container_username }}" in text
    assert "CONTAINER_NAME={{ nixos_container_name }}" in text


def test_env_template_derives_image_name_from_ansible_vars():
    text = ENV_TEMPLATE.read_text()
    rendered = Template(text).render(
        nixos_container_unix_dotfiles_dir="/data/Unix_dotfiles",
        nixos_container_virt_scripts_dir="/data/Virt_scripts_bootstrap",
        nixos_container_home_assistant_image="/data/haos.qcow2",
        nixos_container_username="ds13",
        nixos_container_name="HomeServer__HomeAssistant.NikolaiGogol",
        nixos_container_image_repository="ds-omega/nikolai-gogol",
    )
    lines = rendered.splitlines()
    assert "IMAGE_NAME=ds-omega/nikolai-gogol:latest" in lines
    # Derived from the existing image identity, not a duplicated literal.
    assert "{{ nixos_container_image_repository" in text


def test_env_is_rendered_0600(tasks):
    task = _find_task(tasks, "Render the edge .env")["ansible.builtin.template"]
    assert task["dest"] == "{{ nikolaigogol_scripts_dir }}/.env"
    assert task["mode"] == "0600"


# --- on-target verification ---------------------------------------------------

def test_verifies_every_shell_script(tasks):
    task = _find_task(tasks, "Syntax-check every deployed shell script")
    assert task["ansible.builtin.command"]["argv"][:2] == ["bash", "-n"]
    assert task["changed_when"] is False


def test_verifies_compose_and_make(tasks):
    compose = _find_task(tasks, "Validate the deployed compose file")
    assert "docker compose" in compose["ansible.builtin.command"]["cmd"]
    assert "config -q" in compose["ansible.builtin.command"]["cmd"]
    assert compose["changed_when"] is False

    make = _find_task(tasks, "Confirm the deployed Makefile")[
        "ansible.builtin.command"
    ]
    assert "make -n image-name" in make["cmd"]
    assert make["chdir"] == "{{ nikolaigogol_scripts_dir }}"


# --- playbook wiring ----------------------------------------------------------

def test_role_is_tagged_scripts_and_debug_only(deploy_play):
    tags = _role_entry(deploy_play)["tags"]
    assert "scripts" in tags
    assert "debug" in tags
    assert "container" not in tags


def test_no_other_role_picks_up_the_scripts_tag(deploy_play):
    for entry in deploy_play["roles"]:
        if entry.get("role") == "nikolaigogol_scripts":
            continue
        assert "scripts" not in entry.get("tags", [])


def test_role_order_is_after_nixos_container(deploy_play):
    names = [
        entry if isinstance(entry, str) else entry["role"]
        for entry in deploy_play["roles"]
    ]
    assert names.index("nikolaigogol_scripts") > names.index("nixos_container")


def test_no_bind_mount_or_compose_change_is_introduced():
    # The debug surface must not become a container dependency: no mount wiring
    # and no compose lifecycle management (the compose file is only validated).
    role_text = " ".join(p.read_text() for p in sorted(ROLE.rglob("*.yml"))).lower()
    assert "nixos_container_mounts" not in role_text
    assert "docker_compose_v2" not in role_text
    assert "community.docker" not in role_text


def test_makefile_step_matches_repo_convention():
    text = MAKEFILE.read_text()
    assert "STEP_TAGS := scripts" in text
    assert "PLAYBOOK := deploy-nikolaigogol.yml" in text
    assert "include Makefile.Steps" in text
