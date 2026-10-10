"""Unit tests for the bootstrap_nix step's installer handling.

Two bugs this guards against:

1. ``default(omit, true)`` does not drop a key from ``include_role: vars``.
   Ansible only strips the ``omit`` placeholder from module *arguments*, so
   inside a role var it rendered to an empty string instead. An empty
   ``bootstrap_nix_version`` therefore overrode the pinned ``danielrolls.nix``
   role's own default and built the installer URL
   ``https://releases.nixos.org/nix/nix-/nix--x86_64-linux.tar.xz`` (HTTP 404).
   The optional overrides must be gated host facts, not ``include_role`` vars.

2. TOS 6 ships its own Go-based ``install`` at ``/usr/sbin/install`` that shadows
   GNU coreutils' ``/usr/bin/install`` in PATH. The Nix installer creates its
   directory structure with ``install -dv -m 0755 ...`` and dies with
   "flag provided but not defined: -dv". The role must run the pinned role with
   a shim directory resolving ``install`` to GNU coreutils prepended to PATH.
"""
from __future__ import annotations

from pathlib import Path

import pytest
import yaml
from jinja2 import Template

REPO = Path(__file__).resolve().parents[2]
ROLE = REPO / "roles" / "bootstrap_nix"
TASKS_PATH = ROLE / "tasks" / "main.yml"
DEFAULTS_PATH = ROLE / "defaults" / "main.yml"

# Variables the wrapper only passes on when the operator configures them.
OPTIONAL_FACTS = ("nix_version", "installer_checksum", "config")

# Mirrors .ansible/roles/danielrolls.nix/vars/main.yml. That directory is
# git-ignored (the role is fetched by `make install`), so the template is
# reproduced here rather than read from the checkout.
GALAXY_URL_TEMPLATE = (
    "https://releases.nixos.org/nix/nix-{{ nix_version }}/"
    "nix-{{ nix_version }}-{{ arch }}-linux.tar.xz"
)


def _tasks() -> list:
    return yaml.safe_load(TASKS_PATH.read_text())


def _defaults() -> dict:
    return yaml.safe_load(DEFAULTS_PATH.read_text())


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


def _find_task(tasks: list, needle: str) -> dict:
    for task in _iter_tasks(tasks):
        if needle in (task.get("name") or ""):
            return task
    raise AssertionError(f"no task containing {needle!r}")


def _find_block(tasks: list, needle: str) -> dict:
    for task in _iter_tasks(tasks):
        if needle in (task.get("name") or "") and "block" in task:
            return task
    raise AssertionError(f"no block containing {needle!r}")


def _include_role_task(tasks: list) -> dict:
    for task in _iter_tasks(tasks):
        role = task.get("ansible.builtin.include_role") or task.get("include_role")
        if role and role.get("name") == "danielrolls.nix":
            return task
    raise AssertionError("bootstrap_nix does not include danielrolls.nix")


def _include_role_vars(tasks: list) -> dict:
    return _include_role_task(tasks).get("vars") or {}


def test_optional_overrides_are_not_passed_as_role_vars():
    passed = _include_role_vars(_tasks())
    assert not (set(OPTIONAL_FACTS) & set(passed)), (
        "optional Nix overrides must not travel through include_role vars "
        f"(omit renders empty there): {sorted(passed)}"
    )


def test_include_role_still_passes_the_required_knobs():
    passed = _include_role_vars(_tasks())
    assert {"flakes", "remove_nix_directory", "nix_commands"} <= set(passed)


@pytest.mark.parametrize("fact", OPTIONAL_FACTS)
def test_optional_overrides_are_gated_set_facts(fact):
    setters = [
        task
        for task in _tasks()
        if fact in (task.get("ansible.builtin.set_fact") or {})
    ]
    assert setters, f"no set_fact task injects {fact}"
    assert "| length > 0" in setters[0]["when"], (
        f"{fact} override must be gated on a non-empty value"
    )


@pytest.mark.parametrize(
    "value,expected",
    [
        ("", False),
        ("2.34.7", True),
    ],
)
def test_version_gate_only_fires_for_a_real_value(value, expected):
    when = _find_task(_tasks(), "Pin the Nix version")["when"]
    rendered = Template("{{ " + when + " }}").render(
        bootstrap_nix_version=value
    ).strip().lower()
    assert (rendered == "true") is expected


def test_empty_version_is_what_broke_the_url():
    broken = Template(GALAXY_URL_TEMPLATE).render(nix_version="", arch="x86_64")
    assert broken == (
        "https://releases.nixos.org/nix/nix-/nix--x86_64-linux.tar.xz"
    )

    # Deferring to the pinned role's default yields a real, fetchable path.
    good = Template(GALAXY_URL_TEMPLATE).render(
        nix_version="2.34.7", arch="x86_64"
    )
    assert good == (
        "https://releases.nixos.org/nix/nix-2.34.7/"
        "nix-2.34.7-x86_64-linux.tar.xz"
    )


def test_empty_version_defers_to_the_role_default():
    # Defaults must stay empty so the gate above skips and danielrolls.nix's
    # own pinned version applies.
    defaults = _defaults()
    assert defaults["bootstrap_nix_version"] == ""
    assert defaults["bootstrap_nix_installer_checksum"] == ""


def test_gnu_install_shim_defaults():
    defaults = _defaults()
    assert defaults["bootstrap_nix_gnu_install_path"] == "/usr/bin/install"
    shim_dir = defaults["bootstrap_nix_install_shim_dir"]
    assert shim_dir.startswith("/")
    # Must NOT be a directory that is already on PATH: the shim is only ever
    # prepended for the install run, never installed system-wide.
    assert shim_dir not in (
        "/usr/local/sbin",
        "/usr/local/bin",
        "/usr/sbin",
        "/usr/bin",
        "/sbin",
        "/bin",
    )


def test_install_block_prepends_the_shim_to_path():
    block = _find_block(_tasks(), "Install Nix (multi-user, systemd)")
    path = block["environment"]["PATH"]
    assert path.startswith("{{ bootstrap_nix_install_shim_dir }}:"), (
        "the shim must be first on PATH so it wins over TOS's /usr/sbin/install"
    )
    # Keep the host's existing PATH after the shim.
    assert "ansible_facts['env']['PATH']" in path


def test_install_block_gates_on_a_needed_install():
    block = _find_block(_tasks(), "Install Nix (multi-user, systemd)")
    assert "bootstrap_nix_command.rc != 0" in block["when"]
    assert "bootstrap_nix_force_reinstall" in block["when"]


def test_install_block_guards_and_wires_gnu_install():
    inner = _find_block(_tasks(), "Install Nix (multi-user, systemd)")["block"]

    probe = _find_task(inner, "Check for a GNU coreutils install")
    assert (
        probe["ansible.builtin.command"]
        == "{{ bootstrap_nix_gnu_install_path }} --version"
    )
    assert probe["failed_when"] is False

    check = _find_task(inner, "Fail early when GNU install is unavailable")
    conditions = " ".join(check["ansible.builtin.assert"]["that"])
    assert "GNU coreutils" in conditions

    link = _find_task(inner, "Resolve `install` to GNU coreutils")
    file_args = link["ansible.builtin.file"]
    assert file_args["state"] == "link"
    assert file_args["src"] == "{{ bootstrap_nix_gnu_install_path }}"
    assert file_args["dest"] == "{{ bootstrap_nix_install_shim_dir }}/install"


def test_include_role_runs_inside_the_shim_block():
    """The pinned role must inherit the block's environment (PATH), so the
    include_role has to be nested in the block, not a sibling."""
    block = _find_block(_tasks(), "Install Nix (multi-user, systemd)")
    assert _include_role_task(_tasks()) in block["block"]
