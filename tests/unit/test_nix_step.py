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


def _installer_rescue_block(tasks: list) -> dict:
    """The block that directly wraps the danielrolls.nix include and has a
    rescue section."""
    for task in _iter_tasks(tasks):
        if "rescue" not in task:
            continue
        for child in task.get("block") or []:
            if not isinstance(child, dict):
                continue
            role = child.get("ansible.builtin.include_role") or child.get(
                "include_role"
            )
            if role and role.get("name") == "danielrolls.nix":
                return task
    raise AssertionError("danielrolls.nix is not wrapped in a block with rescue")


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


def test_install_block_uses_the_nix_env_path():
    block = _find_block(_tasks(), "Install Nix (multi-user, systemd)")
    assert block["environment"]["PATH"] == "{{ bootstrap_nix_env_path }}"


def test_nix_env_path_puts_shim_then_nix_profiles_first():
    """The shim must win over TOS's /usr/sbin/install, and the Nix profile bin
    dirs must be present so post-install `nix` resolves without a new login
    shell."""
    expr = _defaults()["bootstrap_nix_env_path"]
    rendered = Template(expr).render(
        bootstrap_nix_install_shim_dir="/shim",
        bootstrap_nix_profile_bin_dirs=[
            "/nix/var/nix/profiles/default/bin",
            "/home/terra/.nix-profile/bin",
            "/home/terra/.local/state/nix/profile/bin",
        ],
        ansible_facts={"env": {"PATH": "/usr/bin:/bin"}},
    )
    assert rendered == (
        "/shim:/nix/var/nix/profiles/default/bin:/home/terra/.nix-profile/bin:"
        "/home/terra/.local/state/nix/profile/bin:/usr/bin:/bin"
    )


def test_nix_profile_bin_dirs_cover_the_user_profile():
    dirs = _defaults()["bootstrap_nix_profile_bin_dirs"]
    joined = " ".join(dirs)
    # The successful run resolved nix at <home>/.nix-profile/bin/nix.
    assert "/nix/var/nix/profiles/default/bin" in dirs
    assert ".nix-profile/bin" in joined
    assert "ansible_facts['user_dir']" in joined


def test_verify_task_uses_the_nix_env_path():
    verify = _find_task(_tasks(), "Verify Nix is available")
    assert verify["environment"]["PATH"] == "{{ bootstrap_nix_env_path }}"


def test_install_block_gates_on_the_store_not_path():
    block = _find_block(_tasks(), "Install Nix (multi-user, systemd)")
    assert "bootstrap_nix_installed" in block["when"]
    assert "bootstrap_nix_force_reinstall" in block["when"]
    # A PATH probe is wrong in both directions (2026-10-11 incident).
    for task in _iter_tasks(_tasks()):
        for key in ("ansible.builtin.shell", "shell", "ansible.builtin.command", "command"):
            assert "command -v nix" not in str(task.get(key, ""))


def test_install_gate_counts_the_store():
    gate = _find_task(_tasks(), "Count the entries in the Nix store")
    assert gate["ansible.builtin.find"]["paths"] == "{{ bootstrap_nix_store_dir }}"
    assert gate["register"] == "bootstrap_nix_store_entries"
    fact = _find_task(_tasks(), "Decide whether the Nix store already exists")
    assert "bootstrap_nix_store_entries.matched" in (
        fact["ansible.builtin.set_fact"]["bootstrap_nix_installed"]
    )


def test_empty_store_behind_a_mount_fails_fast():
    guard = _find_task(
        _tasks(), "Fail-fast when an empty store is hidden behind a mount"
    )
    conditions = " ".join(guard["ansible.builtin.assert"]["that"])
    assert "bootstrap_nix_allow_empty_mount" in conditions
    assert "bootstrap_nix_expected_mount_check.rc" in conditions
    assert guard["when"] == "not bootstrap_nix_installed"
    assert _defaults()["bootstrap_nix_allow_empty_mount"] is False


def test_terra_points_the_empty_mount_gate_at_the_zterra_bind():
    terra = yaml.safe_load(
        (REPO / "group_vars" / "terra" / "vars.yml").read_text()
    )
    assert terra["bootstrap_nix_expected_mount_source"].endswith("/local-/nix")


def test_post_install_asserts_the_store_and_daemon():
    tasks = _tasks()
    assert _find_task(tasks, "Assert the Nix store is populated")
    assert _find_task(
        tasks, "Assert the nix-daemon service is installed, enabled and running"
    )
    unit = _find_task(tasks, "Stat the nix-daemon service unit")
    assert unit["ansible.builtin.stat"]["follow"] is True
    assert _defaults()["bootstrap_nix_assert_daemon"] is True


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
    assert _include_role_task(_tasks()) in list(_iter_tasks(block["block"]))


def test_installer_include_role_is_wrapped_in_a_rescue_block():
    block = _installer_rescue_block(_tasks())
    assert "rescue" in block
    assert any(
        (child.get("ansible.builtin.include_role") or child.get("include_role") or {}).get(
            "name"
        )
        == "danielrolls.nix"
        for child in block["block"]
    )


def test_rescue_discriminates_on_the_profile_binary():
    rescue = _installer_rescue_block(_tasks())["rescue"]

    stat = _find_task(rescue, "Stat the installed Nix profile binary")
    assert stat["ansible.builtin.stat"]["path"] == "{{ bootstrap_nix_profile_bin }}"
    assert stat["register"] == "bootstrap_nix_profile_bin_stat"

    fail = _find_task(rescue, "Fail when the installer really failed")
    assert "ansible_failed_result" in fail["ansible.builtin.fail"]["msg"]
    assert "not bootstrap_nix_profile_bin_stat.stat.exists" in fail["when"]

    assert _defaults()["bootstrap_nix_profile_bin"] == (
        "/nix/var/nix/profiles/default/bin/nix"
    )
    assert _defaults()["bootstrap_nix_profile_dir"] == (
        "/nix/var/nix/profiles/default"
    )


def test_rescue_chown_uses_uid_zero_and_the_resolved_gid():
    rescue = _installer_rescue_block(_tasks())["rescue"]
    chown = _find_task(rescue, "Fix ownership of /nix")
    command = chown["ansible.builtin.command"]
    argv = command["argv"]

    assert argv[:2] == ["chown", "-R"]
    assert argv[2] == "0:{{ bootstrap_nix_nixbld_gid }}"
    assert "bootstrap_nix_nixbld_gid" in argv[2]
    joined = " ".join(str(part) for part in argv)
    assert "root" not in joined
    assert "0:" in joined

    for forbidden in ("become", "become_user", "sudo"):
        assert forbidden not in chown
    assert "bootstrap_nix_current_owner" in chown["when"]
    assert chown["changed_when"] == chown["when"]


def test_rescue_resolves_nixbld_gid_from_getent():
    rescue = _installer_rescue_block(_tasks())["rescue"]

    resolve = _find_task(rescue, "Resolve the nixbld group id")
    assert resolve["ansible.builtin.command"]["argv"] == [
        "getent",
        "group",
        "nixbld",
    ]
    assert resolve["changed_when"] is False
    assert resolve["register"] == "bootstrap_nix_nixbld_group"

    parse = _find_task(rescue, "Parse the nixbld group id")
    expression = parse["ansible.builtin.set_fact"]["bootstrap_nix_nixbld_gid"]
    assert ".split(':')[2]" in expression

    numeric = _find_task(rescue, "Assert the nixbld group id is numeric")
    conditions = "\n".join(numeric["ansible.builtin.assert"]["that"])
    assert "is match" in conditions
    assert "30000" not in yaml.safe_dump(rescue)


def test_rescue_reconciles_nix_var_with_systemd_tmpfiles():
    rescue = _installer_rescue_block(_tasks())["rescue"]
    tmpfiles = _find_task(rescue, "systemd-tmpfiles")
    assert tmpfiles["ansible.builtin.command"]["argv"] == [
        "systemd-tmpfiles",
        "--create",
        "--prefix=/nix/var/nix",
    ]


def test_rescue_links_service_and_enables_socket_with_state_guards():
    rescue = _installer_rescue_block(_tasks())["rescue"]

    link = _find_task(rescue, "Link the nix-daemon service unit")
    link_argv = link["ansible.builtin.command"]["argv"]
    assert link_argv[:2] == ["systemctl", "link"]
    assert link_argv[2] == (
        "{{ bootstrap_nix_profile_dir }}/lib/systemd/system/nix-daemon.service"
    )
    assert "bootstrap_nix_rescue_service_enabled" in link["when"]
    assert "not in ['enabled', 'linked']" in link["when"]

    enable = _find_task(rescue, "Enable the nix-daemon socket unit")
    enable_argv = enable["ansible.builtin.command"]["argv"]
    assert enable_argv[:2] == ["systemctl", "enable"]
    assert enable_argv[2] == (
        "{{ bootstrap_nix_profile_dir }}/lib/systemd/system/nix-daemon.socket"
    )
    assert "bootstrap_nix_rescue_socket_enabled" in enable["when"]
    assert "!= 'enabled'" in enable["when"]

    reload_task = _find_task(rescue, "Reload systemd")
    assert reload_task["ansible.builtin.command"]["argv"] == [
        "systemctl",
        "daemon-reload",
    ]

    enable_now = _find_task(rescue, "Enable and start the nix-daemon socket")
    assert enable_now["ansible.builtin.command"]["argv"] == [
        "systemctl",
        "enable",
        "--now",
        "nix-daemon.socket",
    ]

    restart = _find_task(rescue, "Restart the nix-daemon service")
    assert restart["ansible.builtin.command"]["argv"] == [
        "systemctl",
        "restart",
        "nix-daemon.service",
    ]


def test_post_install_assert_accepts_linked_service_and_requires_socket():
    daemon = _find_task(
        _tasks(), "Assert the nix-daemon service is installed, enabled and running"
    )
    conditions = "\n".join(daemon["ansible.builtin.assert"]["that"])
    assert "'linked'" in conditions
    assert "bootstrap_nix_daemon_socket_enabled" in conditions
    assert "== 'enabled'" in conditions
    assert daemon["when"] == "bootstrap_nix_assert_daemon | bool"


def test_post_install_socket_probe_exists_and_is_required():
    probe = _find_task(_tasks(), "Read the nix-daemon socket enabled state")
    assert probe["ansible.builtin.command"] == "systemctl is-enabled nix-daemon.socket"
    assert probe["register"] == "bootstrap_nix_daemon_socket_enabled"
    assert probe["changed_when"] is False
    assert probe["failed_when"] is False

    daemon = _find_task(
        _tasks(), "Assert the nix-daemon service is installed, enabled and running"
    )
    conditions = "\n".join(daemon["ansible.builtin.assert"]["that"])
    assert "bootstrap_nix_daemon_socket_enabled.stdout | trim == 'enabled'" in (
        conditions
    )


def test_post_install_assert_requires_nix_store_ping_and_version():
    ping = _find_task(_tasks(), "Ping the Nix store through the profile binary")
    assert ping["ansible.builtin.command"]["argv"] == [
        "{{ bootstrap_nix_profile_bin }}",
        "store",
        "ping",
    ]
    assert ping["register"] == "bootstrap_nix_store_ping"

    version = _find_task(_tasks(), "Read the Nix version through the profile binary")
    assert version["ansible.builtin.command"]["argv"] == [
        "{{ bootstrap_nix_profile_bin }}",
        "--version",
    ]
    assert version["register"] == "bootstrap_nix_profile_version"

    smoke = _find_task(
        _tasks(), "Assert nix store ping and nix --version succeed"
    )
    conditions = "\n".join(smoke["ansible.builtin.assert"]["that"])
    assert "bootstrap_nix_store_ping.rc" in conditions
    assert "bootstrap_nix_profile_version.rc" in conditions
    assert "nix store ping" in (
        smoke["name"] + smoke["ansible.builtin.assert"]["fail_msg"]
    )


def test_post_install_asserts_the_expected_mount_device_when_configured():
    root = _find_task(_tasks(), "Read the device id of /nix")
    assert root["ansible.builtin.command"]["argv"] == [
        "stat",
        "-c",
        "%d",
        "{{ bootstrap_nix_root }}",
    ]
    source = _find_task(
        _tasks(), "Read the device id of the expected Nix mount source"
    )
    assert source["ansible.builtin.command"]["argv"][-1] == (
        "{{ bootstrap_nix_expected_mount_source }}"
    )
    check = _find_task(
        _tasks(), "Assert /nix and the expected mount source are on the same filesystem"
    )
    conditions = "\n".join(check["ansible.builtin.assert"]["that"])
    assert "bootstrap_nix_root_device.stdout" in conditions
    assert "bootstrap_nix_expected_mount_device.stdout" in conditions
    assert check["when"] == "bootstrap_nix_expected_mount_source | length > 0"
