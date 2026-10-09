"""Unit tests for the access_sftp step's pure logic.

TOS 6's sshd_config points ``Subsystem sftp`` at
``/usr/lib/openssh/sftp-server``, but the package providing that binary is not
installed, so Ansible's sftp/scp transfer probes fail and it silently falls back
to the slow ``piped`` transfer. This step installs the package after SSH access
is established. The assertions below pin the package, the path, the apt-only
guard and the playbook ordering.
"""
from __future__ import annotations

from pathlib import Path

import pytest
import yaml

REPO = Path(__file__).resolve().parents[2]
PLAYBOOK = REPO / "HomeServer__HomeAssistant.yml"
DEFAULTS_PATH = REPO / "roles" / "access_sftp" / "defaults" / "main.yml"
TASKS_PATH = REPO / "roles" / "access_sftp" / "tasks" / "main.yml"


@pytest.fixture(scope="module")
def defaults() -> dict:
    return yaml.safe_load(DEFAULTS_PATH.read_text())


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


def test_defaults_are_namespaced(defaults):
    assert defaults
    for key in defaults:
        assert key.startswith("access_sftp"), f"un-namespaced var: {key}"


def test_defaults_pin_package_and_path(defaults):
    assert defaults["access_sftp_package"] == "openssh-sftp-server"
    assert defaults["access_sftp_server_path"] == "/usr/lib/openssh/sftp-server"
    assert defaults["access_sftp_apt_lists_partial"] == "/var/lib/apt/lists/partial"


def test_recreates_apt_lists_partial_before_install():
    # TOS 6 ships without /var/lib/apt/lists/partial, which makes the apt
    # module's update_cache abort; the directory must be recreated first.
    tasks = yaml.safe_load(TASKS_PATH.read_text())
    mkdir = _find_task(tasks, "Ensure the apt lists directory exists")
    file_args = mkdir["ansible.builtin.file"]
    assert file_args["path"] == "{{ access_sftp_apt_lists_partial }}"
    assert file_args["state"] == "directory"
    assert "ansible_facts['pkg_mgr'] == 'apt'" in mkdir["when"]
    assert "not access_sftp_server_stat.stat.exists" in mkdir["when"]

    names = [task.get("name") for task in tasks]
    assert names.index("Ensure the apt lists directory exists") < names.index(
        "Install the SSH SFTP server package"
    )


def test_installs_package_only_when_binary_missing():
    tasks = yaml.safe_load(TASKS_PATH.read_text())
    task = _find_task(tasks, "Install the SSH SFTP server package")
    apt = task["ansible.builtin.apt"]
    assert apt["name"] == "{{ access_sftp_package }}"
    assert apt["state"] == "present"
    assert "not access_sftp_server_stat.stat.exists" in task["when"]
    assert "ansible_facts['pkg_mgr'] == 'apt'" in task["when"]


def test_role_uses_ansible_facts_not_top_level_fact_vars():
    # INJECT_FACTS_AS_VARS is deprecated; TOS also reports os_family=OtherLinux,
    # so the gate is pkg_mgr, not os_family.
    text = TASKS_PATH.read_text()
    assert "ansible_os_family" not in text
    assert "ansible_pkg_mgr" not in text
    assert "ansible_facts['pkg_mgr']" in text


def test_binary_presence_is_checked_and_verified():
    tasks = yaml.safe_load(TASKS_PATH.read_text())
    check = _find_task(tasks, "Check whether the SSH SFTP server binary is present")
    assert check["ansible.builtin.stat"]["path"] == "{{ access_sftp_server_path }}"
    verify = _find_task(tasks, "Verify the SSH SFTP server binary is present")
    assert verify["ansible.builtin.stat"]["path"] == "{{ access_sftp_server_path }}"
    assert "not access_sftp_server_verify.stat.exists" in verify["failed_when"]


def test_playbook_runs_sftp_step_right_after_ssh_access():
    play = yaml.safe_load(PLAYBOOK.read_text())[0]
    names = [
        entry if isinstance(entry, str) else entry["role"]
        for entry in play["roles"]
    ]
    assert names.index("access_sftp") == names.index("access_ssh") + 1

    tags = {
        (entry if isinstance(entry, str) else entry["role"]): (
            [] if isinstance(entry, str) else entry.get("tags", [])
        )
        for entry in play["roles"]
    }
    assert "access" in tags["access_sftp"]
    assert "ssh" in tags["access_sftp"]
