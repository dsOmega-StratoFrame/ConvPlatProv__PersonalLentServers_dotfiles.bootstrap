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
    assert defaults["bootstrap_docker_gpg_url"] == (
        defaults["bootstrap_docker_apt_base_url"] + "/gpg"
    )


def test_apt_repo_line_renders_correctly(defaults):
    template = (
        "deb [arch={{ arch }} signed-by={{ gpg }}] "
        "{{ base }} {{ suite }} {{ channel }}"
    )
    line = Template(template).render(
        arch=defaults["bootstrap_docker_apt_arch"],
        gpg=defaults["bootstrap_docker_gpg_path"],
        base=defaults["bootstrap_docker_apt_base_url"],
        suite=defaults["bootstrap_docker_apt_suite"],
        channel=defaults["bootstrap_docker_apt_channel"],
    )
    assert line == (
        "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] "
        "https://download.docker.com/linux/ubuntu jammy stable"
    )
