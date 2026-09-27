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
DEFAULTS_PATH = REPO / "roles" / "bootstrap_base" / "defaults" / "main.yml"

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


def _is_blocked(stdout: str, blocked: list) -> bool:
    return bool(Template(BLOCKED_EXPR).render(blocked=blocked, stdout=stdout))


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
