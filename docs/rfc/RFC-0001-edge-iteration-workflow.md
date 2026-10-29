# RFC-0001 — Edge iteration workflow for `@NikolaiGogol` and `@Manilov`

| Field | Value |
|---|---|
| RFC | `RFC-0001` |
| Title | Edge iteration workflow for `@NikolaiGogol` and `@Manilov` |
| Status | **Proposed** |
| Date | 2026-10-28 |
| Author | Architect |
| Base HEAD | `004ee9e` (worktree carries the storage/container work plus uncommitted docs) |
| Scope | The edge-iteration contract for the `@NikolaiGogol` NixOS system container and the `@Manilov` HomeAssistant OS VM on `@terra`: upstream `@NikolaiGogol` scripts, `Virt_scripts_bootstrap`, `roles/nikolaigogol_scripts` (Phase 0), `roles/nixos_edge_sync`, and the hand-off to the image pipeline. **Documentation only** — no role, playbook, Makefile, ADR-status or `reviewed-by` change. |
| Supersedes | none |

Companion documents (read, not modified): `docs/HomeServer__StratoFrame__ConvPlatProv__NikolaiGogolDeployment_plan.md`, `docs/NikolaiGogol__DependencyLayers_plan.md`, `docs/adr/0001-HomeServer__HomeAssistant.md`–`0005-*.md`, `.agents/AGENTS.md`.

## 1. Summary / motivation

The deployment already has two speeds (deployment plan §1): a **fast edge
iterate** path and a **full chain redeploy**. What it does not have is a
contract that says which changes are allowed to exist only inside the running
container, which changes must be committed, and which implementation owns the
edge loop. Two implementations currently exist — `roles/nixos_edge_sync` and the
upstream `@NikolaiGogol` scripts — with different destructive behaviour and
different safety defaults.

This RFC:

1. records the current flow and its six concrete defects (evidence with
   `file:line`);
2. proposes **three loops and one promotion rule** (edge → edge-commit → image,
   with the VM as a separate stateful loop);
3. carves out a deliberately narrow **Phase 0 exception**: deploy the upstream
   `@NikolaiGogol` scripts **as-is** to `@terra` now, for inspection over SSH,
   and refactor afterwards.

Phase 0 is not an endorsement of the scripts. It is a reversible evidence step:
the user has tested the upstream scripts on their host and wants the same bytes
on `@terra` before any refactor. The scripts remain a debug surface, not the
deployment path.

## 2. Current state (evidence)

### 2.1 The upstream edge/full cycle

`switch-nixos.sh` is the only end-to-end cycle today:

| Line | Command | Effect |
|---|---|---|
| 13 | `make stop-system-container` | stop the running container |
| 14 | `make rm-system-container` | **remove** the container and its writable layer |
| 16 | `make --directory=~/.bookmarks/shared-configs/Unix_dotfiles build-${SYSTEM_NAME}` | full rootfs tarball build |
| 19 | `make import-nixos` | `docker import` the tarball as the content-tag image |
| 20 | `make start-system` | `docker compose up --detach` |
| 21 | `./connect.sh` | `docker exec … bash` into the container |

After connecting, the user still has to activate the new system **manually
inside the container** (`switch-nixos.sh:23-25`, TODO: `make
switch-NikolaiGogol-system`). So even the "full" path ends with a manual step.

### 2.2 `@Manilov` is a libvirt VM inside the `@NikolaiGogol` container

`Virt_scripts_bootstrap/install.sh:10-11` runs `virt-install --connect
qemu:///system` and `undefine.sh:3-4` runs `virsh -c qemu:///system`; the VM
disk is the HAOS qcow2 bind-mounted at `docker-compose-system.yml:19`. The
container is privileged with `cgroup: host` (`docker-compose-system.yml:7-9`),
which is what lets libvirt run inside it. `@Manilov` therefore has two layers of
state: the HAOS qcow2 (a host bind) and libvirt's own domain/NVRAM state (inside
the container).

### 2.3 The compose mounts are only three paths

`docker-compose-system.yml:16-19` mounts:

| Source | Container target | Kind |
|---|---|---|
| `${UNIX_DOTFILES:?error}` | `/home/${CONTAINER_USERNAME:-root}/.bookmarks/shared-configs/Unix_dotfiles` | directory |
| `${VIRT_SCRIPTS_BOOTSTRAP:?error}` | `/home/${CONTAINER_USERNAME}/.bookmarks/Virt_scripts_bootstrap` | directory |
| `${HOME_ASSISTANT_IMAGE:?error}` | `/opt/HomeServer__HomeAssistant/haos_ova.qcow2` | file |

There is **no** mount for `/var/lib/libvirt` (or `/run/libvirt`, or the NVRAM
directory). The HAOS qcow2 survives a recreate because it is a bind source;
libvirt's domain definitions and NVRAM do not.

### 2.4 What survives `docker rm` today

| State | Location | Survives container recreate? |
|---|---|---|
| HAOS qcow2 | host bind (`HOME_ASSISTANT_IMAGE`) | yes |
| `Unix_dotfiles` checkout | host bind | yes |
| `Virt_scripts_bootstrap` | host bind | yes |
| libvirt domain definitions | `/var/lib/libvirt/qemu` (container layer) | **no** |
| UEFI/NVRAM variables | `/var/lib/libvirt/qemu/nvram` (container layer) | **no** |
| `virsh edit` changes | container layer | **no** |
| ad-hoc `/etc`, packages, units | container layer | **no** |
| `nixos-rebuild` generations | container layer | **no** |

This is the core reason the current "fast" path is not actually fast: it pays
for a full image rebuild and throws away every non-bind change.

## 3. Problems

The six findings below are the reason this RFC exists. Line references are to
the files as read on 2026-10-28.

### 3.1 Wrong granularity

`switch-nixos.sh:13-21` stops, removes, rebuilds the full rootfs, imports and
recreates the container for a one-line config edit. The granularity is the
**image**, not the configuration. A pet config change costs a tarball build plus
a container recreate, and the recreate destroys state (§3.2).

### 3.2 Container recreation destroys libvirt state

`switch-nixos.sh:14` removes the container. The compose file mounts only the
three paths at `docker-compose-system.yml:16-19`; `/var/lib/libvirt` is not one
of them. The `@Manilov` domain definition, NVRAM and any `virsh edit` changes
live in the container's writable layer and are lost. The qcow2 disk survives,
so the failure is silent: the VM comes back with a fresh identity rather than a
missing disk.

### 3.3 Two competing implementations

| Implementation | What it does | Evidence |
|---|---|---|
| `roles/nixos_edge_sync` | rsync the checkout into the bind mount, then `nixos-rebuild switch` inside the container | `roles/nixos_edge_sync/tasks/main.yml:10-30` |
| upstream scripts | stop/rm/build/import/start/connect, then a manual in-container switch | `switch-nixos.sh:13-25`, `connect.sh` |

The role defaults to `switch` (not `test`), the scripts default to destroying
and rebuilding, and neither is declared authoritative. There is no shared
promotion rule, so a change can look "deployed" while existing only in the
container.

### 3.4 `nixos_edge_sync` unsafe defaults

| Defect | Evidence | Consequence |
|---|---|---|
| `delete: true` | `roles/nixos_edge_sync/tasks/main.yml:16` | silently deletes files in the target bind directory, including manual edits made during debugging |
| `changed_when: true` | `roles/nixos_edge_sync/tasks/main.yml:27` | every run reports changed; idempotence is unobservable |
| `become_user: "{{ ansible_become_user | default('root') }}"` | `roles/nixos_edge_sync/tasks/main.yml:30` | on TOS 6 `root` is uid 9999 and unprivileged; a missing `ansible_become_user` drops privileges |
| default mode is `switch` | `roles/nixos_edge_sync/tasks/main.yml:22-26` | an edge experiment is promoted to a boot generation by default instead of being tested |

The same `become_user | default('root')` pattern appears in
`roles/nixos_container/tasks/main.yml:97,110,122`; it is masked today only
because `group_vars/terra/vars.yml` sets `ansible_become_user: terra`.

### 3.5 `@Manilov` scripts are destructive and hard-coded

| Finding | Evidence | Consequence |
|---|---|---|
| `undefine` deletes storage | `undefine.sh:4`: `undefine hass_qemu16 --nvram --remove-all-storage` | a "define/start" cleanup destroys the HAOS qcow2 |
| install has no network | `install.sh:23`: `--network none` | the generated definition has no NIC; `vmDefinition.xml:63-67` expects `tap0` + MAC `52:54:00:ed:0b:9f` |
| MAC prompt is disconnected | `getMacAddress.sh:3-5` asks for a MAC, but `install.sh` never accepts or sets one | the operator is told to do something the installer cannot consume |
| device is hard-coded | `Virt_scripts_bootstrap/Makefile:12`: `./UsbDevices/ZigbeeDongle.xml` | a missing file fails `make start`; adding a second device requires editing the Makefile |

### 3.6 Shell fragility

`switch-nixos.sh` has no `set -euo pipefail` (lines 1-26); `connect.sh` has no
shebang and no `set` (lines 1-15) and uses `info`/`fatal` (lines 10, 14) without
declaring `REQUIRES_FUNCS` — `switch-nixos.sh:11` requires only `info`, and
`connect.sh` runs as a separate process. `install.sh:3` has `set -e` alone.
Failures can be masked or turn into undefined-function errors.

## 4. Proposal — three loops, one promotion rule

```
edit source
   │
   ├─ edge (test) ──────────────► nixos-rebuild test --flake …#NikolaiGogol
   │                               activates now; NO boot entry; ephemeral
   ├─ edge-commit (switch) ─────► nixos-rebuild switch --flake …#NikolaiGogol
   │                               boot generation inside the container only
   │
   └─ promotion: commit → pin → build tarball → content tag → import → recreate
                                   (image loop; authoritative)

@Manilov: virsh define/start from XML + qcow2 (separate stateful loop)
```

| Loop | Entry point | Runs where | Effect | Lifetime |
|---|---|---|---|---|
| **Edge** | `nixos-rebuild test --flake <flake>#NikolaiGogol` | inside the running container | activate the new system for this boot; no boot entry | ephemeral — lost on container recreate (and on reboot without a switch) |
| **Edge-commit** | `nixos-rebuild switch --flake <flake>#NikolaiGogol` | inside the running container | new boot generation inside the container | ephemeral with respect to container recreate; survives a plain restart |
| **Image** | build `Unix_dotfiles` → content tag → `docker import` → compose recreate | control node + `@terra` | new rootfs image, authoritative deploy | durable; reproducible from the pinned commit |
| **VM** | `virsh define`/`start`, `attach-device` | inside the container (libvirt `qemu:///system`) | `@Manilov` domain + disk | stateful; must survive container recreate via a bind or a redefine |

**One promotion rule.** A change is promoted only by **commit → pin → image
deploy**:

1. make and verify the change with the edge or edge-commit loop;
2. commit it to the source (`Unix_dotfiles`, and for VM definitions
   `Virt_scripts_bootstrap/vmDefinition.xml`);
3. pin the ref/commit;
4. build the tarball;
5. derive the content tag;
6. import and recreate the container.

Edge changes are **ephemeral**. Anything that lives only inside the container —
installed packages, `/etc` edits, systemd units, `virsh edit` changes, libvirt
generations, `nixos-rebuild` generations, shell history — is lost when the
container is recreated. There is no copy-out path in the promotion rule; the
source commit is the only promotion artifact.

## 5. Phase 0 exception — deploy as-is (accepted now)

### 5.1 Rationale

The user has tested the upstream scripts on their host and wants the **same
bytes** on `@terra` first, checked over SSH, before any refactor. Phase 0 is
therefore an explicit, bounded exception to the "one implementation" rule in §4
and §6. It installs an artifact for inspection; it does not make the scripts the
deployment path.

### 5.2 What Phase 0 does

Implemented by `roles/nikolaigogol_scripts` (tags `[scripts, debug]`):

1. Copy the upstream `ConvPlatProv-HomeServer__HomeAssistant/@NikolaiGogol`
   folder to `{{ zterra_root }}/local-/Projects/@NikolaiGogol/_scripts/`, i.e.
   `/zterra/local-/Projects/@NikolaiGogol/_scripts/`, with
   `ansible.posix.synchronize`.
2. Render `.env` from Ansible vars (the upstream `.env` is gitignored and
   contains host paths; it is never copied).
3. Copy every other included file byte-for-byte. No edits, no patches, no `sed`.
4. Guard drift, sync additively, render `.env`, then write `.deploy-state`
   (§5.4).

Phase 0 **is not** a container dependency:

- it adds **no bind mount** to `docker-compose-system.yml` — the three mounts at
  `docker-compose-system.yml:16-19` stay exactly as they are;
- the role uses tags `scripts` and `debug`, neither of which is implied by
  `container` (so `TAGS=container` does not copy scripts);
- it does not manage the compose lifecycle (`nixos_container_mounts` and
  `community.docker.docker_compose_v2` are absent); it only runs
  `docker compose config -q` as a validation.

The role default `nikolaigogol_scripts_source_dir` uses the
`~/.bookmarks/shared-projects/ChronoIndex/2026/ConvPlatProv-HomeServer__HomeAssistant/@NikolaiGogol`
spelling. That is the confirmed path (§9 Q1).

### 5.3 Rendered `.env` (exact keys and terra values)

The key set is the 11 keys rendered by
`roles/nikolaigogol_scripts/templates/env.j2`. The upstream `.env.example` also
has `IMAGE_NAME`; Phase 0 does not render it because the upstream Makefile
derives it from `NAMESPACE` / `IMAGE_BASE_NAME` / `IMAGE_TAG`
(`@NikolaiGogol/Makefile:18-20`).

| Key | Terra value |
|---|---|
| `PROJECT_NAME` | `HomeServer__HomeAssistant` |
| `SYSTEM_NAME` | `NikolaiGogol` |
| `BOOKMARKS` | `/zterra` |
| `UNIX_DOTFILES` | `{{ nixos_container_unix_dotfiles_dir }}` → `/zterra/local-/Projects/nikolaigogol/data/Unix_dotfiles` |
| `VIRT_SCRIPTS_BOOTSTRAP` | `{{ nixos_container_virt_scripts_dir }}` → `/zterra/local-/Projects/nikolaigogol/data/Virt_scripts_bootstrap` |
| `HOME_ASSISTANT_IMAGE` | `{{ nixos_container_home_assistant_image }}` → `/zterra/shared-/@Manilov/dotfiles-/_configs/HomeAssistant__/haos_ova.qcow2` |
| `CONTAINER_USERNAME` | `ds13` |
| `NAMESPACE` | `ds-omega` |
| `IMAGE_BASE_NAME` | `nikolai-gogol` |
| `IMAGE_TAG` | `latest` |
| `CONTAINER_NAME` | `HomeServer__HomeAssistant.NikolaiGogol` |

Notes:

- `IMAGE_TAG=latest` is deliberate for the **debug** surface: the upstream
  `import-nixos` keeps a `:latest` alias next to the content tag
  (`@NikolaiGogol/Makefile:35-37`). It is not the deploy identity; the image
  loop and verify path use content tags (§4, §7). `make -n image-name` in
  `_scripts` therefore prints `ds-omega/nikolai-gogol:latest` as long as no
  tarball is present to override it (`@NikolaiGogol/Makefile:19`).
- `HOME_ASSISTANT_IMAGE` above is the **current** `group_vars` value (unversioned
  `haos_ova.qcow2`). The versioned `haos_ova-16.3.qcow2` path is the dependency-layer
  proposal in `docs/NikolaiGogol__DependencyLayers_plan.md`, not an accepted
  value for this RFC. Phase 0 renders whatever `nixos_container_home_assistant_image`
  resolves to.
- `BOOKMARKS=/zterra` is the terra root. The two payload keys are absolute, so
  `BOOKMARKS` is retained only for upstream key compatibility; it is not used to
  derive them (upstream's relative layout is different).
- The three compose-source keys carry `:?error` in the upstream compose file;
  all three must be present or `docker compose config` fails closed.
- `.env` is rendered with mode `0600`.

### 5.4 Dirty-target / manifest rule

`_scripts` is a debug surface the user may edit on `@terra`, so Phase 0 applies
a drift guard before every sync:

1. Hash the target tree **without git**, excluding `.deploy-state`,
   `.deploy-state.*` and `.env`; compare with the manifest `tree_sha256`.
2. If it differs and `nikolaigogol_scripts_force` is not true, fail, list the
   drifted files (`sha256sum -c` over the recorded per-file digests) and stop
   **before** rsync. The override is explicitly
   `-e nikolaigogol_scripts_force=true`.
3. Sync with `delete: false` and the excludes below, so a failed run leaves the
   previous payload rather than a half-deleted one.
4. Render `.env`, then write `_scripts/.deploy-state`:

```yaml
role: nikolaigogol_scripts
source: <source dir on the control node>
tree_sha256: <sha256 over the target tree, excluding .env/.deploy-state*>
deployed_at: <UTC timestamp>
files: [<sha256sum output lines for the copied tree>]
```

- Excludes: `.git`, `.env`, `result-*`, `node_modules`, `.yarn/cache`. The copy
  preserves every included file byte-for-byte.
- `.env` is render output, excluded from the tree digest and re-rendered each
  run; a hand edit to `.env` is not preserved. Tracking `env_sha256` and the
  upstream `source_commit` is a refactor item (§6.3, §9 Q1), not Phase 0.
- `delete: false` means stale files are not removed; the drift report and the
  manifest are the visibility mechanism.

### 5.5 Remote verification

The role runs these on `@terra` after the sync; the same commands are the
control-node acceptance checks:

```sh
ssh terra 'cd /zterra/local-/Projects/@NikolaiGogol/_scripts \
  && for f in $(find . -name "*.sh" -type f); do bash -n "$f"; done'

ssh terra 'cd /zterra/local-/Projects/@NikolaiGogol/_scripts \
  && docker compose -f docker-compose-system.yml config -q'

ssh terra 'cd /zterra/local-/Projects/@NikolaiGogol/_scripts \
  && make -n image-name'
```

`make -n` prints the computed image name without importing or starting
anything. For the debug `.env` it prints `ds-omega/nikolai-gogol:latest`; that
is the upstream alias and does not change the content-tag deploy contract.

### 5.6 Risk note

The scripts call `sudo docker` and recreate the managed container
(`switch-nixos.sh:13-21`). They are a **debug** surface that can race the
Ansible-managed container (`nixos_container` / `community.docker.docker_compose_v2`);
two writers to the same container is undefined behaviour. They are **not the
deployment path** and must not be invoked by a playbook or a release target.

Phase 0 also does not claim the cycle runs end-to-end on `@terra`:
`switch-nixos.sh:16` hard-codes `~/.bookmarks/shared-configs/Unix_dotfiles`,
which is not a path Phase 0 creates on the TOS host, and `sudo docker` from
inside the container would need a Docker socket that is not mounted. Phase 0 is
for inspection and validation; the refactor in §6 resolves the build source and
the execution context. The role itself runs only `bash -n`, `docker compose
config -q` and `make -n image-name`; it never runs `switch-nixos.sh`.

## 6. Refactor (not in Phase 0)

### 6.1 Edge and full CLIs

- `edge.sh --test|--switch|--rollback|--status`:
  - `--test` (default): `nixos-rebuild test --flake <flake>#NikolaiGogol`, no
    boot entry;
  - `--switch`: commit the experiment into a container generation;
  - `--rollback`: `nixos-rebuild --rollback` (or switch to the previous
    generation);
  - `--status`: current generation, dirty checkout state, image tag, container
    and domain state.
- `full.sh`: the explicit destructive cycle (stop/rm/build/import/start), with
  a confirmation prompt and the same content-tag rule. It is not the default
  and not reachable from `edge.sh`.

### 6.2 `connect.sh` hardening

- add a shebang and `set -euo pipefail`;
- source the logging library and declare `REQUIRES_FUNCS info fatal` (or use
  plain `printf`), so `fatal` is defined in the process that calls it;
- retry on a real readiness signal (`docker inspect` health / `/init` state),
  not on an unconditional `make connect-nixos && exit 0`;
- expose a non-interactive mode for scripted checks; do not mask failure with
  `exit 0`.

### 6.3 Repo role

`roles/nixos_edge_sync` becomes the single managed edge implementation:

- `delete: false` by default; stale files are reported, and `--delete` is only
  enabled after the manifest guard proves a clean target or an explicit force is
  supplied;
- real `changed_when` from a registered rsync result / generation comparison, not
  `changed_when: true`;
- `become_user` without a `root` fallback: require an explicit
  `nixos_edge_sync_become_user` (or `ansible_become_user`) and assert it is
  non-empty; never default to TOS's uid-9999 `root`;
- `nixos_edge_sync_mode: test|switch`, default `test`;
- rollback support (`--rollback` / previous generation) and status output;
- carry forward the Phase 0 manifest improvements: record the upstream
  `source_commit` and the rendered `.env` digest (`env_sha256`), and only enable
  rsync `--delete` after a clean-manifest check or an explicit force.

**Decision: only one implementation survives.** After Phase 0 acceptance,
`nixos_edge_sync` owns edge sync + rebuild. The upstream `edge.sh` becomes a
thin operator wrapper (or is removed); `full.sh` remains only as the explicit
image-cycle CLI and must call the same build/content-tag commands as the Ansible
path. The Phase 0 copy of `switch-nixos.sh` / `connect.sh` is removed or reduced
to wrappers; there is no second rsync/rebuild implementation.

### 6.4 `@Manilov` (`Virt_scripts_bootstrap`)

- parameterize VM name, disk path, MAC, network mode, USB devices, vCPUs and
  memory (`manilov_*` vars); no hard-coded `hass_qemu16`, `tap0` or
  `ZigbeeDongle.xml`;
- make `vmDefinition.xml` the source of truth: define from it (or render it),
  rather than re-running `virt-install --print-xml` with flags that disagree
  with it;
- idempotent define: `virsh define` only when the XML digest changes; `virsh
  start` only when the domain is not running; `attach-device` only when the
  device is absent;
- `undefine` keeps storage by default (`virsh undefine <name> --nvram`); a
  separate explicit `purge` target requires confirmation and takes a backup of
  the qcow2 before `--remove-all-storage`;
- reconcile the network mode: `install.sh` and `vmDefinition.xml` must agree on
  `none` / `tap0` / `wifi-vepa`; `getMacAddress.sh` either feeds a parameterized
  MAC or is removed in favour of a var.

### 6.5 libvirt state

Two options, in order of preference:

1. bind `/var/lib/libvirt` (or a zterra path) into the container so domain
   definitions, NVRAM and libvirt state survive `docker rm`;
2. redefine the domain from `vmDefinition.xml` on every container start.

**Recommendation: do both.** The bind preserves live state and `virsh edit`
changes; the idempotent define reconstructs identity if the bind is missing or
reset. If NVRAM cannot be bind-mounted, the XML must point `<nvram>` at a
persistent path, or the loss of UEFI variables must be an accepted, documented
consequence. The qcow2 is already on a host bind and is not at risk.

## 7. Safety invariants

| Invariant | Enforced by |
|---|---|
| Edge changes never ship by copying files out | promotion rule: commit → pin → image deploy; no copy-out path |
| `nixos-rebuild test` is the default for edge | CLI `--test` default; `nixos_edge_sync_mode: test` |
| No `delete: true` against a dirty target | `delete: false` + manifest drift guard + explicit force |
| `undefine` never deletes storage | default `undefine --nvram`; `purge` is separate, confirmed and backed up |
| No key material on `@terra` | control-node-only key; scripts carry no credentials; `.env` excludes secrets |
| `_scripts` is not wired into compose | tag `scripts`; no bind mount; `container` does not imply `scripts` |
| One writer at a time | do not run the scripts during an Ansible deploy; the manifest/force gate makes a second run visible |
| Content tag in deploy/verify | the image loop and verify use content tags; `_scripts/.env` `IMAGE_TAG=latest` is the upstream debug alias only |
| libvirt state survives recreate | `/var/lib/libvirt` bind and/or idempotent define from XML |

## 8. Alternatives considered

### (a) Refactor first, deploy later

Cleaner end state, but it validates the refactor without the baseline the user
has already tested. It also delays any observation of the upstream scripts on
`@terra`, which is the evidence the refactor needs. Rejected for now; Phase 0
is the lower-risk first step.

### (b) Keep only the role, drop the scripts

Removes the duplicate implementation immediately, but discards the user's
tested debug surface and muscle memory before the role has been proven on the
real host. It also hides the hard-coded path and execution-context problems in
§5.6 instead of surfacing them. Rejected for now; the role becomes the single
implementation after Phase 0 evidence (§6.3).

### (c) Run edge work from the control node only

Keeps `@terra` free of scripts, but the edge loop must run where the container
runs: paths, `/var/lib/libvirt`, mounts and libvirt state are host/container
facts. A control-node-only loop does not exercise them, and it does not help the
VM state problem. Rejected.

### Why Phase 0-as-is wins for now

Phase 0 changes no role, playbook, Makefile or compose mount. It is reversible
(delete `_scripts`), produces direct evidence on the real host, and gives the
refactor a tested baseline. Its non-authoritative status is explicit: the
scripts are copied for inspection, not promoted to the deployment path.

## 9. Open questions

1. **Exact upstream path on the control node — resolved.** The canonical path
   is
   `~/.bookmarks/shared-projects/ChronoIndex/2026/ConvPlatProv-HomeServer__HomeAssistant/@NikolaiGogol`
   (`ConvPlatProv`, not `PlatConvProv`). The Phase 0 role default uses this
   path; it determines the copy source and the manifest's `source`.
2. **`_scripts` location — resolved.** The target is
   `/zterra/local-/Projects/@NikolaiGogol/_scripts/` (via
   `{{ zterra_root }}/local-/Projects/@NikolaiGogol/_scripts`), not under
   `nixos_container_project_dir` and not a compose bind source.
3. **Default edge mode.** This RFC proposes `test` as the default and reserves
   `switch` for an explicit edge-commit. Is `switch` ever expected as the
   default for a known-good rebuild?
4. **libvirt state: bind vs redefine.** This RFC recommends the
   `/var/lib/libvirt` bind **plus** idempotent define. Which is the accepted
   primary, and what is the bind path/ownership on `@terra`?
5. **VM network mode.** `install.sh:23` has `--network none`,
   `vmDefinition.xml:63-67` has `tap0` + MAC `52:54:00:ed:0b:9f`, and
   `install.sh:24` has a commented `wifi-vepa` option. Which is the target for
   `@Manilov`, and where does the MAC come from?
6. **Image-cycle build source on `@terra`.** `switch-nixos.sh:16` hard-codes
   `~/.bookmarks/shared-configs/Unix_dotfiles`. Does the refactored `full.sh`
   build on the control node (the Ansible model) or stage a checkout on
   `@terra`? Phase 0 deliberately does not provide that path.

## 10. Acceptance / rollout

### Phase 0 is done when

1. `_scripts` exists at `/zterra/local-/Projects/@NikolaiGogol/_scripts/` with
   the upstream `@NikolaiGogol` files, and `.deploy-state` records the source,
   tree digest, per-file digests and `deployed_at`.
2. Every included file matches the upstream source byte-for-byte (per-file
   sha256); `.git`, `.env`, `result-*`, `node_modules`, `.yarn/cache` are absent.
3. `.env` is rendered from vars with all keys in §5.3; `IMAGE_TAG=latest` is
   the expected debug value, not the deploy identity.
4. `bash -n` is clean for `switch-nixos.sh` and `connect.sh` (and any other
   copied `*.sh`).
5. `docker compose -f docker-compose-system.yml config -q` exits `0` on `@terra`.
6. `make -n image-name` exits `0` and prints a stable image name
   (`ds-omega/nikolai-gogol:latest` for the debug `.env`; the target is not
   used as the deploy identity).
7. `--list-tasks --tags container` does **not** include
   `nikolaigogol_scripts`, and the rendered `docker-compose-system.yml` is
   unchanged (no new mount).
8. The user confirms the result over SSH on `@terra`.
9. `nix develop --command python3 -m pytest tests/unit -q` is green (the docs
   must not break the structure guard).

Rollback for Phase 0 is simply removing `_scripts`; no role, playbook or
compose change was made.

### The RFC is implemented when

1. Phase 0 is accepted and the evidence is recorded.
2. `edge.sh` / `full.sh` exist with the modes in §6.1; `connect.sh` is hardened
   per §6.2.
3. `nixos_edge_sync` uses `delete: false`, real `changed_when`, a required
   non-`root` `become_user`, `mode: test|switch` and rollback.
4. Only one edge implementation survives; the Phase 0 copy is removed or reduced
   to a wrapper.
5. `@Manilov` is parameterized, `vmDefinition.xml` is the source of truth, the
   define is idempotent, `undefine` keeps storage, and `purge` is explicit and
   backed up.
6. libvirt state survives container recreation (bind and/or idempotent define),
   and the network mode is reconciled.
7. The safety invariants in §7 have tests or explicit verification steps, and
   the docs (this RFC plus the rollout plan) describe the resulting reality.

### Phase 0 — known as-is limitations

These are **expected** while Phase 0 deploys the upstream scripts unchanged.
They are inputs to the refactor in §6, not blockers for Phase 0 acceptance.

- `switch-nixos.sh` hard-codes
  `~/.bookmarks/shared-configs/Unix_dotfiles` for its
  `make --directory=...` build step. On `@terra` the checkout is at
  `/zterra/local-/Projects/nikolaigogol/data/Unix_dotfiles`; the deployed
  `.env` sets `UNIX_DOTFILES` for compose, but the build step ignores it.
- The scripts call `sudo docker`. On TOS 6 `terra` is already uid 0, so `sudo`
  may be absent; the remote check will reveal it.
- `connect.sh` never sources `REQUIRES_FUNCS`; `info` / `fatal` may be
  undefined on a bare TOS shell.
Diagrams: docs/EdgeIteration_scripts.puml

## Reverse flow — propagating on-@terra edits back

| Field | Value |
|---|---|
| Status | **Proposed** (documentation only; no role, Makefile, playbook or test change) |
| Scope | `_scripts` on `@terra` → control-node snapshot → owning git repo → pin → S0/S1 |
| Base HEAD | `004ee9e` (worktree dirty) |
| Invariants | extends §7; does not change Phase 0 (§5) or the promotion rule (§4) |

`@terra` has **no git, no GitHub access and no key**. A fix made on the target
cannot be pushed from the target, and it is not promoted by a copy-out path. The
reverse flow is **pull-based from the control node**: the control node is the
only party that can read the target over SSH and the only party that holds the
credential. Detection is already built in — the Phase 0 drift guard (§5.4) fails
when the target tree no longer matches `.deploy-state`. This section turns that
failure into a reviewed commit, a pin and a redeploy.

In one line:

```
detect drift → pull snapshot → diff in a worktree at the pin → validate
→ commit on a branch → push/PR → re-pin → S0/S1 deploy → .deploy-state rewritten
```

### 11.1 The detection signal is the drift guard

`roles/nikolaigogol_scripts/tasks/main.yml:82-141` hashes the target tree
(excluding `.env`, `.deploy-state`, `.deploy-state.*`) and compares it with the
manifest's `tree_sha256`. With `nikolaigogol_scripts_force=false` (the default,
`defaults/main.yml:25`) a mismatch **fails before rsync** and lists the
`FAILED` paths from the per-file digest check.

That failure is the signal that remote edits exist. It is not a reason to set
`force=true`.

- `make -f Makefile.NixosScripts dry` is the read-only-safe detector: the hash
  and drift tasks run under `--check` because they set `check_mode: false`. It
  makes no payload or manifest change, but the guard's staging tasks do write and
  remove a temporary `.deploy-state.drift` on the target.
- `.env` is excluded from the digest, so an edited remote `.env` is **not**
  detected. It is environment-specific and is never propagated (§11.5).
- Added files change the tree hash; deleted files change it too. Both are
  detected even though the pull cannot express a deletion (§11.6).
- A missing or corrupt `.deploy-state` makes the guard treat the target as clean
  and the role rewrites the manifest. Detection is blind in that case; compare the
  target against the pin manually.

### 11.2 The owning repository is the submodule, not the superproject

At base HEAD `@NikolaiGogol` is a **submodule** of
`ConvPlatProv-HomeServer__HomeAssistant`:

| Fact | Value |
|---|---|
| Submodule name | `ConvPlatProv__NikolaiGogol` |
| Submodule path | `@NikolaiGogol` |
| Submodule remote | `git@github.com:dsOmega-StratoFrame/ConvPlatProv__NikolaiGogol.git` |
| Superproject remote | `git@github.com:dsOmega-StratoFrame/ConvPlatProv-HomeServer__HomeAssistant.git` |
| Superproject pin (dependency plan §0) | `fd56f6bdd1c8b9f3820c223296f2fbd1aeb27a01` |
| Gitlink recorded at that pin | `e6bd5992595f74ed330cea540a6aa636e8220766` (`git rev-parse fd56f6b:@NikolaiGogol`) |

Consequence: `git worktree add` **must run in the submodule repository**
(`$SUPER/@NikolaiGogol`). A worktree of the superproject at `fd56f6b` contains a
gitlink, not the script files, so overlaying the snapshot there produces a
one-line `Subproject commit` diff. Commit the script content in the submodule
repo; bump the gitlink in the superproject afterwards (§11.3 step 6).

The scripts role copies `nikolaigogol_scripts_source_dir` as a working tree and
has **no pin variable** at base HEAD (`defaults/main.yml:9-25`). The pin is
therefore the control-node checkout commit, anchored by the superproject pin the
dependency layer resolves (`nixos_virt_scripts_ref` / `nixos_virt_scripts_commit`,
planned; the plan records `fd56f6b`). The manifest's
`source` records a path, not a commit (`tasks/main.yml:200`); recording
`source_commit` is the §6.3 refactor item.

### 11.3 Exact commands

All commands run on the control node. `@terra` is only ever the rsync source.

#### Step 0 — variables

```sh
TARGET_USER="${TARGET_USER:-terra}"
REMOTE_SCRIPTS="/zterra/local-/Projects/@NikolaiGogol/_scripts"
SUPER="${SUPER:-$HOME/.bookmarks/shared-projects/ChronoIndex/2026/ConvPlatProv-HomeServer__HomeAssistant}"
SUB="$SUPER/@NikolaiGogol"

# The dependency pin is a superproject commit. At base HEAD the dependency plan
# records fd56f6bdd1c8b9f3820c223296f2fbd1aeb27a01; when refs-update exists,
# read it from the pin var instead of retyping a sha.
PIN_SUPER="${PIN_SUPER:?set the pinned superproject sha (e.g. refs-list)}"
PIN_SUB="$(git -C "$SUPER" rev-parse "$PIN_SUPER:@NikolaiGogol")"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PULL="${XDG_CACHE_HOME:-$HOME/.cache}/nikolai-gogol/pull/$STAMP"
SNAPSHOT="$PULL/snapshot"
WORKTREE="$PULL/worktree"
mkdir -p "$SNAPSHOT"

git -C "$SUB" cat-file -e "$PIN_SUB^{commit}"
command -v rsync git
```

In this workspace `git` is reached through `nix develop --command git`; the
container PATH has no git. `rsync` must also exist on `@terra`; check with
`ssh "$TARGET_USER" command -v rsync` before the first pull.

#### Step 1 — detect (no payload change)

```sh
make -f Makefile.NixosScripts dry
```

Expect the drift failure from §11.1. If it exits `0`, either the target is clean
or the manifest is missing; reconcile before pulling.

#### Step 2 — pull a snapshot (never `.env`, never `--delete`)

```sh
rsync -az --checksum --no-owner --no-group \
  --exclude='.env' \
  --exclude='.deploy-state' \
  --exclude='.deploy-state.*' \
  --exclude='.git' \
  --exclude='node_modules' \
  --exclude='.yarn/cache' \
  --exclude='result-*' \
  "$TARGET_USER:$REMOTE_SCRIPTS/" "$SNAPSHOT/"
```

- trailing slashes copy the **contents** of `_scripts/`, not the directory;
- `-a` preserves mode and times; `--no-owner --no-group` drops the TOS uid/gid;
- `--checksum` compares content, not size + mtime;
- **no `--delete`** — a remote deletion cannot and must not be expressed here.

#### Step 3 — overlay into a worktree pinned at the deployed commit

```sh
git -C "$SUB" worktree add --detach "$WORKTREE" "$PIN_SUB"

rsync -a --checksum --delete --exclude='.git' \
  "$SNAPSHOT/" "$WORKTREE"/

git -C "$WORKTREE" add -A
git -C "$WORKTREE" status --short
git -C "$WORKTREE" diff --cached --stat
git -C "$WORKTREE" diff --cached --summary   # mode changes, new/deleted files
git -C "$WORKTREE" diff --cached             # content review
```

- The worktree is **disposable** and starts exactly at the pin, so `--delete`
  is what propagates remote deletions. It is safe only because no tracked file
  at the pin was withheld from the pull: every pull exclude is either untracked
  or gitignored, and `.env` is not tracked.
- `--exclude='.git'` protects the worktree's `.git` pointer file; never use
  `--delete-excluded`.
- `git add -A` is required: `git diff` alone does not show untracked added files,
  and `git diff --stat` would miss them.
- The diff is **remote vs pin**. The operator's dirty submodule checkout (at base
  HEAD `.env.example` and `Makefile` are modified) is not part of it. That
  isolation is the point: unrelated local work cannot hide or pollute the
  incoming delta.

#### Step 4 — validate before any commit

```sh
find "$WORKTREE" -name '*.sh' -type f -print0 | xargs -0 -r -n1 bash -n
git -C "$WORKTREE" diff --cached --check

# Authoritative compose check: on the target, with the rendered 0600 .env.
ssh "$TARGET_USER" "cd $REMOTE_SCRIPTS && docker compose -f docker-compose-system.yml config -q"

# Optional control-node shape check. The worktree has no .env (never pulled),
# so interpolate with the tracked example only; it is not the real environment.
docker compose -f "$WORKTREE/docker-compose-system.yml" \
  --env-file "$WORKTREE/.env.example" config -q
```

Never commit a shell file that fails `bash -n`. A compose failure on the shape
check is a prompt to inspect the `${...:?error}` keys, not a reason to copy
`.env` into the worktree.

#### Step 5 — commit on a branch and open a PR

```sh
BRANCH="edge/terra-$(date -u +%Y%m%d)"
git -C "$WORKTREE" switch -c "$BRANCH"

# one commit per logical fix (repeat add/commit for each)
git -C "$WORKTREE" add -A
git -C "$WORKTREE" commit \
  -m "fix(edge): <what changed>" \
  -m "Recovered from an on-@terra debug session in $REMOTE_SCRIPTS; reviewed against $PIN_SUB."

git -C "$WORKTREE" push -u origin "$BRANCH"
```

Open a PR in `ConvPlatProv__NikolaiGogol` and merge normally. **No auto-merge.**
If the delta contains several independent fixes, split them into several commits
(`git add -p`) so each can be reviewed and reverted alone. Reuse the same branch
name only after the first one is merged; otherwise add a time suffix.

#### Step 6 — re-pin (submodule gitlink + dependency pin)

The submodule commit is not the deployment identity; the superproject pin is.
After the PR merges:

```sh
git -C "$SUPER" fetch origin
git -C "$SUPER" switch main
git -C "$SUB" switch main
git -C "$SUB" pull --ff-only

git -C "$SUPER" add @NikolaiGogol
git -C "$SUPER" commit -m "chore(deps): bump @NikolaiGogol" -- @NikolaiGogol
git -C "$SUPER" push origin main

NEW_PIN="$(git -C "$SUPER" rev-parse HEAD)"
```

The control-node submodule checkout is dirty at base HEAD; stash or commit the
unrelated `.env.example` / `Makefile` changes before switching, and never let
them ride along in the recovery commit. `git commit -- @NikolaiGogol` stages only
the gitlink, not the superproject's other modified files.

Then record `NEW_PIN` as the dependency pin. Where that value lives is **`TBD`
(planned)**: the dependency plan names `nixos_virt_scripts_ref` / `_commit` for the
superproject commit, and `refs-update` (absent at base HEAD) is the intended
writer. Until it exists, the
operative step is the control-node checkout above — the scripts role copies it
as-is and has no pin var of its own.

#### Step 7 — redeploy and rewrite the manifest

```sh
# Authoritative: image, container and scripts at the new pin.
make run TAGS=image,container,scripts

# Script-only fix (no image/bind change): the scripts tag is the complete
# redeploy of that surface, but it must still follow the commit and the pin.
make -f Makefile.NixosScripts run
```

The role re-syncs (`delete: false`), re-renders `.env` (`0600`) and rewrites
`.deploy-state` because the tree hash differs from the previous manifest. Verify
with S7; the next `make -f Makefile.NixosScripts dry` must be clean.

Clean up the disposable worktree:

```sh
git -C "$SUB" worktree remove --force "$WORKTREE"
```

Keep `$PULL/snapshot`, the reviewed diff and the commit message until the change
is deployed.

### 11.4 Decision table

| Situation | Action |
|---|---|
| S1/S0 fails on drift with `force=false` | This is the detector. Pull, review, commit; do **not** force |
| Only `.env` changed remotely | Not drift (excluded); never pull. Change `env.j2`/group vars and commit that |
| Remote file deleted | `--delete` overlay stages the deletion; review it and commit with an explicit reason |
| Stale file reappears as an addition | `delete: false` kept a file upstream already deleted; do not commit it blindly — delete it or exclude it explicitly |
| Remote added file | Appears in `git add -A`; commit it if it is source, otherwise delete it on the target |
| Manifest missing/corrupt | Guard is blind; diff the target against the pin manually before any deploy |
| Mode change | `rsync -a` preserved it, but this submodule has `core.filemode=false`; use `git update-index --chmod=+x <path>` and verify with `git ls-tree` |
| Binary change | `--stat` shows `Bin`, `--numstat` shows `-`; review the bytes, never hand-edit |
| Upstream moved since the pin | Diff is vs the old pin; branch from the pin, then rebase/merge onto `main` normally; no force-push |
| Change is in the `Unix_dotfiles` bind | Same pattern in that repo and its pin (`nixos_unix_dotfiles_ref`, default branch `dev`) |
| Change is `@Manilov` XML | `virsh dumpxml` → diff against the pinned `vmDefinition.xml` → commit the intended delta in the owning repo → re-pin `nixos_virt_scripts_ref` |
| Deploy must proceed now, fix can wait | Pull the snapshot first; then `force=true` discards the working copy, not the evidence |
| No `rsync` on `@terra` | Stop; install it or stage the payload another way. Do not substitute a destructive copy |
| Branch already exists | Add a time suffix; never force-push a branch under review |

### 11.5 What not to pull

| Path | Why it is excluded |
|---|---|
| `.env` | Rendered per environment by `env.j2`, mode `0600`; it contains target paths and is never source. Pulling it would overwrite rendered values and leak environment facts |
| `.deploy-state`, `.deploy-state.*` | Target bookkeeping. Pulling it would let a target manifest masquerade as control-node state; `.deploy-state.drift` may contain digests |
| `.git` | The target has none. A stray `.git` would make the snapshot a repository and can redirect git commands when overlaid |
| `node_modules`, `.yarn/cache` | Dependency caches, regenerated, large; already in the role excludes and upstream `.gitignore` |
| `result-*` | Nix build outputs, machine-specific and large; already excluded by the role |
| `haos_ova-*.qcow2`, `*.vdi.zip` | Not in `_scripts`; VM disks are data, never propagated by this flow |

`@NikolaiGogol/.gitignore` ignores `.env`, `node_modules`, `.yarn/*` (with
release/plugin exceptions) and `.pnp.*`. Those are source-repo rules; the pull
applies its own explicit excludes because `.deploy-state*` is not gitignored
(there is no git on the target to ignore it).

### 11.6 Deletions

`rsync` without `--delete` copies what exists; it has no way to say "this file
was deleted on the source". Therefore:

- the **pull** never uses `--delete`;
- the **overlay into the disposable worktree** uses `--delete`, because the
  worktree starts exactly at the pin and the only difference is the remote delta;
- `git diff --cached` then shows the deletion, and the commit records it.

Two traps:

1. `_scripts` is deployed with `delete: false`, so a file upstream deleted can
   still exist on the target and reappear in the snapshot as an addition relative
   to the pin. Check additions against upstream history
   (`git -C "$SUB" log --oneline --diff-filter=D -- <path>`) before committing.
2. A remote deletion can be accidental, and absence on the target is not proof
   of intent — the target is not a pristine checkout. The commit message must
   state why the deletion is intended; otherwise restore the file on the target
   and pull again.

### 11.7 Binary and mode changes

- `rsync -a` preserves mode bits, including the executable bit.
- `git diff --cached --stat` prints `Bin` for binary content; `--numstat` prints
  `-` for both columns. Review the bytes; do not edit them in the worktree.
- `git diff --cached --summary` prints `mode change 100644 => 100755` **only if
  git tracks the file mode**. The `@NikolaiGogol` submodule's local config has
  `core.filemode = false`, so git ignores the executable bit there. To propagate
  an intentional mode change use
  `git -C "$WORKTREE" update-index --chmod=+x <path>` (or `--chmod=-x`), then
  verify with `git ls-tree HEAD <path>` before committing.
- `.gitattributes` in `@NikolaiGogol` marks `.yarn` content as vendored/binary
  and `.pnp.*` as generated; it does **not** set `text=auto` or `eol=`. Line
  endings therefore follow the control node's git configuration. If a one-line
  remote edit shows as a whole-file rewrite, check with
  `git diff --cached --ignore-space-at-eol` and fix the checkout's
  `core.autocrlf`/`core.eol` rather than committing the churn.

### 11.8 Conflict case — upstream moved since the pin

The worktree diff is "remote vs the **deployed** pin". If `origin/main` has
advanced since that pin, the branch will not contain the newer upstream commits.

- Keep the pinned worktree as the authoritative "what changed on the target"
  review; do not move it.
- Commit the recovered delta on `edge/terra-<date>` from the pin.
- Rebase or merge that branch onto current `main` in a normal checkout
  (`git rebase origin/main` or `git merge origin/main`), resolve conflicts there,
  and push normally. **Never force-push.**
- If the combined diff is too noisy to review, add a second worktree at
  `origin/main` and overlay the same snapshot into it. That diff is "remote vs
  current"; the first one remains "remote vs deployed". Both are read-only
  reviews; only the branch is committed.

### 11.9 Parallel cases

The pattern is the same; only the repository, the bind path and the pin differ.

| Surface | Remote path | Owning repo / pin | Delta source |
|---|---|---|---|
| `_scripts` | `/zterra/local-/Projects/@NikolaiGogol/_scripts` | submodule `ConvPlatProv__NikolaiGogol`; superproject pin → gitlink | rsync snapshot (this section) |
| `Unix_dotfiles` bind | `/zterra/local-/Projects/nikolaigogol/data/Unix_dotfiles` | `Unix_dotfiles`; `nixos_unix_dotfiles_ref`, default branch `dev` | rsync snapshot of the bind, same worktree/diff/commit |
| `@Manilov` XML | `/zterra/local-/Projects/nikolaigogol/data/Virt_scripts_bootstrap` (container: `/home/ds13/.bookmarks/Virt_scripts_bootstrap`) | `Virt_scripts`; `nixos_virt_scripts_ref` | `virsh dumpxml` vs pinned `vmDefinition.xml` |

`Unix_dotfiles`:

```sh
rsync -az --checksum --no-owner --no-group \
  --exclude='.git' --exclude='.env' --exclude='result-*' \
  "$TARGET_USER:/zterra/local-/Projects/nikolaigogol/data/Unix_dotfiles/" \
  "$PULL/unix-dotfiles/"
# then the same worktree/diff/commit against that repo's pin
```

The `Unix_dotfiles` checkout is a full git checkout on a bind. Do not run
`roles/nixos_edge_sync` before pulling — its current `delete: true`
(`roles/nixos_edge_sync/tasks/main.yml:16`) would remove the remote edits.

`@Manilov`:

```sh
ssh "$TARGET_USER" "docker exec HomeServer__HomeAssistant.NikolaiGogol \
  virsh -c qemu:///system dumpxml hass_qemu16" > "$PULL/manilov-live.xml"

git -C "$SUPER" show "$PIN_SUPER:Virt_scripts_bootstrap/vmDefinition.xml" \
  > "$PULL/vmDefinition.pinned.xml"
diff -u "$PULL/vmDefinition.pinned.xml" "$PULL/manilov-live.xml"
```

Review the delta, edit `vmDefinition.xml` in `Virt_scripts_bootstrap` (tracked in
the superproject at base HEAD; the plan's `nixos_virt_scripts_ref` applies when
the dependency layer lands) to the intended state, commit, re-pin and redeploy.
Do not copy the live XML verbatim: `dumpxml` also contains runtime-generated
identity (UUID, MAC, paths, NVRAM) that is not part of the intended definition.
Never use `undefine --remove-all-storage` as cleanup during this flow.

### 11.10 Proposed `scripts-pull` target (specification only)

Add to `Makefile.NixosScripts` (which includes `Makefile.Steps`). The name avoids
a generic `pull` target in an included file; the design brief's shorthand `pull`
is the same operation.

| Item | Specification |
|---|---|
| Target | `scripts-pull` (`.PHONY`) |
| Inputs | `INVENTORY` (default `hosts.ini`; must select the real target), `REF` (optional pin; default = configured dependency pin), `TARGET_USER` (default `terra`; `SSH_TARGET` already exists in `Makefile.Steps`), `PULL_ROOT` (default `${XDG_CACHE_HOME:-$HOME/.cache}/nikolai-gogol/pull`) |
| Step 1 | Resolve `PIN_SUB`: `REF` → superproject sha → `git rev-parse "$REF:@NikolaiGogol"`; assert with `git cat-file -e`. At base HEAD `REF` is effectively required because no pin var exists; fail with a clear message instead of guessing. |
| Step 2 | `mkdir -p "$PULL_ROOT/<stamp>/snapshot"`; rsync the target with the §11.3 filters and **no `--delete`**. |
| Step 3 | `git -C "$SUB" worktree add --detach "$PULL_ROOT/<stamp>/worktree" "$PIN_SUB"`; overlay the snapshot with `--delete --exclude=.git`. |
| Step 4 | `git add -A`; write `diff.patch` (`git diff --cached`) and `review.txt` (`--stat` + `--summary` + `--numstat`) into `$PULL_ROOT/<stamp>/`; print them. |
| Step 5 | `bash -n` every `*.sh`; fail the target on a syntax error. Print the target-side compose check hint (the worktree has no `.env`). |
| Outputs | `$PULL_ROOT/<stamp>/{snapshot/,worktree/,diff.patch,review.txt}`; exit `0` on a successful review bundle |
| Hard stop | **No branch, no commit, no push, no re-pin, no deploy, no `force`.** The target must not modify `_scripts`, `.deploy-state`, the submodule's `main`, the superproject, or any pin. It prints the next operator commands and stops. |
| Read-only claim | The only writes are under `$PULL_ROOT` and git's worktree admin metadata (`$SUB/.git/worktrees/`). No target write. |
| Refusals | `INVENTORY=tests/integration/inventory.ini` (the mock has no `_scripts`); a missing `.deploy-state` (pull still allowed, but print the "guard is blind" warning); a dirty submodule checkout (warn that the diff is vs the pin, not vs the working tree). |
| Non-goals | No `.env` pull, no secret handling, no auto-merge, no `refs-update`, no image build, no S0/S1 invocation. |

Acceptance when implemented: on a dirty target it produces a diff and exits `0`;
on a clean target the diff is empty; `sha256sum` over `_scripts` before and after
is unchanged; the fake inventory fails fast.

### 11.11 The rule: never `force=true` before pulling

`force=true` is not "make the deploy work". It overwrites the only copy of the
remote fix: the target has no git, so once rsync replaces the file there is no
history and no other copy. The order is fixed:

```
pull → review → commit → re-pin → deploy
```

`force=true` is allowed only when a **deliberate discard** is intended, and only
after the snapshot exists (`$PULL/snapshot` or an equivalent copy). If the
operator cannot answer "where is the snapshot?", the answer is no.

This extends §7 without changing it:

| Invariant | Enforced by |
|---|---|
| The target is never a git writer | no git, no key on `@terra`; the flow is pull-based from `CN` |
| A remote fix is preserved before it is overwritten | `scripts-pull` snapshot precedes any force; the decision table forbids force-first |
| The recovered delta is reviewed against the deployed pin | disposable worktree at `PIN_SUB`; `git diff --cached` |
| Nothing is auto-promoted | `scripts-pull` stops before branch/commit/push; PR + merge is an operator decision |
| Deletions are explicit | `--delete` only inside the disposable worktree; the commit message states intent |

Diagram for this section: `docs/EdgeIteration_scripts.puml` (S9).
