"""Unit tests for the zterra namespace roles' pure logic.

Covers roles/zterra_mount, zterra_layout, zterra_binds and zterra_docker_data:
the deepest-backing-mount selection, the free-space / root-mount guards, the
noCoW handling, the bind ordering, and the Docker data-root decision
(TOS-ZTERRA-002). No Ansible required; mirrors test_docker_step.py.
"""
from __future__ import annotations

from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]
ROLES = REPO / "roles"
MOUNT_DEFAULTS = ROLES / "zterra_mount" / "defaults" / "main.yml"
MOUNT_TASKS = ROLES / "zterra_mount" / "tasks" / "main.yml"
MOUNT_TEMPLATE = ROLES / "zterra_mount" / "templates" / "zterra.mount.j2"
LAYOUT_DEFAULTS = ROLES / "zterra_layout" / "defaults" / "main.yml"
LAYOUT_TASKS = ROLES / "zterra_layout" / "tasks" / "main.yml"
BINDS_DEFAULTS = ROLES / "zterra_binds" / "defaults" / "main.yml"
BINDS_TASKS = ROLES / "zterra_binds" / "tasks" / "main.yml"
BINDS_TEMPLATE = ROLES / "zterra_binds" / "templates" / "zterra-bind.mount.j2"
DOCKER_DEFAULTS = ROLES / "zterra_docker_data" / "defaults" / "main.yml"
DOCKER_TASKS = ROLES / "zterra_docker_data" / "tasks" / "main.yml"
DOCKER_TEMPLATES = ROLES / "zterra_docker_data" / "templates"
CONTAINERD_DROPIN = DOCKER_TEMPLATES / "containerd-zterra-root.conf.j2"
DOCKER_DROPIN = DOCKER_TEMPLATES / "docker-zterra-mounts.conf.j2"
TERRA_VARS = REPO / "group_vars" / "terra" / "vars.yml"

# Size of the artifact whose staging failed (logs/20261010T180200-image.log).
ARTIFACT_BYTES = 1570828932

ROLE_DEFAULTS = {
    "zterra_mount": MOUNT_DEFAULTS,
    "zterra_layout": LAYOUT_DEFAULTS,
    "zterra_binds": BINDS_DEFAULTS,
    "zterra_docker_data": DOCKER_DEFAULTS,
}


def load(path: Path):
    return yaml.safe_load(path.read_text())


def _iter_tasks(tasks):
    for task in tasks:
        yield task
        for key in ("block", "rescue", "always"):
            if key in task:
                yield from _iter_tasks(task[key])


def _find_task(tasks, needle):
    for task in _iter_tasks(tasks):
        if needle in (task.get("name") or ""):
            return task
    raise AssertionError(f"no task containing {needle!r}")


def _task_index(tasks, needle):
    for index, task in enumerate(_iter_tasks(tasks)):
        if needle in (task.get("name") or ""):
            return index
    raise AssertionError(f"no task containing {needle!r}")


def _backing_mount(root: str, mounts: list[dict]):
    """Pure-Python mirror of the deepest-mount selection."""
    matches = [
        mount
        for mount in sorted(mounts, key=lambda m: m["mount"])
        if root == mount["mount"] or root.startswith(mount["mount"].rstrip("/") + "/")
    ]
    return matches[-1] if matches else None


# --- namespacing --------------------------------------------------------------

def test_role_defaults_are_namespaced():
    for role, path in ROLE_DEFAULTS.items():
        for key in load(path):
            assert key.startswith(role), f"{role}: '{key}' is not namespaced"


# --- @terra values ------------------------------------------------------------

def test_terra_root_is_the_strategy_mountpoint():
    assert load(TERRA_VARS)["zterra_root"] == "/zterra"


def test_terra_mount_uses_a_stable_device_not_a_kernel_name():
    device = load(TERRA_VARS)["zterra_mount_device"]
    assert device.startswith("/dev/disk/by-")
    assert not device.startswith("/dev/sd")


def test_terra_nocow_paths_cover_nix_docker_and_tmp():
    nocow = load(TERRA_VARS)["zterra_layout_nocow_paths"]
    assert any(p.endswith("/local-/nix") for p in nocow)
    assert any(p.endswith("/var-/lib/docker") for p in nocow)
    assert any(p.endswith("/local-/var-/tmp") for p in nocow)


def test_terra_docker_is_a_subvolume_not_a_precreated_directory():
    """var-/lib/docker must be a noCoW subvolume; pre-creating it as a plain
    directory makes `btrfs subvolume create` skip it (the layout bug)."""
    data = load(TERRA_VARS)
    dirs = [d["path"] for d in data["zterra_layout_directories"]]
    assert not any(p.endswith("/var-/lib/docker") for p in dirs)
    assert any(p.endswith("/var-/lib/docker") for p in data["zterra_layout_nocow_paths"])


def test_terra_binds_are_nix_and_tmp_only_after_d_log():
    """D-LOG: /var/log is a TOS symlink to /tmp/log and cannot be a systemd
    .mount target, so the bind set is /nix + /tmp only; logs ride the /tmp bind.
    """
    binds = {b["target"]: b for b in load(TERRA_VARS)["zterra_binds_mounts"]}
    assert set(binds) == {"/nix", "/tmp"}
    assert binds["/nix"]["before"] == "nix-daemon.service"
    # /tmp replaces the active tmpfs tmp.mount, so it must be restarted.
    assert binds["/tmp"]["replace"] is True


def test_terra_retires_the_var_log_unit():
    """D-LOG: the failed, enabled /var/log unit must be torn down."""
    assert "var-log.mount" in load(TERRA_VARS)["zterra_binds_retired_units"]


def test_terra_keeps_var_log_as_a_reserved_directory():
    dirs = [d["path"] for d in load(TERRA_VARS)["zterra_layout_directories"]]
    assert any(p.endswith("/local-/var-/log") for p in dirs)


def test_terra_enables_the_docker_data_root():
    data = load(TERRA_VARS)
    assert data["zterra_docker_data_manage"] is True
    assert data["zterra_docker_data_mechanism"] == "daemon_json"
    assert data["zterra_docker_data_root"].endswith("/var-/lib/docker")


def test_terra_puts_the_containerd_image_store_on_zterra():
    """Docker 29 keeps images/snapshots in containerd, not data-root."""
    data = load(TERRA_VARS)
    assert data["zterra_docker_data_containerd_root"].endswith("/var-/lib/containerd")
    assert data["zterra_docker_data_containerd_root"] in data["zterra_layout_nocow_paths"]


# --- zterra_mount -------------------------------------------------------------

def test_mount_defaults_are_operator_provisioned():
    data = load(MOUNT_DEFAULTS)
    assert data["zterra_mount_provision"] is False
    assert data["zterra_mount_fstype"] == "btrfs"
    assert data["zterra_mount_options"] == "nofail"


def test_mount_rejects_kernel_device_names():
    tasks = load(MOUNT_TASKS)
    validate = _find_task(tasks, "Validate the zterra mount inputs")
    assert "match('^/dev/sd')" in str(validate["ansible.builtin.assert"]["that"])


def test_mount_never_formats_by_default():
    tasks = load(MOUNT_TASKS)
    provision = _find_task(tasks, "Provision the zterra btrfs filesystem")
    assert "zterra_mount_provision" in str(provision["when"])
    assert "mkfs.btrfs" in provision["ansible.builtin.command"]
    # A blank, unprovisioned device fails with guidance instead of formatting.
    assert _find_task(tasks, "Fail when the device is unprovisioned")


def test_mount_template_is_nofail():
    assert "nofail" in load(MOUNT_DEFAULTS)["zterra_mount_options"]
    assert "[Mount]" in MOUNT_TEMPLATE.read_text()


# --- zterra_layout ------------------------------------------------------------

def test_layout_default_min_free_covers_the_artifact():
    min_free = int(load(LAYOUT_DEFAULTS)["zterra_layout_min_free_bytes"])
    assert min_free >= ARTIFACT_BYTES


def test_layout_refreshes_mount_facts_before_selecting():
    """gather_facts runs before zterra_mount in the same play, so the play-start
    ansible_facts['mounts'] lacks /zterra; the guard then resolves to "/" and
    fails. The role must refresh the mount facts before selecting."""
    tasks = load(LAYOUT_TASKS)
    refresh = _find_task(tasks, "Refresh the mount facts")
    assert refresh["ansible.builtin.setup"]["gather_subset"] == "mounts"
    assert _task_index(tasks, "Refresh the mount facts") < _task_index(
        tasks, "Identify the filesystem that backs the zterra root"
    )


def test_layout_selects_backing_mount_and_guards():
    tasks = load(LAYOUT_TASKS)
    identify = _find_task(tasks, "Identify the filesystem that backs the zterra root")
    assert "ansible_facts['mounts']" in identify["loop"]
    assert "startswith" in identify["when"]
    assert _find_task(tasks, "Refuse to lay out zterra on the root filesystem")
    free = _find_task(tasks, "Assert the zterra filesystem has enough free space")
    assert "size_available" in str(free["ansible.builtin.assert"])


def test_layout_nocow_is_subvolume_plus_chattr():
    tasks = load(LAYOUT_TASKS)
    subvol = _find_task(tasks, "Ensure the zterra noCoW subvolumes exist")
    assert "btrfs subvolume create" in subvol["ansible.builtin.command"]
    assert subvol["when"] == "zterra_layout_backing_mount.fstype | default('') == 'btrfs'"
    chattr = _find_task(tasks, "Disable copy-on-write")
    assert chattr["ansible.builtin.file"]["attributes"] == "+C"


def test_layout_creates_directories_idempotently():
    create = _find_task(load(LAYOUT_TASKS), "Ensure the zterra namespace directories exist")
    assert create["ansible.builtin.file"]["state"] == "directory"
    assert create["loop"] == "{{ zterra_layout_directories }}"


def test_layout_verifies_nocow_paths_are_subvolumes():
    """`creates:` only tests existence, so a plain directory left by an earlier
    run silently skips the subvolume; the role must verify subvolume-ness."""
    tasks = load(LAYOUT_TASKS)
    verify = _find_task(tasks, "Verify each noCoW path is a btrfs subvolume")
    assert "btrfs" in str(verify["ansible.builtin.command"])
    assert _find_task(tasks, "Fail when a noCoW path is not a btrfs subvolume")


# --- zterra_binds -------------------------------------------------------------

def test_binds_fail_closed_on_missing_source():
    tasks = load(BINDS_TASKS)
    assert _find_task(tasks, "Fail-closed when a bind source is missing")
    # The install task registers its result so only *changed* units restart.
    install = _find_task(tasks, "Install the zterra bind mount units")
    assert install["register"] == "zterra_binds_installed"


def test_binds_restart_only_changed_non_replace_units():
    """Changing one unit must not restart a busy sibling (e.g. /nix)."""
    tasks = load(BINDS_TASKS)
    start = _find_task(tasks, "Start the non-replace zterra bind mounts")
    assert "item.changed" in str(start["ansible.builtin.systemd"]["state"])
    assert "replace" in str(start["when"])


def test_binds_template_orders_after_the_zterra_mount():
    text = BINDS_TEMPLATE.read_text()
    assert "After={{ zterra_bind.after | default(zterra_binds_mount_dep) }}" in text
    assert "Type=none" in text


def test_binds_template_lazy_unmounts_replaceable_targets():
    """A `replace` target is busy; the unit must stop with LazyUnmount=yes so a
    restart can detach it instead of failing with EBUSY (umount exit 32)."""
    text = BINDS_TEMPLATE.read_text()
    assert "LazyUnmount=yes" in text
    assert "zterra_bind.replace | default(false)" in text


def test_binds_reject_symlinked_targets():
    """systemd .mount units cannot use a symlinked Where= (D-LOG); the role must
    stat with follow:false and fail before writing an unusable unit."""
    tasks = load(BINDS_TASKS)
    inspect = _find_task(tasks, "Inspect each bind target")
    assert inspect["ansible.builtin.stat"]["follow"] is False
    guard = _find_task(tasks, "Fail-closed on a symlinked bind target")
    assert "islnk" in str(guard["ansible.builtin.assert"]["that"])
    assert _task_index(tasks, "Inspect each bind target") < _task_index(
        tasks, "Derive each bind unit name"
    )


def test_binds_replace_detects_an_already_bound_target():
    """findmnt -o SOURCE reports a btrfs bind as '<device>[/subvol]', never the
    source path, so a string compare restarts every run. Compare the resolved
    device:inode identity of the target and its source instead."""
    tasks = load(BINDS_TASKS)
    check = _find_task(tasks, "already bound to its source")
    assert "stat -c %d:%i" in str(check["ansible.builtin.command"])
    restart = _find_task(tasks, "Replace a stale mount")
    assert restart["ansible.builtin.systemd"]["state"] == "restarted"
    assert "item.rc" in str(restart["when"])
    # The template must index zterra_binds_units by the loop's own index_var;
    # a mismatched name is an undefined variable at runtime (not caught by lint).
    index_var = restart["loop_control"]["index_var"]
    assert f"[{index_var}]" in restart["ansible.builtin.systemd"]["name"]


def test_binds_swap_keeps_module_payload_off_tmp():
    """Ansible extracts the module payload into the system tempdir; replacing
    /tmp would hide it and crash the module on exit. The swap task must point
    TMPDIR at a filesystem we are not swapping."""
    tasks = load(BINDS_TASKS)
    swap = _find_task(tasks, "Replace a stale mount")
    env = swap["environment"]
    assert not env["TMPDIR"].startswith("/tmp")
    default = load(BINDS_DEFAULTS)["zterra_binds_module_tmpdir"]
    assert default.startswith("/")
    assert not default.startswith("/tmp")


def test_binds_retire_stale_units():
    tasks = load(BINDS_TASKS)
    assert _find_task(tasks, "Stop and disable the retired bind units")
    assert _find_task(tasks, "Remove the retired bind unit files")
    assert load(BINDS_DEFAULTS)["zterra_binds_retired_units"] == []


# --- zterra_docker_data -------------------------------------------------------

def test_docker_data_is_inert_by_default():
    assert load(DOCKER_DEFAULTS)["zterra_docker_data_manage"] is False


def test_docker_data_sets_daemon_json_data_root():
    tasks = load(DOCKER_TASKS)
    set_root = _find_task(tasks, "Set the Docker data-root in daemon.json")
    assert "data-root" in set_root["ansible.builtin.copy"]["content"]
    assert "zterra_docker_data_daemon_json_result" in set_root["register"]


def test_docker_data_relocates_the_containerd_root():
    defaults = load(DOCKER_DEFAULTS)
    assert defaults["zterra_docker_data_manage_containerd"] is True
    assert defaults["zterra_docker_data_containerd_root"].endswith("/var-/lib/containerd")
    tasks = load(DOCKER_TASKS)
    assert _find_task(tasks, "Ensure the containerd storage root directory exists")


def test_docker_data_overrides_containerd_root_via_dropin():
    tasks = load(DOCKER_TASKS)
    task = _find_task(tasks, "Set the containerd storage root")
    assert task["ansible.builtin.template"]["src"] == "containerd-zterra-root.conf.j2"
    content = CONTAINERD_DROPIN.read_text()
    assert "RequiresMountsFor={{ zterra_docker_data_containerd_root }}" in content
    # An empty ExecStart resets the vendor unit before the --root override.
    assert "ExecStart=\n" in content
    assert "--root {{ zterra_docker_data_containerd_root }}" in content


def test_docker_data_fails_closed_when_zterra_is_not_mounted():
    """zterra.mount is `nofail`; docker must not write state to the root fs."""
    tasks = load(DOCKER_TASKS)
    task = _find_task(tasks, "Require the zterra mounts before Docker starts")
    assert task["ansible.builtin.template"]["src"] == "docker-zterra-mounts.conf.j2"
    content = DOCKER_DROPIN.read_text()
    assert "RequiresMountsFor={{ zterra_docker_data_root }}" in content
    assert "{{ zterra_docker_data_containerd_root }}" in content


def test_docker_data_applies_restarts_inline_and_self_heals_drift():
    """A failed play must not skip the restart (handlers are deferred)."""
    tasks = load(DOCKER_TASKS)
    names = [task.get("name") or "" for task in _iter_tasks(tasks)]
    read = names.index("Read the active containerd storage root")
    restart = names.index("Restart containerd when its zterra root is not applied")
    docker = names.index("Restart docker after a storage-root or mount-order change")
    verify = names.index("Fail when containerd is not using the zterra image store")
    assert read < restart < docker < verify
    restart_task = _find_task(tasks, "Restart containerd when its zterra root is not applied")
    assert "not in zterra_docker_data_containerd_active.stdout" in str(restart_task["when"])


# --- pure backing-mount selection ---------------------------------------------

MOUNTS = [
    {"mount": "/", "size_available": 4 * 1024**3},
    {"mount": "/zterra", "size_available": 900 * 1024**3},
    {"mount": "/zterra-old", "size_available": 1},
]


def test_backing_mount_prefers_the_deepest_match():
    chosen = _backing_mount("/zterra/local-/nix", MOUNTS)
    assert chosen is not None
    assert chosen["mount"] == "/zterra"


def test_backing_mount_does_not_false_match_a_sibling():
    chosen = _backing_mount("/zterra/local-/nix", MOUNTS)
    assert chosen is not None
    assert chosen["mount"] != "/zterra-old"


def test_backing_mount_falls_back_to_root():
    chosen = _backing_mount("/var/tmp/zterra", MOUNTS)
    assert chosen is not None
    assert chosen["mount"] == "/"


def test_backing_mount_is_exact_when_root_is_a_mount():
    chosen = _backing_mount("/zterra", MOUNTS)
    assert chosen is not None
    assert chosen["mount"] == "/zterra"
