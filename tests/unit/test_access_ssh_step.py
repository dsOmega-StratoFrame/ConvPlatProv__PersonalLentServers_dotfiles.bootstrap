"""Unit tests for the access_ssh step's connection-target logic.

Regression: the manual ``ssh`` checks run with ``delegate_to: localhost``, which
re-scopes the connection vars — ``ansible_host`` becomes ``localhost`` and
``ansible_port`` is dropped — unless they were explicitly set in the inventory.
The role must therefore read the *inventory* host's values from ``hostvars`` so
the checks target the same host Ansible actually connects to.
"""
from __future__ import annotations

from pathlib import Path

import pytest
import yaml

REPO = Path(__file__).resolve().parents[2]
DEFAULTS_PATH = REPO / "roles" / "access_ssh" / "defaults" / "main.yml"
TASKS_PATH = REPO / "roles" / "access_ssh" / "tasks" / "main.yml"


@pytest.fixture(scope="module")
def defaults() -> dict:
    return yaml.safe_load(DEFAULTS_PATH.read_text())


def test_defaults_are_namespaced(defaults):
    assert defaults
    for key in defaults:
        assert key.startswith("access_ssh"), f"un-namespaced var: {key}"


def test_connect_host_reads_inventory_hostvars(defaults):
    host = defaults["access_ssh_connect_host"]
    assert "hostvars[inventory_hostname].ansible_host" in host
    assert "default(inventory_hostname)" in host
    # A bare `ansible_host` is re-scoped to `localhost` by delegate_to.
    assert "{{ ansible_host" not in host


def test_connect_port_reads_inventory_hostvars(defaults):
    assert "hostvars[inventory_hostname].ansible_port" in defaults["access_ssh_connect_port"]


def test_port_arg_uses_connect_port(defaults):
    assert "access_ssh_connect_port" in defaults["access_ssh_port_arg"]


def test_ssh_checks_target_the_resolved_host():
    tasks = yaml.safe_load(TASKS_PATH.read_text())
    for needle in (
        "Check whether key-based SSH already works",
        "Verify SSH access via key",
    ):
        task = next(t for t in tasks if needle in (t.get("name") or ""))
        cmd = task["ansible.builtin.command"]["cmd"]
        assert "access_ssh_connect_host" in cmd
        assert "access_ssh_port_arg" in cmd
