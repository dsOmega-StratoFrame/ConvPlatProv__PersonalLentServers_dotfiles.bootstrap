# RFC-0002 — Generic roles and Makefile layers

| Field | Value |
|---|---|
| RFC | `RFC-0002` |
| Title | Generic roles and reusable Makefile layers |
| Status | **Proposed** |
| Date | 2026-10-29 |
| Author | Architect |
| Base HEAD | `004ee9e` (worktree dirty; base shared with RFC-0001) |
| Scope | Abstract the repo's host/project roles into reusable mechanism roles and its per-step Makefiles into an include contract, **without changing behaviour**. Documentation only: no role code, playbook edit, Makefile edit, ADR change, commit, publication or `reviewed-by`. |
| Supersedes | none |

Companion documents (read, not modified): `docs/rfc/RFC-0001-edge-iteration-workflow.md`, `docs/NikolaiGogol__DependencyLayers_plan.md`, `.agents/AGENTS.md`, `docs/adr/0001-HomeServer__HomeAssistant.md`–`0005-*.md`, `tests/README.md`.

## Contract summary

| Field | Value |
|---|---|
| Affected projects | this repository (`roles/`, `group_vars/`, playbooks, `Makefile.*`); any future host/repository that consumes the extracted roles. No external repository is changed. |
| Source revisions | repo base HEAD `004ee9e`; the storage/container work and docs are present, worktree dirty. `RFC-0001` is the current edge-workflow proposal at the same base. |
| Decision status | **Proposed.** This RFC does not supersede an accepted architecture baseline; it proposes a reusable library shape and a behaviour-preserving migration. |
| Compatibility guarantees | Role names, playbook role order, playbook tags, `Makefile.<Step>` entry points and rendered deployment artifacts stay unchanged through Phases A–E. Legacy `zterra_*`, `nixos_image_*`, `nixos_container`, `nikolaigogol_scripts` and `nixos_edge_sync` names remain callable wrappers for the deprecation window (§7). |
| Prohibited changes | no behaviour change; no host/artifact names in generic role defaults or logic; no TOS privilege/path policy in a generic role; no new secrets or vault reads; no ADR status edit; no publication; no `reviewed-by`. |
| Validation gates | `nix develop --command python3 -m pytest tests/unit -q`; `make check`; `ansible-lint`; `--list-tasks --tags <tag>` before/after diff; second-run `changed=0`; two-parameter-set fixture (same role, two hosts). |
| Rollback | per-phase: restore the wrapper to its pre-phase task body; the generic role becomes unused. No data migration, no playbook edit, no target-side state change. |
| Diagrams | §7 phase/event order. No topology change is proposed. |

## 1. Context and motivation

The user's observation, in intent, is:

> `nikolaigogol_scripts` should be reusable for other hosts and repositories;
> `zterra_layout` is already generic; the Makefiles are a repeated pattern they
> have written before.

The code agrees in part. `roles/nikolaigogol_scripts` is already a payload-sync
engine with a manifest, drift guard, additive sync and verification
hooks (`roles/nikolaigogol_scripts/tasks/main.yml`), but its defaults and its
`.env` template are tied to `@NikolaiGogol`, `@terra`, `/zterra` and
`HomeServer__HomeAssistant`. `roles/zterra_layout` is structurally generic —
directory list, noCoW list, deepest-backing-mount guard, free-space floor, root
mount refusal — but its variables and failure messages say `zterra`.
`Makefile.Steps` is already a small engine, and nine per-step makefiles repeat
the same `STEP_TAGS` / `PLAYBOOK` / `VERIFY_PLAYBOOK` / `include` preamble
(`Makefile.AccessSsh`, `Makefile.BackupTos`, `Makefile.DockerDeployment`,
`Makefile.NixBootstrap`, `Makefile.NixosContainer`, `Makefile.NixosEdgeSync`,
`Makefile.NixosImage`, `Makefile.NixosScripts`, `Makefile.Zterra`).

The goal is:

> **mechanism in generic roles, policy in thin project roles**, without changing
> behaviour.

Concretely:

- a generic role owns *how* a capability works (sync + manifest + drift guard,
  btrfs layout, systemd mount units, Docker storage roots, image
  locate/transfer/import, compose render/up, in-container rebuild);
- the project role owns *the names, paths, defaults and exceptions* for a host
  or product (`zterra`, `@NikolaiGogol`, `HomeServer__HomeAssistant`, TOS 6);
- existing playbooks keep calling the existing role names and tags, so role
  order, `--tags` selection and operator commands do not change.

This RFC is deliberately not an architecture change to the deployment model.
ADR 0001's layered, idempotent model and ADR 0002's content-tag contract remain
the baseline. This is a code-organisation proposal with a behaviour-preserving
migration.

## 2. Inventory and taxonomy

There are **16 roles** under `roles/`. I classify them as:

- **generic** — the mechanism has no host, artifact or product identity in its
  defaults or logic; all identity is a parameter;
- **host-specific** — the role encodes a platform/distro policy (TOS 6, apt, a
  vendor `install`, a package-manager quirk);
- **project-specific** — the role encodes this deployment's paths, databases,
  names or backup scope.

The classification is about the *current* code, not about what could be made
generic after a rewrite.

| Role | Capability (evidence) | Reusable? | Proposed generic name | Key parameterization |
|---|---|---|---|---|
| `access_ssh` | key generation/check/upload and verification (`roles/access_ssh/tasks/main.yml`) | **generic (deferred)** | `ssh_key_access` | user, key path, public key, optional password, connect host/port, retries. Not in Phases A–E. |
| `access_sftp` | restore the sftp-server binary / apt lists workaround (`roles/access_sftp/tasks/main.yml`) | **host-specific** | — | TOS 6 protects OpenSSH and cannot serve sftp; the opt-out is policy. |
| `backup_tos` | `/etc` + extras + DB dumps + secrets archive (`roles/backup_tos/tasks/main.yml`) | **project-specific** | — | TOS vendor excludes, PostgreSQL port 5032, SQLite paths, TOS archive naming. |
| `bootstrap_base` | required commands, apt mirror, xz CVE guard (`roles/bootstrap_base/tasks/main.yml`) | **host-specific** | — | Ubuntu/TOS mirror candidates and `jammy`; already data-driven, but single-platform policy. |
| `bootstrap_docker` | detect/install Docker CE, GNU `install` shim (`roles/bootstrap_docker/tasks/main.yml`) | **host-specific** | — | TOS's Go `install` shadows coreutils; apt-only install path. |
| `bootstrap_nix` | install Nix via pinned galaxy role, `/etc/nix/nix.conf` (`roles/bootstrap_nix/tasks/main.yml`) | **host-specific** | — | TOS `install` shim, profile PATH, installer checksum; not a generic package-manager bootstrap. |
| `nikolaigogol_scripts` | payload dir sync, manifest + drift guard, `.env`, shell/compose checks (`roles/nikolaigogol_scripts/tasks/main.yml`) | **generic** | `payload_dir_sync` | source dir, target dir, excludes, `delete`, `force`, manifest name/role, env template + vars, verify commands. |
| `nixos_container` | render compose/env, mount sources, fail-closed file mounts, compose up/recreate (`roles/nixos_container/tasks/main.yml`) | **generic** | `compose_service` | project dir, compose/env templates, mounts `{source,target,type,provider}`, validate/manage/pull/recreate, docker binary, become user. Privileged-systemd flags stay in the project template. |
| `nixos_edge_sync` | rsync checkout into a bind, run an in-container rebuild (`roles/nixos_edge_sync/tasks/main.yml`) | **generic** | `container_edge_sync` | source dir, remote dir, container name, in-container command list, rsync opts, `delete`, `enabled`, become user. |
| `nixos_image_artifact` | locate + checksum the tarball, derive the content tag (`roles/nixos_image_artifact/tasks/main.yml`) | **generic** | `docker_image_artifact` | source dir, archive relative path, tag length, image repository, content-tag command, required flag. |
| `nixos_image_load` | gated `docker import` + verify (`roles/nixos_image_load/tasks/main.yml`) | **generic** | `docker_image_load` | repository, tag, remote archive, docker binary, manage, force, become user. |
| `nixos_image_sync` | push the artifact to a staging dir (`roles/nixos_image_sync/tasks/main.yml`) | **generic** | `docker_image_transfer` | source archive, remote dir, checksum/compress/delete, dest port, rsync opts, rsync install policy. |
| `zterra_binds` | templated bind `.mount` units, symlink guard, `LazyUnmount`, `TMPDIR` (`roles/zterra_binds/tasks/main.yml`) | **generic** | `bind_mount_units` | mounts `{source,target,after,before,options,replace,lazy_unmount}`, retired units, mount dependency, module tempdir. |
| `zterra_docker_data` | data-root + containerd root, drop-ins, inline restart, active-ExecStart assert (`roles/zterra_docker_data/tasks/main.yml`) | **generic** | `docker_storage_root` | data root, containerd root/flag/binary, daemon.json path, drop-in paths, manage, mechanism, inline restart. |
| `zterra_layout` | directory tree, noCoW subvolumes, deepest-backing mount + free-space/root guards (`roles/zterra_layout/tasks/main.yml`) | **generic** | `btrfs_layout` | root, directories `{path,mode}`, noCoW paths, minimum free bytes, forbid-root-mount, dir mode. Btrfs-specific, not filesystem-agnostic. |
| `zterra_mount` | one systemd `.mount` unit from a stable device, provision gate (`roles/zterra_mount/tasks/main.yml`) | **generic** | `systemd_mount_unit` | device, mountpoint, fstype, options, unit name/description, provision flag, dir mode. |

Inventory result: **16 roles; 10 generic in scope** (the proposed library), **1
generic candidate deferred** (`access_ssh`), **4 host-specific** and **1
project-specific**. The deferred and non-generic roles stay as they are in this
RFC; they are listed so the inventory is complete, not to force an abstraction.

`Makefile.NixosDeps` does **not** exist at base HEAD; it is proposed in
`docs/NikolaiGogol__DependencyLayers_plan.md`. It is not part of this RFC's
current-pattern inventory, but a future layer file should use the same
`Makefile.Layer` contract (§5).

## 3. Design principles

1. **Generic role = mechanism + contract. Project role = defaults + policy.**
   The project role may be only `defaults/main.yml` plus a small import of the
   generic role. It must not fork the mechanism.
2. **No host, artifact or product names in generic vars or logic.** No
   `zterra`, `terra`, `NikolaiGogol`, `HomeServer__HomeAssistant`, `ds-omega`,
   `/zterra`, `haos_ova`, `nixos-rebuild` or `ds13` in a generic role. Those
   belong in the wrapper defaults, group vars, templates or command parameters.
3. **Hard-won invariants are parameters, not hidden defaults.** They survive
   the extraction as explicit knobs and contract tests:

   | Invariant | Contract in the generic role |
   |---|---|
   | TOS 6 privilege model: escalate to the uid-0 admin, never the uid-9999 `root` | `*_become_user` is a required/validated parameter; no `default('root')` inside a generic role. The project wrapper supplies `ansible_become_user`. |
   | Ansible module payload must not be hidden by replacing `/tmp` | `bind_mount_units_module_tmpdir` default `/var/tmp`; the swap task exports `TMPDIR`/`TMP`/`TEMP`. |
   | Storage-root changes restart inline, not through deferred handlers | `docker_storage_root_restart_inline` default `true`; all restarts are tasks, and the role re-reads the active `ExecStart`. |
   | Atomic replace / no half-written live payload | single-file payloads use an `.incoming` + rename; directory sync stays additive (`delete: false`) until a staging/swap mode is implemented, and the generic role must not claim directory atomicity it does not have. |
   | Manifest-based drift guard (`delete: false`, explicit `force`) | `payload_dir_sync_manifest`, `payload_dir_sync_force`, `payload_dir_sync_delete=false` by default; drift fails **before** sync. |
   | Fail-closed file mounts | `compose_service` validates `type: file` sources before `up`; a missing source is a failure, never a created directory. |
   | Content-addressable identity, never a moving `latest` | `docker_image_artifact` derives the tag from the checksum or a shared tag command; the wrapper supplies the repository. |
   | Real change reporting | no `changed_when: true` in a generic role; probes use `changed_when: false`, modules report their own change. |
4. **One verification contract per role.** Every generic role must define:
   (a) a second run that reports `changed=0` when inputs are unchanged; (b) an
   explicit post-condition (file exists, unit active, image present, container
   running, manifest digest equal); (c) a failure message that names the
   parameter, the observed state and the remediation.
5. **Prefer composition over deep inheritance.** A project role imports or
   includes one or more generic roles; generic roles do not import project
   roles, and there are no `include_role` cycles. Pass values through role
   vars, never through global `set_fact` unless the role publishes a documented
   fact.
6. **Do not over-abstract single-use logic.** The TOS privilege preflight
   (`tasks/preflight_privilege_model.yml`), backup scope, apt mirror and vendor
   `install` shims stay project/host tasks until a second host needs them.
7. **Tags belong to the caller.** A generic role declares no playbook tags. The
   project playbook keeps `tags: [zterra, storage, image]`, `[scripts, debug]`,
   etc.; the generic role inherits them through the wrapper. This is what keeps
   `--tags` behaviour identical.
8. **No wrapper drift.** A wrapper may hold defaults, a mapping and a template,
   but not a copy of the mechanism. If a wrapper grows a second task body, the
   mechanism belongs in the generic role.

## 4. Proposed library and interfaces

### 4.1 Location and naming convention (provisional)

Until §10 Q1/Q2 are decided, this RFC uses:

- role directory: `roles/generic_<capability>/`;
- public variable prefix: `<capability>_*` (the prefix users and wrappers see);
- role invocation name: `generic_<capability>`.

The `generic_` directory prefix is a location marker, not part of the public
variable interface. `tests/unit/test_repo_structure.py` currently asserts every
default key starts with the role directory name; the migration must add a
one-line allowance that strips `generic_` before the assertion, or Q2 resolves
to unprefixed directory names. This is a test change, not a behaviour change.

Common rules:

- **Tags:** none in the generic role; the wrapper is tagged by the playbook.
- **Facts:** published under the capability prefix (for example
  `payload_dir_sync_result`), never under a host or product prefix. A wrapper
  may alias them to legacy names for compatibility (§7 Phase C).
- **Secrets:** generic roles never read vaults and never render secrets. An env
  hook is a template supplied by the project; if a project template needs a
  secret, the project owns the vault indirection.
- **Mode:** all rendered files have an explicit mode; `.env` and manifests
  default to `0600`.

### 4.2 `generic_payload_dir_sync`

| Item | Contract |
|---|---|
| Purpose | Push a control-node directory to a target directory with excludes, optional `.env` rendering, a manifest and a drift guard; run post-sync verification. |
| Required vars | `payload_dir_sync_source_dir`, `payload_dir_sync_target_dir`. |
| Optional vars | `payload_dir_sync_enabled` (default `true`), `payload_dir_sync_excludes`, `payload_dir_sync_rsync_opts`, `payload_dir_sync_delete` (default `false`), `payload_dir_sync_force` (default `false`), `payload_dir_sync_manifest` (`true`), `payload_dir_sync_manifest_name` (`.deploy-state`), `payload_dir_sync_manifest_role`, `payload_dir_sync_env_template_path`, `payload_dir_sync_env_dest`, `payload_dir_sync_env_mode` (`0600`), `payload_dir_sync_env_vars`, `payload_dir_sync_verify_shell_glob` (`*.sh`), `payload_dir_sync_verify_commands`, `payload_dir_sync_dir_mode` (`0755`). |
| Tags | none; caller supplies `scripts`/`debug`, or a future `payload` tag. |
| Publishes / registers | `payload_dir_sync_result` (rsync result), `payload_dir_sync_manifest` (parsed), `payload_dir_sync_tree`, `payload_dir_sync_deployed`; no host facts. |
| Idempotency / verification | checksum rsync with `delete: false` by default; manifest rewritten only when the tree digest changes; second run `changed=0`; drift fails before rsync and lists affected files; shell syntax and optional commands verify after sync. |
| Wrapper keeps | source/target paths, project excludes, `enabled`/`force` policy, `templates/env.j2` and its project values, the `.deploy-state` role/source labels, the docker/make probes. |

The generic role must accept a legacy manifest that has the current keys
(`role`, `source`, `tree_sha256`, `deployed_at`, `files`) and ignore unknown or
mismatched role labels. That is what lets Phase A keep the existing
`.deploy-state` readable.

### 4.3 `generic_btrfs_layout`

| Item | Contract |
|---|---|
| Purpose | Create a directory tree and optional btrfs noCoW subvolumes, guarded by the deepest backing mount, a free-space floor and a root-filesystem refusal. |
| Required vars | `btrfs_layout_root`, `btrfs_layout_directories` (`[{path, mode?}]`). |
| Optional vars | `btrfs_layout_nocow_paths`, `btrfs_layout_min_free_bytes`, `btrfs_layout_forbid_root_mount` (`true`), `btrfs_layout_dir_mode` (`0755`), `btrfs_layout_refresh_mount_facts` (`true`). |
| Tags | none; caller supplies `zterra`/`storage`/`image`. |
| Publishes / registers | `btrfs_layout_backing_mount` (mount fact), subvolume verification results. |
| Idempotency / verification | `file: state=directory`; `btrfs subvolume create` with `creates`; verify subvolume-ness and fail on a plain directory; `chattr +C` via `attributes: "+C"`; second run `changed=0`. |
| Wrapper keeps | the `zterra` root, the full directory list (including reserved leaves), noCoW paths, the 5 GiB floor, the TOS D-MOUNT/D-LOG reasons. |

The role remains **btrfs-specific**. It is not a generic filesystem layout role;
on a non-btrfs backing filesystem the noCoW block is skipped, and the wrapper
must say so.

### 4.4 `generic_systemd_mount_unit`

| Item | Contract |
|---|---|
| Purpose | Render one systemd `.mount` unit from a stable device path, mountpoint, fstype and options; optionally provision a blank filesystem behind an explicit gate. |
| Required vars | `systemd_mount_unit_device`, `systemd_mount_unit_path`. |
| Optional vars | `systemd_mount_unit_fstype` (caller-supplied; no distro default), `systemd_mount_unit_options` (`nofail`), `systemd_mount_unit_unit`, `systemd_mount_unit_description`, `systemd_mount_unit_provision` (`false`), `systemd_mount_unit_dir_mode` (`0755`), `systemd_mount_unit_forbid_kernel_device` (`true`). |
| Tags | none; caller supplies `zterra`/`storage`. |
| Publishes / registers | `systemd_mount_unit_name`, device stat/blkid, enable/start result. |
| Idempotency / verification | unit name derived with `systemd-escape` when unset; template + `systemd enabled/started`; second run `changed=0`; unprovisioned device with provisioning off fails with the exact `mkfs` guidance. |
| Wrapper keeps | `/zterra`, the by-uuid/by-path device, `btrfs`, `nofail`, the unit description and DP1's “operator formats” policy. |

### 4.5 `generic_bind_mount_units`

| Item | Contract |
|---|---|
| Purpose | Render bind `.mount` units for a list of `{source,target}` pairs, with a symlink guard, per-unit restart, `LazyUnmount`, identity idempotency and a tempdir outside the target. |
| Required vars | `bind_mount_units_mounts`. |
| Optional vars | `bind_mount_units_retired_units`, `bind_mount_units_options` (`bind,nofail`), `bind_mount_units_mount_dep`, `bind_mount_units_module_tmpdir` (`/var/tmp`), `bind_mount_units_unit_dir` (`/etc/systemd/system`). |
| Tags | none; caller supplies `zterra`/`storage`/`binds`. |
| Publishes / registers | installed-unit results, bound-state results, retired-unit results. |
| Idempotency / verification | sources and non-symlink targets checked before writing; unit template change restarts only that unit; non-`replace` units `started` unless changed; `replace` units compare `stat -c %d:%i` and restart only when the target is not the source; retired units are stopped/disabled/removed; second run `changed=0`. |
| Wrapper keeps | `/nix` and `/tmp` sources/targets, `before: nix-daemon.service`, `replace: true` for `/tmp`, the retired `var-log.mount`, `zterra.mount` dependency and the `/var/tmp` module tempdir. |

### 4.6 `generic_docker_storage_root`

| Item | Contract |
|---|---|
| Purpose | Move Docker's `data-root` and containerd's image store, add drop-ins that require the backing mounts, restart the daemons inline and assert the active containerd `ExecStart` uses the new root. |
| Required vars | `docker_storage_root_data_root`. |
| Optional vars | `docker_storage_root_manage` (`false`), `docker_storage_root_mechanism` (`daemon_json`), `docker_storage_root_daemon_json`, `docker_storage_root_dir_mode`, `docker_storage_root_manage_containerd` (`true`), `docker_storage_root_containerd_root`, `docker_storage_root_containerd_binary`, `docker_storage_root_containerd_dropin`, `docker_storage_root_docker_dropin`, `docker_storage_root_restart_inline` (`true`). |
| Tags | none; caller supplies `zterra`/`storage`/`docker`/`image`. |
| Publishes / registers | daemon.json result, drop-in results, containerd active/restart results. |
| Idempotency / verification | daemon.json is parsed and merged, not overwritten; drop-ins are templated; restarts happen only when a file changed or the active `ExecStart` lacks the root; post-restart assert; second run `changed=0`. |
| Wrapper keeps | `/zterra/var-/lib/docker` and `/zterra/var-/lib/containerd`, `manage: true`, the drop-in paths, the mount requirement and the D-ROOT history. |

### 4.7 `generic_docker_image_artifact`

| Item | Contract |
|---|---|
| Purpose | Locate a pre-built rootfs tarball on the control node, checksum it, derive a content tag and publish the image name. Never builds. |
| Required vars | `docker_image_artifact_source_dir`, `docker_image_artifact_archive_relative`. |
| Optional vars | `docker_image_artifact_system_name`, `docker_image_artifact_tarball_name`, `docker_image_artifact_checksum_algorithm` (`sha256`), `docker_image_artifact_tag_length` (`12`), `docker_image_artifact_image_repository`, `docker_image_artifact_content_tag_command`, `docker_image_artifact_content_tag_required` (`false`). |
| Tags | none; caller supplies `image`. |
| Publishes / registers | `docker_image_artifact_archive`, `_checksum`, `_checksum_slice`, `_tag`, `_image_name`; a wrapper may alias these to `nixos_image_artifact_*`. |
| Idempotency / verification | all tasks are read-only (`delegate_to: localhost`, `become: false`); a missing artifact fails before the pipeline; the shared tag command is asserted against the checksum slice; second run `changed=0`. |
| Wrapper keeps | the Unix_dotfiles source dir, `NikolaiGogol`, the tarball/result path, the `ds-omega/nikolai-gogol` repository, the shared `invoke` command and the “build with make” failure hint. |

### 4.8 `generic_docker_image_transfer`

| Item | Contract |
|---|---|
| Purpose | Push the artifact from the control node to a target staging directory under a content-addressed filename. |
| Required vars | `docker_image_transfer_source_archive`, `docker_image_transfer_remote_dir`. |
| Optional vars | `docker_image_transfer_checksum` (`true`), `docker_image_transfer_compress` (`false`), `docker_image_transfer_delete` (`false`), `docker_image_transfer_dest_port`, `docker_image_transfer_rsync_opts`, `docker_image_transfer_require_rsync` (`true`), `docker_image_transfer_install_rsync` (`false`), `docker_image_transfer_artifact_checksum`. |
| Tags | none; caller supplies `image`. |
| Publishes / registers | `docker_image_transfer_remote_archive`, transfer result. |
| Idempotency / verification | rsync `--checksum`; the destination name includes the checksum, so a re-run is a no-op; second run `changed=0`; rsync absence fails early unless installation is explicitly allowed. |
| Wrapper keeps | the zterra staging root, the `ssh -G` port-resolution policy needed by `synchronize`, the rsync policy and the artifact-fact mapping. |

### 4.9 `generic_docker_image_load`

| Item | Contract |
|---|---|
| Purpose | Import a staged rootfs tarball into Docker under a content tag, gated on `docker image inspect`. |
| Required vars | `docker_image_load_image_repository`, `docker_image_load_image_tag`, `docker_image_load_remote_archive`. |
| Optional vars | `docker_image_load_docker_binary` (`docker`), `docker_image_load_manage` (`true`), `docker_image_load_become` (`true`), `docker_image_load_become_user`, `docker_image_load_force` (`false`). |
| Tags | none; caller supplies `image`. |
| Publishes / registers | `docker_image_load_image`, inspect/import/verify results. |
| Idempotency / verification | inspect first; import only when absent or `force`; inspect again after import; second run `changed=0`; no `docker import` on a present tag. |
| Wrapper keeps | the `ds-omega/nikolai-gogol` identity, the TOS uid-0 become user, the compose prerequisite (`command: /init`, stop signal). |

### 4.10 `generic_compose_service`

| Item | Contract |
|---|---|
| Purpose | Render a compose project (compose + env), ensure mount sources, fail closed on a missing `type: file` source, validate and bring the service up/recreate idempotently. |
| Required vars | `compose_service_project_dir`, `compose_service_compose_template`, `compose_service_mounts`. |
| Optional vars | `compose_service_compose_file` (`docker-compose.yml`), `compose_service_env_template`, `compose_service_env_vars`, `compose_service_env_file` (`.env`), `compose_service_project_dir_mode` (`0750`), `compose_service_config_mode` (`0640`), `compose_service_validate` (`true`), `compose_service_manage` (`true`), `compose_service_pull` (`never`), `compose_service_recreate` (`auto`), `compose_service_docker_binary` (`docker`), `compose_service_become`, `compose_service_become_user`. |
| Tags | none; caller supplies `container`. |
| Publishes / registers | render results, mount inspection, validate result, compose status. |
| Idempotency / verification | compose/env templates notify a recreate handler with `recreate: auto`; directory sources created, file sources fail closed; `docker compose config -q` before up; second run `changed=0` when templates and mounts are unchanged. |
| Wrapper keeps | the privileged systemd-container template (`privileged`, `cgroup: host`, `cgroup_parent`, `network_mode: host`, `stop_signal: SIGRTMIN+3`, `command: /init`), the env keys, container/service/user names, mount list, project dir and TOS become user. |

### 4.11 `generic_container_edge_sync`

| Item | Contract |
|---|---|
| Purpose | Rsync a control-node checkout into a target bind directory and run a caller-supplied command inside a running container. |
| Required vars | `container_edge_sync_source_dir`, `container_edge_sync_remote_dir`, `container_edge_sync_container_name`, `container_edge_sync_command` (list/string). |
| Optional vars | `container_edge_sync_enabled` (`false`), `container_edge_sync_rsync_opts`, `container_edge_sync_delete` (`false`), `container_edge_sync_become`, `container_edge_sync_become_user`, `container_edge_sync_changed_when`. |
| Tags | none; caller supplies `edge_sync`. |
| Publishes / registers | sync result, in-container command result. |
| Idempotency / verification | rsync checksum; the in-container command's own change semantics are captured by a real `changed_when`, never a hard-coded `true` in the generic role; disabled means no work; second run `changed=0` only when the command is itself idempotent. |
| Wrapper keeps | the Unix_dotfiles source, container name, flake path/attribute, `nixos-rebuild test|switch`, enablement, and the safety policy. |

**RFC-0001 interaction.** `roles/nixos_edge_sync/tasks/main.yml` currently uses
`delete: true`, `changed_when: true` and `become_user: "{{ ansible_become_user |
default('root') }}"`. Those are known RFC-0001 defects, not invariants to
preserve. This RFC moves the mechanism; it does not silently fix the policy.
Phase D must either (a) pass the current project values explicitly to remain
byte-for-byte behaviour-preserving, or (b) land the safe defaults as an
RFC-0001 implementation change with its own acceptance. The RFC recommends (a)
for the extraction and (b) as the immediately following change, so the two
decisions stay separate.

### 4.12 Short YAML sketches (illustrative, not implementations)

**Sketch 1 — Phase A wrapper (`nikolaigogol_scripts` → `payload_dir_sync`).**

```yaml
# roles/nikolaigogol_scripts/tasks/main.yml — after Phase A
- name: Delegate the payload sync to the generic role
  ansible.builtin.import_role:
    name: generic_payload_dir_sync
  vars:
    payload_dir_sync_enabled: "{{ nikolaigogol_scripts_enabled }}"
    payload_dir_sync_source_dir: "{{ nikolaigogol_scripts_source_dir }}"
    payload_dir_sync_target_dir: "{{ nikolaigogol_scripts_dir }}"
    payload_dir_sync_excludes: "{{ nikolaigogol_scripts_rsync_excludes }}"
    payload_dir_sync_force: "{{ nikolaigogol_scripts_force }}"
    payload_dir_sync_manifest_role: nikolaigogol_scripts
    payload_dir_sync_env_template_path: "{{ role_path }}/templates/env.j2"
    payload_dir_sync_env_dest: .env
    payload_dir_sync_verify_shell_glob: "*.sh"
```

The wrapper keeps `defaults/main.yml` and `templates/env.j2`; the generic role
owns the manifest, drift guard, rsync, digest and syntax checks. No
`default(omit)` is used in role-include vars.

**Sketch 2 — storage wrappers (`zterra_mount` / `zterra_binds`).**

```yaml
# roles/zterra_mount/tasks/main.yml — after Phase B
- name: Delegate the mount unit to the generic role
  ansible.builtin.import_role:
    name: generic_systemd_mount_unit
  vars:
    systemd_mount_unit_device: "{{ zterra_mount_device }}"
    systemd_mount_unit_path: "{{ zterra_mount_root }}"
    systemd_mount_unit_fstype: "{{ zterra_mount_fstype }}"
    systemd_mount_unit_options: "{{ zterra_mount_options }}"
    systemd_mount_unit_provision: "{{ zterra_mount_provision }}"
    systemd_mount_unit_description: "zterra NVMe data volume"
```

```yaml
# roles/zterra_binds/tasks/main.yml — after Phase B
- name: Delegate the bind units to the generic role
  ansible.builtin.import_role:
    name: generic_bind_mount_units
  vars:
    bind_mount_units_mounts: "{{ zterra_binds_mounts }}"
    bind_mount_units_retired_units: "{{ zterra_binds_retired_units }}"
    bind_mount_units_mount_dep: "{{ zterra_binds_mount_dep }}"
    bind_mount_units_module_tmpdir: "{{ zterra_binds_module_tmpdir }}"
```

**Sketch 3 — image and compose wrappers.**

```yaml
# roles/nixos_image_artifact/tasks/main.yml — after Phase C
- name: Delegate artifact identity to the generic role
  ansible.builtin.import_role:
    name: generic_docker_image_artifact
  vars:
    docker_image_artifact_source_dir: "{{ nixos_image_artifact_source_dir }}"
    docker_image_artifact_archive_relative: "{{ nixos_image_artifact_archive_relative }}"
    docker_image_artifact_image_repository: "{{ nixos_image_artifact_image_repository }}"
    docker_image_artifact_content_tag_command: "{{ nixos_image_artifact_content_tag_command }}"
    docker_image_artifact_content_tag_required: "{{ nixos_image_artifact_content_tag_required }}"
- name: Publish the legacy artifact facts
  ansible.builtin.set_fact:
    nixos_image_artifact_archive: "{{ docker_image_artifact_archive }}"
    nixos_image_artifact_checksum: "{{ docker_image_artifact_checksum }}"
    nixos_image_artifact_tag: "{{ docker_image_artifact_tag }}"
    nixos_image_artifact_image_name: "{{ docker_image_artifact_image_name }}"
```

```yaml
# roles/nixos_container/tasks/main.yml — after Phase D
- name: Delegate compose lifecycle to the generic role
  ansible.builtin.import_role:
    name: generic_compose_service
  vars:
    compose_service_project_dir: "{{ nixos_container_project_dir }}"
    compose_service_compose_template: "{{ role_path }}/templates/docker-compose-system.yml.j2"
    compose_service_env_template: "{{ role_path }}/templates/env.j2"
    compose_service_mounts: "{{ nixos_container_mounts }}"
    compose_service_manage: "{{ nixos_container_manage_compose }}"
```

## 5. Makefile abstraction

### 5.1 Current pattern (evidence)

`Makefile.Steps` is the engine. It defines `STEP_TAGS`, `PLAYBOOK`,
`VERIFY_PLAYBOOK`, `INVENTORY`, `ANSIBLE_CONFIG`, `ANSIBLE_ROLES_PATH`,
`COMPOSE`, `SSH_TARGET` and `EXTRA_ARGS`; includes `Makefile.Log`; and provides
`help`, `run`, `dry`, `verify`, `up`, `down`, `shell`, `shell-ssh`, `logs` and
`clean` (`Makefile.Steps:1-72`). A per-layer file is a small preamble:

```make
STEP_TAGS := image
PLAYBOOK := deploy-nikolaigogol.yml
VERIFY_PLAYBOOK := verify-nikolaigogol.yml
include Makefile.Steps
```

The nine current files are 4–33 lines (the longer ones carry comments or
extra helpers: `Makefile.NixosContainer` has `connect-container`, `ssh-container`
and `ps`; `Makefile.BackupTos` has `inspect`). The repetition is the
`STEP_TAGS`/`PLAYBOOK`/`VERIFY_PLAYBOOK` triple plus the include.

Contract details that must not change:

- **Inventory selection:** `INVENTORY=hosts.ini` is E2E; `INVENTORY=tests/integration/inventory.ini`
  is the mock. It is an engine variable, never a per-layer default.
- **Log labels:** `LOG_LABEL` defaults to `STEP_TAGS` (`Makefile.Log`), and
  `run`/`dry`/`verify` append `-dry`/`-verify`. Logs go to
  `logs/<timestamp>-<label>.log` and `logs/latest.log`.
- **`EXTRA_ARGS`** is forwarded verbatim to every ansible-playbook invocation.
- **`dry`** is `--check --diff`; **`verify`** runs `VERIFY_PLAYBOOK` without
  `--tags`; **`run`** applies `--tags $(STEP_TAGS)`.
- `ANSIBLE_CONFIG`, `ANSIBLE_ROLES_PATH` and the mock `docker compose` helpers
  remain engine concerns.

### 5.2 Recommendation: a `Makefile.Layer` include contract

Keep `Makefile.Steps` as the engine and add a thin prelude, `Makefile.Layer`:

```make
# Makefile.Layer — prelude for a per-layer file.
LAYER := $(if $(LAYER),$(LAYER),$(STEP_TAGS))
STEP_TAGS := $(if $(STEP_TAGS),$(STEP_TAGS),$(LAYER))
PLAYBOOK ?= HomeServer__HomeAssistant.yml
VERIFY_PLAYBOOK ?= verify-terra.yml

include Makefile.Steps

.PHONY: layer-info
layer-info:
	@echo "layer: $(LAYER)"
	@echo "tags: $(STEP_TAGS)"
	@echo "playbook: $(PLAYBOOK)"
	@echo "verify: $(VERIFY_PLAYBOOK)"
```

The immediate `if` form lets a layer file set either `LAYER` or
`STEP_TAGS` without a recursive `?=` cycle; when neither is set both stay
empty and `layer-info` prints an empty tag for the caller to fix. A layer file
becomes one to three lines:

```make
# Makefile.Zterra
LAYER := zterra
include Makefile.Layer
```

```make
# Makefile.NixosImage
LAYER := image
PLAYBOOK := deploy-nikolaigogol.yml
VERIFY_PLAYBOOK := verify-nikolaigogol.yml
include Makefile.Layer
```

`Makefile.NixosContainer` keeps its `CONTAINER_*` variables and helper targets,
and replaces its last line with `include Makefile.Layer`. `Makefile.BackupTos`
keeps `inspect`. `Makefile.Log` is unchanged and is still included exactly once
through `Makefile.Steps`.

Add `make layers` to the root `Makefile`: an explicit `LAYERS` list (not a
`wildcard`, so `Makefile.Steps`/`Makefile.Log` are not mistaken for layers)
invokes each file's `layer-info` target and prints a table of tag, playbook and
verify playbook. This gives discovery without a dispatcher.

Why this over a `make layer STEP=<tag>` entry point:

| Option | Pros | Cons | Decision |
|---|---|---|---|
| `Makefile.Layer` include | preserves `make -f Makefile.<Step>` muscle memory and per-layer helper targets; zero mapping table; smallest diff; `Makefile.Steps` unchanged | nine tiny files remain | **Recommended** |
| single `make layer STEP=<tag>` | one command, one place | needs a tag→playbook map, argument validation and special cases for `connect-container`/`inspect`/`scripts-pull`; loses per-layer defaults and tab-completion; harder to keep `make -f` docs accurate | Not now |
| generator | removes repetition | adds a build/regenerate step, generated files in review, and a second source of truth; with nine files the repetition is one line each | **Not needed** |

A generator becomes reasonable only when the layer count grows substantially
(for example, more than ~20) or when the same layer matrix is generated for
several consumers. The current repetition does not justify it.

### 5.3 Behaviour-preservation rules for the Makefile change

- `Makefile.Layer` sets only defaults; it must not override an explicit
  `STEP_TAGS`, `PLAYBOOK` or `VERIFY_PLAYBOOK` in a layer file. The `?=` order
  above preserves that.
- No layer file sets `INVENTORY`; no layer file changes `EXTRA_ARGS`, logging
  or the `--check`/dry semantics.
- `make -f Makefile.<Step> help` must print the same targets and the same
  `Step: <tag>` line (now including `LAYER` if desired, but not replacing it).
- Migrate one file first (for example `Makefile.Zterra`), diff `make help` and
  `make -n run`, then convert the rest.
- The old four-line form remains valid indefinitely: it still includes
  `Makefile.Steps` directly. No big-bang conversion is required.

## 6. Where the library lives

Options:

| Option | Versioning | Sharing across hosts/repos | Tests | Secrets | Release overhead |
|---|---|---|---|---|---|
| **A. In-repo `roles/generic_*`** (recommended now) | one repo version; no extra pin | copy/submodule/collection extraction later; not directly consumable elsewhere | `tests/unit` and integration run in this repo; one `make unit` | generic roles never read vaults; consuming repo keeps secrets | none |
| **B. Separate Ansible collection/repo** | independent SemVer and tags | clean `ansible-galaxy collection install`; multiple repos | separate CI; this repo tests against a pinned collection version | collection must never hold secrets; consumers own them | tag, changelog, release, compatibility matrix, galaxy/install wiring |
| **C. Hybrid: in-repo now, collection-ready conventions** | in-repo now; extraction later keeps names stable | extraction is mechanical if no repo-local lookups | same as A now; collection CI later | same as A | deferred |

**Recommendation: C, implemented as A.** Keep the generic roles in this
repository under `roles/generic_*`, but write them as if they were a collection:
capability-based role names, no repo-local lookups, no host/product literals,
explicit required vars, no vault reads, no dependency on this repo's
`group_vars`, and templates supplied by the caller or colocated with the role.
This gives sharing and testability now without assuming publication or paying a
release process. Extract to a collection when a second repository needs more
than a handful of roles, or when the release cadence diverges (§10 Q8).

Do **not** copy generic roles into another repo as the sharing mechanism, and do
**not** publish anything as part of this RFC.

## 7. Migration plan

Event order (no playbook reorder):

```
Phase A  payload_dir_sync
             │
Phase B  btrfs_layout → systemd_mount_unit → bind_mount_units → docker_storage_root
             │
Phase C  docker_image_artifact → docker_image_transfer → docker_image_load
             │
Phase D  compose_service → container_edge_sync
             │
Phase E  Makefile.Layer
```

Every phase is behaviour-preserving and independently revertible. A phase is
done only when the wrapper still carries the old role name, the playbook still
lists the same role in the same order with the same tags, and the second run is
`changed=0`. No phase changes an ADR, group vars, secrets or the deployment
model.

### Phase A — `payload_dir_sync` (first proof)

| Item | Detail |
|---|---|
| Files | new `roles/generic_payload_dir_sync/{defaults,tasks}/`; `roles/nikolaigogol_scripts/tasks/main.yml` becomes a thin import; `defaults/main.yml` and `templates/env.j2` stay in the wrapper. |
| Wrapper | maps every `nikolaigogol_scripts_*` input to `payload_dir_sync_*`; keeps `manifest_role: nikolaigogol_scripts`, the `.env` template path, the project excludes and the docker/make verification commands. |
| Tests | new `tests/unit/test_generic_roles.py` contract tests; update `tests/unit/test_nikolaigogol_scripts_step.py` to assert the wrapper maps to the generic role and that the manifest/drift logic lives in `roles/generic_payload_dir_sync`; keep all playbook wiring/tag tests. |
| Tag/order invariants | `deploy-nikolaigogol.yml` still lists `nikolaigogol_scripts` after `nixos_container`, tags `[scripts, debug]`, never `container`; `--list-tasks --tags scripts,debug` unchanged. |
| Rollback | restore `roles/nikolaigogol_scripts/tasks/main.yml` from base HEAD; the generic role is unused. No target state changes. |
| Deprecation | `nikolaigogol_scripts` remains the stable name; no removal. The generic role is the first proof that a second parameter set can drive it (two-host fixture, §8). |

Phase A is the **first implementation slice** and the only slice this RFC
proposes to start immediately after acceptance.

### Phase B — storage roles

| Item | Detail |
|---|---|
| Files | new `generic_btrfs_layout`, `generic_systemd_mount_unit`, `generic_bind_mount_units`, `generic_docker_storage_root`; the four `zterra_*` task files become thin imports; their templates move to the generic roles; `zterra_*` defaults stay. |
| Wrapper | `zterra_mount_*`, `zterra_layout_*`, `zterra_binds_*`, `zterra_docker_data_*` names and values remain the public interface; each wrapper maps them to the capability vars. |
| Tests | split `tests/unit/test_zterra_step.py`: generic contract tests move to `test_generic_roles.py`; Terra-specific assertions (paths, `/nix` + `/tmp` bind set, retired `var-log.mount`, 5 GiB floor) stay in `test_zterra_step.py` but point at the wrappers/defaults. |
| Tag/order invariants | Layer 0 order `backup_tos` first, then the zterra roles, then `bootstrap_nix`/`bootstrap_docker`; Layer 1 `zterra_mount → zterra_layout → zterra_docker_data → image`; tags `[zterra, storage]`, `[zterra, storage, image]`, `[zterra, storage, docker, image]` unchanged. |
| Rollback | per role: restore the wrapper task file. Storage state on the target is unchanged because the rendered units/drop-ins are the same. |
| Deprecation | `zterra_*` survives through at least Phase E; renaming or removing it needs a separate RFC and a second consumer. |

### Phase C — image roles

| Item | Detail |
|---|---|
| Files | new `generic_docker_image_artifact`, `generic_docker_image_transfer`, `generic_docker_image_load`; `nixos_image_*` task files become imports; defaults stay in the wrappers. |
| Wrapper / fact aliases | the generic roles publish `docker_image_*` facts; the `nixos_image_artifact` wrapper aliases them to `nixos_image_artifact_archive`, `_checksum`, `_tag`, `_image_name` so `nixos_image_sync`/`nixos_image_load`/`nixos_container` and `group_vars/nikolaigogol/vars.yml` need no edit. `nixos_image_sync` aliases `nixos_image_sync_remote_archive`; `nixos_image_load` keeps its legacy variable names. |
| Tests | update `tests/unit/test_nixos_image_step.py` to target the generic role paths for tag/slice/port logic and keep the fixture tag (`ecfcf1d2a1e3`) and the compose/env invariants in the project tests; add an alias test that the legacy facts equal the generic facts. |
| Tag/order invariants | `image` still runs artifact → transfer → load; artifact stays control-node-only; load stays last; `TAGS=image` still self-sufficient with the zterra roles. |
| Rollback | restore the three wrapper task files; aliases disappear with them; no image or target state changes. |
| Deprecation | `nixos_image_*` names and `nixos_image_artifact_*` facts remain for at least one phase; a future rename needs a compatibility story. |

### Phase D — `compose_service` and `container_edge_sync`

| Item | Detail |
|---|---|
| Files | new `generic_compose_service`, `generic_container_edge_sync`; `nixos_container/tasks/main.yml` and `nixos_edge_sync/tasks/main.yml` become imports; `nixos_container` keeps its compose/env templates, handlers, defaults and helper Makefile targets. |
| Wrapper | `compose_service` gets the project compose/env templates as paths, the mount list and the lifecycle flags; the privileged-systemd flags stay in the project template, not in the generic role. `container_edge_sync` gets the Unix_dotfiles source/remote, container name, flake path/attr and an explicit command list. |
| Tests | move the compose systemd invariants (`privileged`, `cgroup: host`, `network_mode: host`, `stop_signal`, `command: /init`) to a project-template test; add a neutral two-service compose fixture for the generic role; assert the generic role has no `NikolaiGogol`/`nixos-rebuild` literals. For edge sync, assert the generic role's default `delete: false` and real `changed_when`, and a wrapper test that the project policy is explicit. |
| Tag/order invariants | `container` still selects `nixos_container`; `scripts`/`debug` still exclude it; `edge_sync` stays inert unless `nixos_edge_sync_enabled=true`; no role moves. |
| Rollback | restore the two wrapper task files. If Phase D also adopts RFC-0001's safe edge defaults, rollback is the wrapper's explicit old values, not a generic-role edit. |
| Deprecation | role names stay; RFC-0001 owns the edge-policy change and must not be smuggled into this phase. |

### Phase E — `Makefile.Layer`

| Item | Detail |
|---|---|
| Files | new `Makefile.Layer`; convert `Makefile.AccessSsh`, `Makefile.BackupTos`, `Makefile.DockerDeployment`, `Makefile.NixBootstrap`, `Makefile.NixosContainer`, `Makefile.NixosEdgeSync`, `Makefile.NixosImage`, `Makefile.NixosScripts`, `Makefile.Zterra`; add `layers` to the root `Makefile`. |
| Wrapper / compatibility | the old `include Makefile.Steps` form remains valid; conversion is file-by-file; `Makefile.Steps` is not edited beyond, at most, a comment pointing at `Makefile.Layer`. |
| Tests | new `tests/unit/test_makefile_layers.py` parses each layer file for `LAYER`/`STEP_TAGS`, `PLAYBOOK`, `VERIFY_PLAYBOOK`, `include Makefile.Layer`; a shell check compares `make -f <file> help` and `make -n run` before/after for one representative layer. |
| Tag/order invariants | `STEP_TAGS`/`LAYER` values are byte-identical to today; playbook role order is unaffected because Makefiles do not encode it. |
| Rollback | restore the nine preambles; `Makefile.Layer` can stay unused. |
| Deprecation | the four-line form is supported for the whole deprecation window; no generator. |

## 8. Testing strategy

### 8.1 Contract tests per generic role

For each generic role, `tests/unit/test_generic_roles.py` (new) should assert:

- **Interface:** required vars exist and are documented in `defaults`; optional
  vars have safe defaults; every default is namespaced with the capability
  prefix (with the `generic_` directory allowance from §4.1).
- **No host leakage:** the role's `defaults/`, `tasks/`, `templates/` and
  `vars/` contain none of the repo's host/product identifiers
  (`zterra`, `terra`, `NikolaiGogol`, `HomeServer__HomeAssistant`, `ds-omega`,
  `ds13`, `haos_ova`, `nixos-rebuild`) except in comments that explicitly say
  “caller supplies this”.
- **Parameter matrix:** at least two values per required parameter, including a
  non-`/zterra` path and a non-`NikolaiGogol` name; render the templates and
  assert the output changes only where expected.
- **Failure messages:** every `fail`/`assert` includes the parameter name and a
  remediation; test the message text, not just the task name.
- **Idempotency structure:** probes are `changed_when: false`; no generic role
  contains `changed_when: true`; a second-run fixture reports `changed=0` where
  the role can run locally.
- **Invariants:** the table in §3 is represented by an assertion or an explicit
  parameter (for example `bind_mount_units_module_tmpdir` not under `/tmp`,
  `compose_service` file-mount fail-closed, `docker_storage_root` inline
  restart, `payload_dir_sync_delete=false`).

### 8.2 Keep the structure guard

`tests/unit/test_repo_structure.py` is the repo's contract against silent
refactor breakage. Keep these assertions and update them with the migration:

- `test_deploy_nikolaigogol_role_order` and
  `test_deploy_nikolaigogol_role_tags`: the playbook still names the wrappers,
  so the order/tag lists should not change. If a wrapper is ever renamed, this
  test must change in the same commit, with a note.
- `test_zterra_enabled_in_layer0`: `backup_tos` first; all four `zterra_*`
  roles present with their tags.
- `test_role_variables_are_namespaced`: add the `generic_` prefix allowance, or
  use unprefixed directory names after Q2. Do not weaken the assertion for
  project wrappers.
- `test_referenced_roles_exist` / `assert_roles_valid`: the wrappers still have
  `defaults/main.yml` and `tasks/main.yml`.
- `test_privileged_roles_target_configured_become_user`: the TOS invariant
  stays; generic roles that escalate must carry a required `become_user`.

### 8.3 Integration fixtures

Use `/var/tmp` only, never a real bind source:

```
/var/tmp/generic-roles/<phase>/host-a/{src,dst}
/var/tmp/generic-roles/<phase>/host-b/{src,dst}
```

- `payload_dir_sync`: two source/target pairs with different excludes and env
  templates; run twice, assert the second run is `changed=0`, the manifest is
  stable, and a hand edit triggers the drift failure before rsync.
- `btrfs_layout`: cannot create btrfs in the mock; assert directory creation,
  the root-mount refusal and the free-space guard with `forbid_root_mount:
  false` and a `/var/tmp` root, as `tests/integration/playbook.yml` already
  does for `zterra_layout`.
- `systemd_mount_unit` / `bind_mount_units`: use a loopback or `tmpfs` mount in
  the privileged mock where available; otherwise assert the rendered unit and
  the fail-closed checks with `state`/`provision` gates.
- `docker_storage_root`: assert the rendered `daemon.json` and drop-ins; the
  daemon restart is E2E-only.
- image roles: use `tests/integration/fixtures/minimal-rootfs.tar.xz`; keep the
  `ecfcf1d2a1e3` tag; `nixos_image_load_manage=false` in the mock.
- `compose_service`: `manage=false` in the mock, validate only; the systemd
  container start is E2E-only.
- `container_edge_sync`: disabled by default; a local fixture tests the rsync
  half without Docker.

### 8.4 “Same role, two hosts” fixture

The genericity proof is a single generic role invoked twice with different
path/name overrides, not a second real host:

```yaml
# tests/integration/generic-two-hosts.yml — sketch
- hosts: localhost
  tasks:
    - import_role:
        name: generic_payload_dir_sync
      vars:
        payload_dir_sync_source_dir: /var/tmp/generic-roles/host-a/src
        payload_dir_sync_target_dir: /var/tmp/generic-roles/host-a/dst
        payload_dir_sync_manifest_role: host_a
    - import_role:
        name: generic_payload_dir_sync
      vars:
        payload_dir_sync_source_dir: /var/tmp/generic-roles/host-b/src
        payload_dir_sync_target_dir: /var/tmp/generic-roles/host-b/dst
        payload_dir_sync_manifest_role: host_b
```

The fixture passes when both trees are correct, neither run references a
project-specific name, and the role code is the same for both. Repeat the shape
for one storage role (two fake roots) and one compose role (two projects).

### 8.5 Lint and gates

- `nix develop --command python3 -m pytest tests/unit -q` — the structure guard
  and contract tests.
- `make check` — syntax-check all four playbooks.
- `ansible-lint` — no new violations; generic roles must not add
  `command-instead-of-module`/`no-changed-when` exemptions that hide a defect.
- Optional: `make -f Makefile.<Step> help` and `make -n run` before/after for
  the Makefile phase.

Known environment-only failure: `test_shared_content_tag_command_matches_fixture`
fails when `~/.bookmarks/shared-scripts` or `invoke` is unavailable. It is not
caused by this RFC and must not be “fixed” by weakening the test.

## 9. Non-goals and risks

### 9.1 Non-goals

- Changing ADR 0001–0005, their status, or the deployment model.
- Publishing a collection or role to Galaxy/another repository.
- Rewriting working roles for purity (for example, making `backup_tos` a
  generic backup framework).
- Changing TOS 6 behaviour: the privilege preflight, apt mirror, checkouts,
  `become_user`, paths and `nofail` semantics stay as they are.
- Fixing RFC-0001's edge-sync defects inside this RFC; that is RFC-0001's
  implementation decision.
- Adding a second real host, new secrets, a new inventory or a new layer.
- Committing, setting `reviewed-by`, or changing playbooks/Makefiles in this
  documentation-only change.

### 9.2 Risks and mitigations

| Risk | Why it could happen | Mitigation |
|---|---|---|
| Over-abstraction | extracting `bootstrap_*`, `backup_tos` or `access_sftp` without a second consumer | require a second parameter set or second consumer before extraction; keep single-use logic in the project; the inventory explicitly marks them non-generic. |
| TOS quirks leak into generic roles | copying `become_user: root`, `/zterra`, `nixos-rebuild` or TOS `install` shims into a generic default | no-host-literal contract test; required `become_user`; TOS policy only in wrappers; code review against §3. |
| Tag/ordering regression | a wrapper is renamed or a generic role is added to the playbook with its own tags | playbook role names/tags stay; `test_repo_structure` order/tag tests; `--list-tasks --tags` before/after diff. |
| Test-matrix explosion | two values × every optional var × every phase | pairwise parameter tests plus one two-host fixture, not a full cartesian product; phase-scoped fixtures. |
| Wrapper drift | a wrapper gradually grows a second copy of the mechanism | wrapper cap: defaults/mapping/template only; unit test asserts the wrapper imports the generic role and contains no sync/guard/restart task body. |
| Shared-collection release overhead | extracting too early to a separate repo | in-repo now (§6); revisit only when a second repo needs several roles or the cadence diverges. |
| Fact-name breakage | generic facts replace `nixos_image_artifact_*` / `nixos_image_sync_remote_archive` | alias facts in the wrapper, tested in Phase C; keep group vars untouched. |
| Hidden behaviour change | “cleanup” while moving code (delete, changed_when, defaults, order) | phase gate: identical rendered units/templates, `changed=0`, before/after task list; RFC-0001 fixes are separate. |
| Template lookup mistakes | a wrapper template is not found after the code moves to the generic role | pass absolute template paths from the wrapper (`role_path`), or colocate the template in the generic role when it is policy-free; contract tests render both. |

## 10. Open questions

1. **In-repo vs collection.** Should the library live in this repo under
   `roles/generic_*`, or in a separate Ansible collection/repo? *Decision owner:
   Architect + repository owner.* Default if unanswered: in-repo, collection-ready
   conventions (§6). This decides distribution and versioning, not the role
   interfaces.
2. **Naming prefix.** Is `generic_` the right directory prefix, or should the
   roles be unprefixed (`roles/payload_dir_sync`)? The public variable prefix is
   `<capability>_*` either way. *Decision owner: Architect.* Default: unprefixed
   variables, `generic_` directory marker with the structure-test allowance.
3. **Do `zterra_*` names survive as facades?** Keep the four `zterra_*` names
   indefinitely as the project-facing interface, or remove them after the
   migration? *Decision owner: Architect + user.* Default: keep them through
   Phase E and at least one release; removal needs a separate RFC.
4. **How much of `nixos_container` is generic?** The render/mount/lifecycle
   mechanism is generic; the privileged systemd-container flags and env keys are
   project policy. Is there a second compose service that would justify more
   (for example, health checks or profiles)? *Decision owner: Architect.*
   Default: only the mechanism in this RFC; the template stays project-owned.
5. **Is `bootstrap_*` in scope?** `bootstrap_docker` and `bootstrap_nix` carry
   TOS-specific `install` shims and apt policy. Extract a
   `host_package_manager_bootstrap`, or leave them host-specific? *Decision
   owner: Architect.* Default: leave them out of this library until a second
   host needs the same mechanism.
6. **Compatibility policy.** How long do legacy role names, variables and facts
   remain? *Decision owner: Architect.* Default: wrappers and aliases for at
   least one phase plus one release; no removal without a new RFC and a
   deprecation note in the README.
7. **Makefile include vs generator.** `Makefile.Layer` include is recommended;
   a generator is not needed at nine layers. At what layer count or consumer
   count does that change? *Decision owner: Architect + user.* Default: include;
   revisit above ~20 layers or when a second repo consumes the matrix.
8. **Who is the second consumer?** A second host or repository is the strongest
   proof of genericity and the trigger for a collection. Which host/repo is it,
   and when? *Decision owner: user.* Default: the two-parameter-set fixture is
   the short-term proof; no second real host is assumed.

## 11. Acceptance and rollout

### 11.1 What makes this RFC accepted

1. The inventory in §2 is confirmed against the roles at base HEAD (16 roles,
   10 generic in scope, the rest explicitly host/project-specific).
2. The generic interfaces in §4 are accepted, including which vars are required
   and what the wrapper keeps.
3. Q1 (location), Q2 (naming), Q3 (`zterra_*` facades) and Q7 (Makefile include
   vs generator) are decided; the remaining questions may keep their defaults.
4. The behaviour-preservation rule is accepted: no role code, playbook, tag,
   order or rendered artifact changes in the extraction.
5. The Phase A scope is accepted as the first implementation slice.
6. The test plan (§8) is accepted, including the `generic_` namespacing
   allowance and the known environment-only failure.

### 11.2 First implementation slice — Phase A only

Phase A is the smallest end-to-end proof:

- extract `roles/generic_payload_dir_sync/` from `roles/nikolaigogol_scripts`;
- keep `roles/nikolaigogol_scripts` as a thin wrapper with its defaults,
  `templates/env.j2`, tags and playbook position;
- add the generic contract tests and the two-host payload fixture;
- run `make unit`, `make check`, `ansible-lint`, and the payload integration
  fixture twice (second run `changed=0`);
- diff `--list-tasks --tags scripts,debug` and the rendered `.env`/manifest
  against base HEAD.

No other phase starts until Phase A is accepted and the RFC's Q1/Q2/Q3/Q7 are
answered.

### 11.3 Success measures

- A second consumer (a second parameter set now, a second host/repo later) uses
  the generic role **without forking its task body**.
- Every migrated capability reports `changed=0` on a second run with unchanged
  inputs.
- `test_repo_structure.py` role-order and tag assertions still pass; a
  before/after `--list-tasks --tags` diff is empty except for task names.
- `make check`, `ansible-lint` and `make unit` pass (the known env-only failure
  excepted).
- Wrappers contain no duplicated mechanism: defaults, mapping and templates
  only.
- `docs/rfc/RFC-0001-edge-iteration-workflow.md` remains the owner of edge
  policy changes; this RFC only moves the mechanism.

### 11.4 Rollout gates

| Gate | Evidence |
|---|---|
| Phase A accepted | wrapper diff, generic contract tests, two-run `changed=0`, unchanged tags/order. |
| Phase B accepted | four wrappers, generic tests, unchanged storage units/drop-ins, unchanged Layer-0/1 order. |
| Phase C accepted | three wrappers, fact aliases tested, fixture tag unchanged, image order unchanged. |
| Phase D accepted | compose template invariants still project-owned, edge role still inert by default, RFC-0001 policy untouched. |
| Phase E accepted | `Makefile.Layer` conversion, `make layers`, identical help/run output, no tag changes. |

Until all gates pass, the status of this RFC stays **Proposed** and the
implementation remains reversible at the wrapper boundary.
