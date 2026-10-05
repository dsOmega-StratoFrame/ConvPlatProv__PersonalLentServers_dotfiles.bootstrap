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
