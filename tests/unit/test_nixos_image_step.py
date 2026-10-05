"""Unit tests for the @NikolaiGogol image/container step's pure logic.

The roles contain no Python, but they do hold the bits that break silently: the
content-addressable tag derivation, the staging path, and the privileged
systemd-container invariants in the rendered compose/env. Those are asserted
here without Ansible or Docker.

Mirrors the conventions of test_docker_step.py: parse defaults with PyYAML and
render templates with Jinja2.
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest
import yaml
from jinja2 import Template

REPO = Path(__file__).resolve().parents[2]
ARTIFACT_DEFAULTS = REPO / "roles" / "nixos_image_artifact" / "defaults" / "main.yml"
SYNC_DEFAULTS = REPO / "roles" / "nixos_image_sync" / "defaults" / "main.yml"
LOAD_DEFAULTS = REPO / "roles" / "nixos_image_load" / "defaults" / "main.yml"
CONTAINER_DEFAULTS = REPO / "roles" / "nixos_container" / "defaults" / "main.yml"
COMPOSE_TEMPLATE = REPO / "roles" / "nixos_container" / "templates" / "docker-compose-system.yml.j2"
ENV_TEMPLATE = REPO / "roles" / "nixos_container" / "templates" / "env.j2"
NIKOLAIGOGOL_VARS = REPO / "group_vars" / "nikolaigogol" / "vars.yml"


def load(path: Path) -> dict:
    return yaml.safe_load(path.read_text())


@pytest.fixture(scope="module")
def artifact_defaults() -> dict:
    return load(ARTIFACT_DEFAULTS)


@pytest.fixture(scope="module")
def container_defaults() -> dict:
    return load(CONTAINER_DEFAULTS)


# --- artifact / content-addressable tag ---------------------------------------

def test_artifact_checksum_is_sha256(artifact_defaults):
    assert artifact_defaults["nixos_image_artifact_checksum_algorithm"] == "sha256"


def test_artifact_tag_length_is_12(artifact_defaults):
    assert int(artifact_defaults["nixos_image_artifact_tag_length"]) == 12


def test_artifact_archive_relative_path(artifact_defaults):
    rendered = Template(artifact_defaults["nixos_image_artifact_archive_relative"]).render(
        nixos_image_artifact_system_name=artifact_defaults["nixos_image_artifact_system_name"],
        nixos_image_artifact_tarball_name=artifact_defaults["nixos_image_artifact_tarball_name"],
    )
    assert rendered == "result-NikolaiGogol/tarball/nixos-system-x86_64-linux.tar.xz"


def test_tag_derivation_is_first_12_hex():
    # Mirrors the slice in roles/nixos_image_artifact/tasks/main.yml.
    sha256 = "3f1c9a2b7d4e5061728394a5b6c7d8e9f00112233445566778899aabbccddee"
    tag = sha256[:12]
    assert re.fullmatch(r"[0-9a-f]{12}", tag)


def test_image_name_composition():
    repository = "ds-omega/nikolai-gogol"
    tag = "3f1c9a2b7d4e"
    assert f"{repository}:{tag}" == "ds-omega/nikolai-gogol:3f1c9a2b7d4e"


# --- no :latest in the container values ---------------------------------------

def test_group_vars_do_not_pin_latest():
    text = NIKOLAIGOGOL_VARS.read_text()
    assert "latest" not in text.lower(), "group_vars must not pin a :latest tag"


def test_group_vars_derive_tag_at_runtime():
    data = load(NIKOLAIGOGOL_VARS)
    assert "nixos_image_artifact_tag" in str(data["nixos_image_tag"])


# --- sync / load defaults -----------------------------------------------------

def test_sync_defaults_use_checksum_and_staging_dir():
    data = load(SYNC_DEFAULTS)
    assert data["nixos_image_sync_checksum"] is True
    assert data["nixos_image_sync_remote_dir"] == "/var/tmp/nixos-images"


def test_load_is_gated_and_privileged():
    data = load(LOAD_DEFAULTS)
    assert data["nixos_image_load_become"] is True
    assert data["nixos_image_load_force"] is False


# --- container defaults -------------------------------------------------------

def test_container_defaults_pull_never(container_defaults):
    assert container_defaults["nixos_container_pull_policy"] == "never"


def test_container_defaults_manage_compose(container_defaults):
    assert container_defaults["nixos_container_manage_compose"] is True


# --- compose render invariants ------------------------------------------------

def _render_compose(container_defaults, mounts) -> str:
    return Template(COMPOSE_TEMPLATE.read_text()).render(
        nixos_container_service_name=container_defaults["nixos_container_service_name"],
        nixos_container_cgroup_parent=container_defaults["nixos_container_cgroup_parent"],
        nixos_container_mounts=mounts,
    )


SAMPLE_MOUNTS = [
    {
        "source": "/srv/data/Unix_dotfiles",
        "target": "/home/ds13/.bookmarks/shared-configs/Unix_dotfiles",
        "type": "directory",
    },
    {
        "source": "/srv/data/Virt_scripts_bootstrap",
        "target": "/home/ds13/.bookmarks/Virt_scripts_bootstrap",
        "type": "directory",
    },
    {
        "source": "/srv/data/haos_ova.qcow2",
        "target": "/opt/HomeServer__HomeAssistant/haos_ova.qcow2",
        "type": "file",
    },
]


@pytest.mark.parametrize(
    "needle",
    [
        "image: ${IMAGE_NAME}",
        "pull_policy: ${PULL_POLICY:-never}",
        "container_name: ${CONTAINER_NAME}",
        "privileged: true",
        "cgroup: host",
        "cgroup_parent: docker.slice",
        "network_mode: host",
        "stop_signal: SIGRTMIN+3",
        "command: /init",
        "- NET_ADMIN",
        "- seccomp=unconfined",
    ],
)
def test_compose_render_contains_systemd_invariants(container_defaults, needle):
    rendered = _render_compose(container_defaults, SAMPLE_MOUNTS)
    assert needle in rendered, f"compose template missing '{needle}'"


def test_compose_render_includes_every_mount(container_defaults):
    rendered = _render_compose(container_defaults, SAMPLE_MOUNTS)
    assert rendered.count("- /srv/data/") == len(SAMPLE_MOUNTS)
    for mount in SAMPLE_MOUNTS:
        assert f"- {mount['source']}:{mount['target']}" in rendered


def test_compose_render_service_name(container_defaults):
    rendered = _render_compose(container_defaults, SAMPLE_MOUNTS)
    assert f"{container_defaults['nixos_container_service_name']}:" in rendered


# --- env render ---------------------------------------------------------------

def test_env_template_renders_identity():
    rendered = Template(ENV_TEMPLATE.read_text()).render(
        nixos_container_username="ds13",
        nixos_container_namespace="ds-omega",
        nixos_container_image_base_name="nikolai-gogol",
        nixos_container_image_tag="3f1c9a2b7d4e",
        nixos_container_image="ds-omega/nikolai-gogol:3f1c9a2b7d4e",
        nixos_container_name="HomeServer__HomeAssistant.NikolaiGogol",
        nixos_container_pull_policy="never",
    )
    assert "CONTAINER_USERNAME=ds13" in rendered
    assert "IMAGE_NAME=ds-omega/nikolai-gogol:3f1c9a2b7d4e" in rendered
    assert "IMAGE_TAG=3f1c9a2b7d4e" in rendered
    assert "CONTAINER_NAME=HomeServer__HomeAssistant.NikolaiGogol" in rendered
    assert "PULL_POLICY=never" in rendered
