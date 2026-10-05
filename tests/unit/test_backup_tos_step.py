"""Unit tests for the TOS backup step's pure logic (ADR-TOS-BACKUP-001 R2).

The role is data-driven: the scope, excludes and secret handling live in
`defaults/main.yml` plus the rendered exclude-file task, so those contracts are
asserted without Ansible. Mirrors the conventions of `test_repo_structure.py`
(parse the role YAML directly) and renders the exclude template with plain
Jinja2.
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest
import yaml
from jinja2 import Template

REPO = Path(__file__).resolve().parents[2]
ROLE = REPO / "roles" / "backup_tos"
DEFAULTS_PATH = ROLE / "defaults" / "main.yml"
TASKS_PATH = ROLE / "tasks" / "main.yml"
PLAYBOOK = REPO / "HomeServer__HomeAssistant.yml"

MANIFEST_FIELDS = [
    "host",
    "timestamp",
    "uname",
    "remote_archive",
    "archive_sha256",
    "archive_bytes",
    "member_count",
    "integrity",
    "effective_paths",
    "effective_excludes",
    "tos_version",
    "one_file_system",
    "secret_archive",
    "postgres_port",
    "db_dumps",
    "sqlite_backups",
    "enable_state_count",
    "skipped_submounts",
    "restore_hint",
]


def load(path: Path):
    return yaml.safe_load(path.read_text())


@pytest.fixture(scope="module")
def defaults() -> dict:
    return load(DEFAULTS_PATH)


@pytest.fixture(scope="module")
def tasks() -> list:
    return load(TASKS_PATH)


@pytest.fixture(scope="module")
def tasks_text() -> str:
    return TASKS_PATH.read_text()


def _find_task(tasks: list, needle: str) -> dict:
    for task in tasks:
        if needle in (task.get("name") or ""):
            return task
    raise AssertionError(f"no task containing {needle!r}")


def _task_cmd(task: dict) -> str:
    for key in ("ansible.builtin.shell", "ansible.builtin.command"):
        if key in task:
            value = task[key]
            return value["cmd"] if isinstance(value, dict) else value
    raise AssertionError(f"task {task.get('name')!r} has no shell/command")


def _render_excludes(defaults: dict, include_secrets: bool, submounts=None) -> str:
    task = _find_task(load(TASKS_PATH), "Build the effective exclude file")
    content = task["ansible.builtin.copy"]["content"]
    return Template(content).render(
        backup_tos_vendor_excludes=defaults["backup_tos_vendor_excludes"],
        backup_tos_dead_excludes=defaults["backup_tos_dead_excludes"],
        backup_tos_postgres_exclude=defaults["backup_tos_postgres_exclude"],
        backup_tos_secret_paths=defaults["backup_tos_secret_paths"],
        backup_tos_include_secrets=include_secrets,
        backup_tos_submounts={"stdout_lines": submounts or []},
    )


# --- scope / archive construction ---------------------------------------------

def test_scope_is_whole_etc(defaults):
    assert defaults["backup_tos_scope"] == "/etc"


def test_config_tar_uses_scope_and_one_file_system(tasks_text):
    assert "-C {{ backup_tos_scope }}" in tasks_text
    assert "--one-file-system" in tasks_text


def test_config_tar_is_anchored_and_uses_exclude_file(tasks_text):
    assert "--anchored" in tasks_text
    assert "--exclude-from=" in tasks_text


def test_extras_staged_under_extras(defaults, tasks_text):
    assert defaults["backup_tos_extra_paths"] == ["/var/spool/cron", "/var/lib/samba/private"]
    assert "backup_tos_staging_dir }}/extras" in tasks_text
    # The staged extras/db/state trees are folded into the config archive.
    assert "extras db state" in tasks_text


def test_extras_staging_tolerates_unreadable_paths(tasks):
    """Regression: an unreadable leaf (e.g. /var/spool/cron/crontabs) must not
    abort the whole backup. Staging uses `tar --ignore-failed-read`, matching
    the archive steps, instead of `cp -a` under a bare `set -e`."""
    task = _find_task(tasks, "Stage the out-of-scope extras")
    cmd = _task_cmd(task)
    assert "tar" in cmd
    assert "--ignore-failed-read" in cmd
    assert "cp -a" not in cmd
    # Keep failing closed on genuine tar failures (rc 2), not just file reads.
    assert "pipefail" in cmd


def test_volume1_state_is_out_of_scope(tasks_text):
    assert "/Volume1" not in tasks_text


# --- excludes -----------------------------------------------------------------

def test_vendor_and_dead_excludes_exact(defaults):
    assert defaults["backup_tos_vendor_excludes"] == [
        "./i18n",
        "./udev",
        "./pam.d",
        "./tos/modules",
        "./checksystem.db",
    ]
    assert defaults["backup_tos_dead_excludes"] == ["./nix"]


def test_postgres_raw_data_excluded(defaults):
    assert defaults["backup_tos_postgres_exclude"] == "./postgresql/13/main"


def test_exclude_file_contains_vendor_dead_and_postgres(defaults):
    rendered = _render_excludes(defaults, include_secrets=True)
    lines = rendered.splitlines()
    for pattern in (
        defaults["backup_tos_vendor_excludes"]
        + defaults["backup_tos_dead_excludes"]
        + [defaults["backup_tos_postgres_exclude"]]
    ):
        assert pattern in lines, f"exclude file missing {pattern!r}"
    assert "\n\n" not in rendered, "exclude file must not contain blank lines"


def test_secret_excludes_only_when_secrets_disabled(defaults):
    with_secrets = _render_excludes(defaults, include_secrets=True)
    without_secrets = _render_excludes(defaults, include_secrets=False)
    assert "./shadow" not in with_secrets
    assert "./shadow" in without_secrets
    assert "./gshadow" in without_secrets
    assert "./ssh/ssh_host_*_key" in without_secrets
    assert "extras/var/lib/samba/private/secrets.tdb" in without_secrets
    assert "./agent.key" in without_secrets


def test_submounts_are_normalised_and_anchored(defaults):
    rendered = _render_excludes(defaults, include_secrets=True, submounts=["/etc/mqueue"])
    lines = rendered.splitlines()
    assert "./mqueue" in lines
    assert "/etc/mqueue" not in lines


def test_no_vendor_executable_skip(tasks_text):
    assert "-executable" not in tasks_text
    assert " -perm " not in tasks_text


def test_dead_entries_not_special_cased(tasks_text):
    assert "/etc/os-release" not in tasks_text
    assert "/etc/mdadm.conf" not in tasks_text


# --- secrets ------------------------------------------------------------------

def test_secret_paths_declared(defaults):
    assert defaults["backup_tos_include_secrets"] is True
    for needle in (
        "/etc/shadow",
        "/etc/gshadow",
        "/etc/ssh/ssh_host_*_key",
        "/etc/ssl/private",
        "/etc/certificate/_archive",
        "/var/lib/samba/private/secrets.tdb",
        "agent.key",
    ):
        assert needle in defaults["backup_tos_secret_paths"]


def test_secrets_use_a_separate_archive(tasks):
    task = _find_task(tasks, "separate secrets archive")
    assert task["when"] == "backup_tos_include_secrets"
    assert "backup_tos_secret_paths" in _task_cmd(task)
    assert "backup_tos_secrets_archive" in _task_cmd(task)


def test_no_key_fixtures_in_role():
    for path in ROLE.rglob("*"):
        if path.is_file():
            assert path.suffix not in {".key", ".pem"}, f"key fixture in role: {path}"


# --- databases ----------------------------------------------------------------

def test_postgres_dump_is_fail_closed_on_port_5032(tasks):
    task = _find_task(tasks, "PostgreSQL")
    cmd = _task_cmd(task)
    assert "pg_dumpall -p {{ backup_tos_postgres_port }} -U postgres" in cmd
    assert not re.search(r"(?:^|\s)-h(?:\s|$)", cmd), "pg_dump must not use -h"
    assert "failed_when" not in task, "postgres dump must fail closed on rc != 0"


def test_sqlite_uses_online_backup_api(tasks):
    task = _find_task(tasks, "SQLite")
    cmd = _task_cmd(task)
    assert "sqlite3 -readonly" in cmd
    assert ".backup" in cmd
    assert "failed_when" not in task, "sqlite backup must fail closed on rc != 0"


def test_enable_state_is_captured(tasks):
    task = _find_task(tasks, "enabled systemd unit state")
    cmd = _task_cmd(task)
    assert "systemctl list-unit-files --state=enabled" in cmd
    assert "failed_when" not in task, "enable-state capture must fail closed"


# --- verification / manifest --------------------------------------------------

def test_archives_are_verified_with_gzip_and_tar(tasks_text):
    assert "gzip -t" in tasks_text
    assert "tar -tzf" in tasks_text


def test_checksum_tool_is_sha256(tasks_text):
    assert "sha256sum" in tasks_text or "openssl dgst" in tasks_text


def test_manifest_declares_every_field(tasks):
    content = _find_task(tasks, "Write a backup manifest")["ansible.builtin.copy"]["content"]
    for field in MANIFEST_FIELDS:
        assert f"{field}:" in content, f"manifest missing field {field!r}"


# --- interface invariants -----------------------------------------------------

def test_role_variables_are_namespaced(defaults):
    for key in defaults:
        assert key.startswith("backup_tos"), f"variable {key!r} is not namespaced"


def test_legacy_vars_removed(defaults):
    assert "backup_tos_paths" not in defaults
    assert "backup_tos_excludes" not in defaults


def test_backup_tos_is_first_role():
    play = load(PLAYBOOK)[0]
    names = [
        entry if isinstance(entry, str) else entry["role"]
        for entry in play["roles"]
    ]
    assert names[0] == "backup_tos"
