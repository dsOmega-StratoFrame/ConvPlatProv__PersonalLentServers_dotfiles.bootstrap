"""Unit tests for the Docker bootstrap step's pure logic.

The role has no Python, but it does compose an apt source line and choose
detection defaults. Those are exactly the bits that are hard to eyeball and easy
to break, so they are asserted here without Ansible.
"""
from __future__ import annotations

from pathlib import Path

import pytest
import yaml
from jinja2 import Template

REPO = Path(__file__).resolve().parents[2]
DEFAULTS_PATH = REPO / "roles" / "bootstrap_docker" / "defaults" / "main.yml"
TASKS_PATH = REPO / "roles" / "bootstrap_docker" / "tasks" / "main.yml"


@pytest.fixture(scope="module")
def defaults() -> dict:
    return yaml.safe_load(DEFAULTS_PATH.read_text())


def test_default_install_method_is_detect(defaults):
    assert defaults["bootstrap_docker_install_method"] == "detect"


def test_tos6_uses_ubuntu_2204_suite(defaults):
    # TOS 6 rootfs is Ubuntu-22.04-compatible -> jammy.
    assert defaults["bootstrap_docker_apt_suite"] == "jammy"
    assert defaults["bootstrap_docker_apt_arch"] == "amd64"
    assert defaults["bootstrap_docker_apt_channel"] == "stable"


def test_packages_cover_engine_cli_and_containerd(defaults):
    packages = set(defaults["bootstrap_docker_packages"])
    assert {"docker-ce", "docker-ce-cli", "containerd.io"} <= packages


def test_gpg_url_derives_from_base(defaults):
    # The default is a Jinja expression deriving the URL from the base repo.
    rendered = Template(defaults["bootstrap_docker_gpg_url"]).render(
        bootstrap_docker_apt_base_url=defaults["bootstrap_docker_apt_base_url"]
    )
    assert rendered == defaults["bootstrap_docker_apt_base_url"] + "/gpg"


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


def test_docker_repo_uses_deb822_not_deprecated_apt_repository():
    """Regression: ansible.builtin.apt_repository is deprecated in favour of
    deb822_repository (removal announced for ansible-core 2.25)."""
    tasks = yaml.safe_load(TASKS_PATH.read_text())
    task = _find_task(tasks, "Add the Docker apt repository")
    assert "ansible.builtin.apt_repository" not in task
    repo = task["ansible.builtin.deb822_repository"]
    assert repo["name"] == "docker"
    assert repo["types"] == "deb"
    assert repo["uris"] == "{{ bootstrap_docker_apt_base_url }}"
    assert repo["suites"] == "{{ bootstrap_docker_apt_suite }}"
    assert repo["components"] == "{{ bootstrap_docker_apt_channel }}"
    assert repo["architectures"] == "{{ bootstrap_docker_apt_arch }}"
    assert repo["signed_by"] == "{{ bootstrap_docker_gpg_path }}"
    assert repo["state"] == "present"


def test_apt_prereqs_include_python_debian():
    tasks = yaml.safe_load(TASKS_PATH.read_text())
    task = _find_task(tasks, "Ensure apt prerequisites")
    assert "python3-debian" in task["ansible.builtin.apt"]["name"]


def test_legacy_docker_list_is_removed():
    tasks = yaml.safe_load(TASKS_PATH.read_text())
    task = _find_task(tasks, "Remove the legacy Docker apt source")
    assert task["ansible.builtin.file"]["path"] == "/etc/apt/sources.list.d/docker.list"
    assert task["ansible.builtin.file"]["state"] == "absent"
