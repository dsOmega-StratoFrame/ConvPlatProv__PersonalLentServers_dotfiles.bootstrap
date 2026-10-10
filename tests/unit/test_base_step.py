"""Unit tests for the bootstrap_base prerequisites step's pure logic.

The CVE-2024-3094 guard is the branch here that is easy to get subtly wrong
(version matching), so its contract is asserted without Ansible.
"""
from __future__ import annotations

from pathlib import Path

import pytest
import yaml
from jinja2 import Template

REPO = Path(__file__).resolve().parents[2]
ROLE = REPO / "roles" / "bootstrap_base"
DEFAULTS_PATH = ROLE / "defaults" / "main.yml"
TASKS_PATH = ROLE / "tasks" / "dependencies.yml"
MIRROR_TASKS_PATH = ROLE / "tasks" / "apt_mirror.yml"
MAIN_TASKS_PATH = ROLE / "tasks" / "main.yml"

# Mirrors the `when:` expression in roles/bootstrap_base/tasks/dependencies.yml.
BLOCKED_EXPR = "{{ blocked | select('in', stdout) | list | length > 0 }}"


@pytest.fixture(scope="module")
def defaults() -> dict:
    return yaml.safe_load(DEFAULTS_PATH.read_text())


def test_required_commands_cover_nix_prerequisites(defaults):
    assert {"curl", "xz"} <= set(defaults["bootstrap_base_required_commands"])


def test_blocked_versions_cover_cve_2024_3094(defaults):
    blocked = {str(v) for v in defaults["bootstrap_base_xz_blocked_versions"]}
    assert {"5.6.0", "5.6.1"} <= blocked


def _find_task(tasks: list, needle: str) -> dict:
    for task in tasks:
        if needle in (task.get("name") or ""):
            return task
    raise AssertionError(f"no task containing {needle!r}")


def test_apt_install_is_gated_on_pkg_mgr_not_os_family():
    # TOS 6 reports os_family=OtherLinux but pkg_mgr=apt.
    tasks = yaml.safe_load(TASKS_PATH.read_text())
    apt = _find_task(tasks, "Install base packages (apt)")
    assert "ansible_facts['pkg_mgr'] == 'apt'" in apt["when"]
    generic = _find_task(tasks, "Install base packages (generic)")
    assert "ansible_facts['pkg_mgr'] != 'apt'" in generic["when"]


def test_fail_path_rechecks_after_the_install_attempt():
    """The old fail task fired on the pre-install snapshot even when the generic
    install had succeeded; it must now key on the post-install recheck."""
    tasks = yaml.safe_load(TASKS_PATH.read_text())
    assert any(
        "Re-detect required commands" in (task.get("name") or "") for task in tasks
    ), "missing post-install re-detect task"
    fail = _find_task(tasks, "Fail when prerequisites are still missing")
    assert any(
        "bootstrap_base_still_missing_commands" in cond for cond in fail["when"]
    )


def test_still_missing_tolerates_skipped_loop_results():
    """A skipped loop task registers per-item results that have no `rc`; the
    expression must filter those out, not raise 'object of type dict has no
    attribute rc' (hit when nothing was missing, so the re-detect was skipped)."""
    tasks = yaml.safe_load(TASKS_PATH.read_text())
    task = _find_task(tasks, "Record commands still missing")
    expr = task["ansible.builtin.set_fact"]["bootstrap_base_still_missing_commands"]

    skipped = {
        "results": [
            {"item": "curl", "skipped": True},
            {"item": "xz", "skipped": True},
        ]
    }
    assert Template(expr).render(bootstrap_base_command_rechecks=skipped).strip() == "[]"

    still_missing = {"results": [{"item": "curl", "rc": 0}, {"item": "xz", "rc": 1}]}
    rendered = Template(expr).render(bootstrap_base_command_rechecks=still_missing)
    assert "'xz'" in rendered
    assert "curl" not in rendered

    # No loop results at all (whole task skipped).
    assert Template(expr).render(bootstrap_base_command_rechecks={"skipped": True}).strip() == "[]"


def test_command_detection_goes_through_a_shell():
    """`command` is a shell builtin; ansible.builtin.command does not invoke a
    shell, so `command -v X` returned rc 2 for every X and every required command
    looked missing. Detection must use the shell module."""
    tasks = yaml.safe_load(TASKS_PATH.read_text())
    for name in ("Detect required commands", "Re-detect required commands"):
        task = _find_task(tasks, name)
        assert "ansible.builtin.shell" in task, f"{name!r} must use the shell module"
        assert "ansible.builtin.command" not in task


def test_apt_mirror_is_toggleable_and_off_by_default(defaults):
    # Opt-in: no source rewriting unless a host enables it.
    assert defaults["bootstrap_base_apt_mirror_enabled"] is False
    assert defaults["bootstrap_base_apt_mirror_suite"] == ""
    assert defaults["bootstrap_base_apt_mirror_candidates"] == []


def test_main_configures_the_apt_mirror_before_installing():
    tasks = yaml.safe_load(MAIN_TASKS_PATH.read_text())
    imports = [t.get("ansible.builtin.import_tasks") for t in tasks]
    assert "apt_mirror.yml" in imports
    assert imports.index("apt_mirror.yml") < imports.index("dependencies.yml")


def test_apt_mirror_probes_candidates_and_selects_first_reachable():
    tasks = yaml.safe_load(MIRROR_TASKS_PATH.read_text())
    probe = _find_task(tasks, "Probe candidate apt mirrors")
    uri = probe["ansible.builtin.uri"]
    assert uri["status_code"] == 200
    assert probe["loop"] == "{{ bootstrap_base_apt_mirror_candidates }}"
    assert probe["failed_when"] is False
    select = _find_task(tasks, "Select the first reachable mirror")
    expr = select["ansible.builtin.set_fact"]["bootstrap_base_apt_mirror"]
    assert "selectattr('status', 'equalto', 200)" in expr
    assert "| first" in expr


def test_apt_mirror_rewrites_only_ubuntu_hostnames():
    # Other sources (TOS's own repo, Docker) must be left untouched.
    text = MIRROR_TASKS_PATH.read_text()
    assert r"(archive|security|ports)\.ubuntu\.com/ubuntu" in text
    rewrite = _find_task(
        yaml.safe_load(text), "Repoint Ubuntu apt sources at the reachable mirror"
    )
    replace = rewrite["ansible.builtin.replace"]
    assert replace["backup"] is True
    assert "archive" in replace["regexp"]
    assert "ubuntu" in replace["regexp"]


def _is_blocked(stdout: str, blocked: list) -> bool:
    # The expression renders to the string "True"/"False"; a bare bool() of it is
    # always truthy, so compare explicitly.
    rendered = Template(BLOCKED_EXPR).render(blocked=blocked, stdout=stdout)
    return rendered.strip().lower() == "true"


@pytest.mark.parametrize(
    "stdout,vulnerable",
    [
        ("xz (XZ Utils) 5.2.5\nliblzma 5.2.5", False),  # Ubuntu 22.04 / TOS 6
        ("xz (XZ Utils) 5.4.5\nliblzma 5.4.5", False),  # Debian 5.6.1+really5.4.5
        ("xz (XZ Utils) 5.6.0\nliblzma 5.6.0", True),
        ("xz (XZ Utils) 5.6.1\nliblzma 5.6.1", True),
    ],
)
def test_blocked_matching(defaults, stdout, vulnerable):
    assert (
        _is_blocked(stdout, defaults["bootstrap_base_xz_blocked_versions"])
        is vulnerable
    )
