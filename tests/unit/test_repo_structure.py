"""Structural invariants for the HomeServer bootstrap repository.

These tests parse the YAML directly and do not require Ansible, so they run in
any Python environment with pytest + PyYAML. They catch the refactor mistakes
that would otherwise only surface on a live run: dangling role references, roles
missing their interface, unpinned dependencies, unnamespaced variables and
secrets that are no longer ignored.

They cover both playbooks:

* ``HomeServer__HomeAssistant.yml`` — Layer 0 on ``@terra``.
* ``deploy-nikolaigogol.yml`` — Layer 1: the ``@NikolaiGogol`` NixOS system
  container on ``@terra``.
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest
import yaml

REPO = Path(__file__).resolve().parents[2]
PLAYBOOK = REPO / "HomeServer__HomeAssistant.yml"
DEPLOY_PLAYBOOK = REPO / "deploy-nikolaigogol.yml"
VERIFY_PLAYBOOK = REPO / "verify-terra.yml"
VERIFY_NIKOLAIGOGOL_PLAYBOOK = REPO / "verify-nikolaigogol.yml"
REQUIREMENTS = REPO / "requirements.yml"
ROLES_DIR = REPO / "roles"
TERRA_VARS = REPO / "group_vars" / "terra" / "vars.yml"
PREFLIGHT = "tasks/preflight_privilege_model.yml"
PRIVILEGED_ROLES = ("nixos_container", "nixos_edge_sync", "nixos_image_load")


def _iter_tasks(tasks):
    """Yield every task dict, descending into block/rescue/always."""
    if not isinstance(tasks, list):
        return
    for task in tasks:
        if not isinstance(task, dict):
            continue
        yield task
        for key in ("block", "rescue", "always"):
            if key in task:
                yield from _iter_tasks(task[key])


def load(path: Path):
    with path.open() as fh:
        return yaml.safe_load(fh)


def role_names(play: dict) -> list[str]:
    names = []
    for entry in play.get("roles", []):
        names.append(entry if isinstance(entry, str) else entry["role"])
    return names


def role_tags(play: dict) -> dict[str, list[str]]:
    tags: dict[str, list[str]] = {}
    for entry in play.get("roles", []):
        if isinstance(entry, str):
            tags[entry] = []
        else:
            tags[entry["role"]] = entry.get("tags", [])
    return tags


def assert_roles_valid(play: dict) -> None:
    """A referenced role must exist, expose its interface and namespace its vars."""
    names = role_names(play)
    assert names, "playbook declares no roles"
    for name in names:
        role_dir = ROLES_DIR / name
        assert role_dir.is_dir(), f"playbook references missing role '{name}'"
        assert (role_dir / "tasks" / "main.yml").is_file(), f"{name}: no tasks/main.yml"
        assert (role_dir / "defaults" / "main.yml").is_file(), f"{name}: no defaults/main.yml"

        defaults = load(role_dir / "defaults" / "main.yml") or {}
        assert defaults, f"{name}: defaults are empty"
        for key in defaults:
            assert key.startswith(name), (
                f"{name}: variable '{key}' is not namespaced with the role name"
            )


@pytest.fixture(scope="module")
def play() -> dict:
    return load(PLAYBOOK)[0]


@pytest.fixture(scope="module")
def deploy_play() -> dict:
    return load(DEPLOY_PLAYBOOK)[0]


def test_playbook_targets_terra(play):
    assert play["hosts"] == "terra"
    assert play["gather_facts"] is True


def test_backup_runs_first(play):
    assert role_names(play)[0] == "backup_tos"


def test_terra_does_not_escalate_to_unprivileged_root():
    """TOS 6's `root` account is uid 9999 (unprivileged) while `terra` is uid 0,
    so Ansible's default `become_user: root` would drop privileges (apt cannot
    create /var/lib/apt/lists; tar cannot read root-only paths). The SSH user is
    already root-equivalent, so become is off and any role that forces it must
    target `terra`, not `root`."""
    data = load(TERRA_VARS)
    assert data["ansible_become"] is False
    assert data["ansible_become_user"] == "terra"


def _preflight_imports(play: dict) -> list[dict]:
    out = []
    for task in play.get("pre_tasks") or []:
        if not isinstance(task, dict):
            continue
        if PREFLIGHT in (
            task.get("ansible.builtin.import_tasks"),
            task.get("import_tasks"),
        ):
            out.append(task)
    return out


def test_deployable_plays_preflight_the_privilege_model():
    """Both device-mutating plays must run the read-only privilege-model guard
    before any role, and it must survive `--tags` filtering (tag `always`)."""
    for playbook in (PLAYBOOK, DEPLOY_PLAYBOOK):
        play = load(playbook)[0]
        imports = _preflight_imports(play)
        assert imports, f"{playbook.name} does not import {PREFLIGHT}"
        for task in imports:
            assert "always" in (task.get("tags") or []), (
                f"{playbook.name}: {PREFLIGHT} import must be tagged 'always'"
            )


def test_preflight_asserts_root_equivalent_uid():
    tasks = list(_iter_tasks(load(REPO / PREFLIGHT)))
    assert tasks, "preflight declares no tasks"
    assert any(
        "ansible_facts['user_uid'] | int == 0"
        in (task.get("ansible.builtin.assert", {}).get("that") or [])
        for task in tasks
    ), "preflight does not assert a root-equivalent uid"


def test_privileged_roles_target_configured_become_user():
    """TOS 6's `root` is uid 9999 (unprivileged); roles that escalate must set
    `become_user` explicitly (to the configured uid-0 admin) instead of relying
    on Ansible's default of `root`."""
    for role in PRIVILEGED_ROLES:
        files = sorted(
            list((ROLES_DIR / role / "tasks").rglob("*.yml"))
            + list((ROLES_DIR / role / "handlers").rglob("*.yml"))
        )
        assert files, f"{role}: no task/handler files"
        for path in files:
            for task in _iter_tasks(load(path)):
                if "become" in task:
                    assert "become_user" in task, (
                        f"{path.relative_to(REPO)}: task {task.get('name')!r} "
                        f"sets become without become_user"
                    )


def test_referenced_roles_exist(play):
    for name in role_names(play):
        role_dir = ROLES_DIR / name
        assert role_dir.is_dir(), f"playbook references missing role '{name}'"
        assert (role_dir / "tasks" / "main.yml").is_file(), f"{name}: no tasks/main.yml"
        assert (role_dir / "defaults" / "main.yml").is_file(), f"{name}: no defaults/main.yml"


def test_role_variables_are_namespaced(play):
    for name in role_names(play):
        defaults = load(ROLES_DIR / name / "defaults" / "main.yml") or {}
        assert defaults, f"{name}: defaults are empty"
        for key in defaults:
            assert key.startswith(name), (
                f"{name}: variable '{key}' is not namespaced with the role name"
            )


def test_verify_playbook_targets_terra():
    assert load(VERIFY_PLAYBOOK)[0]["hosts"] == "terra"


def test_verify_nikolaigogol_targets_terra():
    assert load(VERIFY_NIKOLAIGOGOL_PLAYBOOK)[0]["hosts"] == "terra"


def test_deploy_nikolaigogol_targets_terra(deploy_play):
    assert deploy_play["hosts"] == "terra"
    assert deploy_play["gather_facts"] is True


def test_deploy_nikolaigogol_loads_container_vars(deploy_play):
    # The play targets @terra, so group_vars/nikolaigogol does not auto-load;
    # the file is pulled in explicitly and must stay a real interface.
    assert "group_vars/nikolaigogol/vars.yml" in deploy_play.get("vars_files", [])


def test_deploy_nikolaigogol_roles_valid(deploy_play):
    assert_roles_valid(deploy_play)


def test_deploy_nikolaigogol_role_order(deploy_play):
    assert role_names(deploy_play) == [
        "nixos_image_artifact",
        "nixos_image_sync",
        "nixos_image_load",
        "nixos_container",
        "nixos_edge_sync",
    ]


def test_deploy_nikolaigogol_role_tags(deploy_play):
    tags = role_tags(deploy_play)
    for name in ("nixos_image_artifact", "nixos_image_sync", "nixos_image_load"):
        assert "image" in tags[name], f"{name}: missing 'image' tag"
    assert "container" in tags["nixos_container"]
    assert "edge_sync" in tags["nixos_edge_sync"]


def test_roles_are_pinned_to_commits():
    req = load(REQUIREMENTS) or {}
    roles = req.get("roles") or []
    assert roles, "requirements.yml declares no roles"
    for role in roles:
        version = str(role.get("version", ""))
        assert re.fullmatch(r"[0-9a-f]{40}", version), (
            f"role '{role.get('name', role.get('src'))}' is not pinned to a full commit"
        )


def test_expected_collections_declared():
    req = load(REQUIREMENTS) or {}
    names = [
        c if isinstance(c, str) else c.get("name")
        for c in (req.get("collections") or [])
    ]
    assert "community.docker" in names
    assert "ansible.posix" in names


def test_secrets_are_git_ignored():
    ignored = (REPO / ".gitignore").read_text()
    for entry in (".vault_pass.py", "backups/"):
        assert entry in ignored, f"'{entry}' is not git-ignored"


def test_base_os_var_files_declare_packages():
    vars_dir = ROLES_DIR / "bootstrap_base" / "vars"
    files = sorted(vars_dir.glob("*.yml"))
    assert files, "bootstrap_base has no OS var files"
    assert (vars_dir / "default.yml").is_file(), "missing fallback default.yml"
    for path in files:
        data = load(path) or {}
        assert "bootstrap_base_packages" in data, f"{path.name} declares no packages"


def test_base_var_lookup_selects_by_pkg_mgr():
    """TOS 6 reports os_family=OtherLinux but pkg_mgr=apt, so the var lookup must
    offer a pkg_mgr-family file; otherwise it falls back to default.yml, whose
    `xz` package does not exist under apt."""
    text = (ROLES_DIR / "bootstrap_base" / "tasks" / "variables.yml").read_text()
    assert "{{ ansible_facts['pkg_mgr'] }}-family.yml" in text
    apt = load(ROLES_DIR / "bootstrap_base" / "vars" / "apt-family.yml")
    assert "xz-utils" in apt["bootstrap_base_packages"]


COMMAND_BUILTIN_VIA_COMMAND = re.compile(r"command:\s*['\"]?command -v")


def test_command_v_is_not_run_via_the_command_module():
    """`command` is a shell builtin and ansible.builtin.command does not invoke a
    shell, so `command -v X` fails with rc 2 for every X and makes every lookup
    report 'missing'. Such detection must use the shell module."""
    offenders = []
    paths = list(ROLES_DIR.rglob("*.yml")) + sorted(REPO.glob("*.yml"))
    for path in paths:
        for match in COMMAND_BUILTIN_VIA_COMMAND.finditer(path.read_text()):
            offenders.append(f"{path.relative_to(REPO)}: {match.group(0)!r}")
    assert not offenders, (
        "`command -v` must not run via ansible.builtin.command (use shell): "
        + ", ".join(offenders)
    )


OS_FAMILY_DEBIAN_GATE = re.compile(r"ansible_facts\['os_family'\]\s*[!=]=\s*'Debian'")


def test_roles_gate_package_management_on_pkg_mgr_not_os_family():
    """TOS 6 reports os_family=OtherLinux but pkg_mgr=apt, so every
    package-management guard must key on pkg_mgr, not os_family=='Debian'."""
    offenders = []
    for path in sorted(ROLES_DIR.rglob("*.yml")):
        for match in OS_FAMILY_DEBIAN_GATE.finditer(path.read_text()):
            offenders.append(f"{path.relative_to(REPO)}: {match.group(0)}")
    assert not offenders, (
        "os_family=='Debian' package gates found (use pkg_mgr=='apt'): "
        + ", ".join(offenders)
    )


def test_no_secrets_committed():
    suspicious = []
    for path in REPO.rglob("*"):
        if path.is_dir() or ".git" in path.parts:
            continue
        if path.name in {".vault_pass.py", ".vault_pass"}:
            continue
        if path.suffix in {".pem", ".key"}:
            suspicious.append(path)
    assert not suspicious, f"possible key material committed: {suspicious}"


TOP_LEVEL_FACT_RE = re.compile(
    r"\bansible_(os_family|distribution|distribution_major_version|"
    r"distribution_release|pkg_mgr|date_time|architecture|system|hostname|"
    r"fqdn|kernel|default_ipv4)\b"
)


def test_roles_use_ansible_facts_not_top_level_fact_vars():
    """INJECT_FACTS_AS_VARS is deprecated (removal announced for ansible-core
    2.24): roles must reference ansible_facts[...] / ansible_facts.* instead of
    top-level ansible_* fact vars."""
    offenders = []
    for path in sorted(ROLES_DIR.rglob("*.yml")):
        for match in TOP_LEVEL_FACT_RE.finditer(path.read_text()):
            offenders.append(f"{path.relative_to(REPO)}: {match.group(0)}")
    assert not offenders, (
        "top-level fact vars found (use ansible_facts[...]): " + ", ".join(offenders)
    )
