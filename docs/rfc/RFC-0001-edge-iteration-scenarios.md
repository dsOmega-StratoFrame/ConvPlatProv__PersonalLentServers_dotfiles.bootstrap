# RFC-0001 — Edge-iteration scenario catalogue

| Field | Value |
|---|---|
| Catalogue | `RFC-0001` scenarios |
| Companion | `docs/rfc/RFC-0001-edge-iteration-workflow.md` (proposal; not duplicated here) |
| Status | Supporting analysis for the Proposed RFC |
| Date | 2026-10-28 |
| Base HEAD | `004ee9e` (worktree dirty) |
| Purpose | Machine-transcribable actor/message catalogue for the architect's PlantUML diagrams |

This document records **what happens** in each edge-iteration scenario. It does
not restate the RFC's proposal, rationale, safety invariants, or alternatives.
Where the repository at base HEAD does not yet contain a mechanism named in the
RFC (for example the dependency-layer roles or `refs-list`/`refs-update`), the
step is marked `TBD (planned)` and the confirmed state is stated separately.

## 1. Actors

Short ids are for PlantUML declarations such as
`actor Operator as OP`. The diagram may omit actors that do not send or receive
a message in a given scenario.

| Id | Actor | Represents |
|---|---|---|
| `OP` | `Operator` | Human at the control node or on an SSH session to `@terra` |
| `CN` | `ControlNode` | Workstation running Ansible; holds the upstream checkouts, the image artifact, and the only GitHub credential |
| `ANS` | `Ansible` | `ansible-playbook` plus `deploy-nikolaigogol.yml` / `roles/*` |
| `TER` | `Terra` | `@terra`, the TerraMaster NAS running TOS 6; the SSH user `terra` is uid 0 |
| `DOC` | `Docker` | Docker CLI/daemon on `@terra` |
| `CON` | `Container` | The running NixOS system container `HomeServer__HomeAssistant.NikolaiGogol` |
| `SD` | `ScriptsDir` | `_scripts` on `@terra`: `/zterra/local-/Projects/@NikolaiGogol/_scripts` |
| `LIB` | `Libvirt` | libvirt / QEMU inside the privileged container (`qemu:///system`) |
| `MAN` | `Manilov` | The HomeAssistant OS VM domain `hass_qemu16` |
| `UP` | `UpstreamRepos` | Control-node checkouts: the upstream `@NikolaiGogol` folder, `Virt_scripts_bootstrap`, and `Unix_dotfiles` |
| `PIN` | `Pins` | Configured refs/commits for dependency repos (planned dependency-layer vars; exact storage `TBD`) |

## 2. Shared conventions

These facts are common to every scenario and are not repeated in each sequence.

| Item | Confirmed value / behaviour |
|---|---|
| Control-node `@NikolaiGogol` source | `$HOME/.bookmarks/shared-projects/ChronoIndex/2026/ConvPlatProv-HomeServer__HomeAssistant/@NikolaiGogol` (role default; `ConvPlatProv`, not `PlatConvProv`) |
| `_scripts` target | `/zterra/local-/Projects/@NikolaiGogol/_scripts` (`{{ zterra_root }}/local-/Projects/@NikolaiGogol/_scripts`) |
| Container | `HomeServer__HomeAssistant.NikolaiGogol`, service `NikolaiGogolSystem` |
| Container user | `ds13` |
| Compose project | `/zterra/local-/Projects/nikolaigogol` |
| Image identity | Content tag = first 12 hex chars of the rootfs tarball sha256; derived by the shared `conv-plat-prov.content-tag` command; `:latest` is only the upstream debug alias |
| Tags | `scripts` and `debug` are independent of `container`; `TAGS=container` never deploys `_scripts` |
| `.env` | Rendered from `roles/nikolaigogol_scripts/templates/env.j2`, mode `0600`; the upstream `.env` is excluded from the copy and from the tree digest |
| Bind mounts | Exactly three: `UNIX_DOTFILES`, `VIRT_SCRIPTS_BOOTSTRAP`, `HOME_ASSISTANT_IMAGE`. `_scripts` has **no bind mount** and is not referenced by compose |
| Drift reference | `_scripts/.deploy-state` (`role`, `source`, `tree_sha256`, `deployed_at`, per-file `files`); the target has no git |
| Target-side git | None. `@terra` has no git, no GitHub access, and no key. Keys live only on `CN` |
| Target-side shell | `sudo docker` is used by the upstream scripts; on TOS 6 `terra` is already uid 0 and `sudo` may be absent |
| Target-side tooling | `docker` and `make` are probed by the scripts role; missing tools skip the corresponding validation rather than fail the role |
| Phase 0 limits | `switch-nixos.sh` hard-codes `~/.bookmarks/shared-configs/Unix_dotfiles`; `connect.sh` declares no `REQUIRES_FUNCS` |

### 2.1 Confirmed versus planned

- `roles/nikolaigogol_scripts` and `_scripts` are **present** at base HEAD.
- The dependency-layer roles (`nixos_haos_image`, `nixos_unix_dotfiles`,
  `nixos_virt_scripts`), `Makefile.NixosDeps`, `refs-list`, and `refs-update` are
  **planned in `docs/NikolaiGogol__DependencyLayers_plan.md` and absent from
  `deploy-nikolaigogol.yml` at base HEAD**. They are labelled `TBD (planned)`.
- The current file-mount source is the unversioned
  `/zterra/shared-/@Manilov/dotfiles-/_configs/HomeAssistant__/haos_ova.qcow2`.
  The versioned `haos_ova-16.3.qcow2` and its digest are dependency-layer
  targets, not accepted Phase 0 values. `TBD`.
- `_scripts` contains the `@NikolaiGogol` folder only. `Virt_scripts_bootstrap`
  is a **separate** bind at `/home/ds13/.bookmarks/Virt_scripts_bootstrap`.
  A path written as `_scripts/Virt_scripts_bootstrap` is **not confirmed**;
  `TBD` whether any future copy consolidates them.

## 3. Scenarios

### S0 — Full authoritative deploy

| | |
|---|---|
| **Id** | `S0` |
| **Actors** | `OP`, `CN`, `ANS`, `TER`, `DOC`, `CON`, `SD`, `UP`, `PIN` (conditional dependency layers) |
| **Precondition** | The operator has built the rootfs artifact on the control node; `@terra` is reachable; the HAOS file mount source exists; the upstream `@NikolaiGogol` checkout exists on `CN`. |

**Sequence**

1. `OP → CN`: create/refresh the artifact precondition (not done by the role):
   `make --directory=~/.bookmarks/shared-configs/Unix_dotfiles build-NikolaiGogol`
   → `result-NikolaiGogol/tarball/nixos-system-x86_64-linux.tar.xz`.
2. `OP → ANS`: `make run TAGS=image,container,scripts` (or the per-step
   `make -f Makefile.NixosImage run` then `make -f Makefile.NixosContainer run`
   then `make -f Makefile.NixosScripts run`).
3. `ANS → CN`: `nixos_image_artifact` validates inputs, stats the artifact,
   computes sha256, runs `invoke --search-root=~/.bookmarks/shared-scripts
   conv-plat-prov.content-tag <tarball>`, asserts the tag equals the sha256
   slice, and publishes `ds-omega/nikolai-gogol:<sha12>`.
4. `ANS → TER`: `nixos_image_sync` ensures
   `/zterra/local-/var-/cache/nixos-images/`, then rsyncs the artifact
   `--checksum` to `<sha256>.tar.xz`.
5. `ANS → DOC`: `nixos_image_load` runs `docker image inspect`; if absent it
   runs `docker import <staged tarball> <repo>:<tag>`, then inspects again.
6. `ANS → TER`: `nixos_container` ensures the compose project directory and the
   two directory mount sources; stats the HAOS file mount source and fails
   closed if it is missing.
7. `ANS → TER`: `TBD (planned)` dependency layers stage the HAOS qcow2,
   `Unix_dotfiles`, and `Virt_scripts_bootstrap` before the container. If the
   layer is not enabled, this step is skipped.
8. `ANS → TER`: renders `docker-compose-system.yml` and `.env` (`0600`), runs
   `docker compose -f docker-compose-system.yml config -q`, then
   `community.docker.docker_compose_v2 state=present pull=never`.
9. `ANS → DOC/CON`: the notify handler recreates the container only when the
   rendered config changed (`recreate: auto`); `docker compose ps` reports status.
10. `ANS → SD`: runs the `scripts` role: source assert on `CN` → target tree
    hash → `.deploy-state` drift check → rsync (`--checksum`, `delete: false`,
    excludes) → render `.env` (`0600`) → per-file digests + manifest →
    `bash -n`, `docker compose config -q`, `make -n image-name`.
11. `ANS → OP`: reports image, container status, and whether `_scripts` changed.

**Alternates / branches**

- Artifact missing → `nixos_image_artifact` fails on `CN` before any target
  mutation; remediation is the build command in step 1.
- Image already loaded → `docker import` is skipped; the container may still be
  recreated if its rendered config changed.
- HAOS file mount missing → `nixos_container` fails closed before compose starts.
- `TAGS=image,container` only → `_scripts` is untouched (tag independence).
- `TAGS=container` without a resolved image tag → the container role fails on
  its input assert unless `nixos_image_tag` is pinned.
- Dependency layers disabled → step 7 is absent; the three bind sources must
  already exist.

**Outcome**

A durable, content-tagged image is imported and the managed container is running
against it; `_scripts` is refreshed only when the `scripts` tag is included.

**Notes / caveats**

- `S0` is the authoritative deploy path. The image tag is the deploy identity;
  `_scripts/.env` `IMAGE_TAG=latest` is a debug alias and not the deploy identity.
- `nixos_image_artifact` **locates and checksums** the artifact; it never builds.
- The scripts role runs **after** the container role. A source or drift failure in
  the scripts role therefore leaves the container deploy already applied and
  `_scripts` unchanged.

---

### S1 — Scripts-only deploy via Ansible (Phase 0)

| | |
|---|---|
| **Id** | `S1` |
| **Actors** | `OP`, `CN`, `ANS`, `TER`, `SD`, `UP` |
| **Precondition** | The upstream `@NikolaiGogol` checkout exists on `CN`; `@terra` is reachable and `_scripts` may or may not exist. |

**Sequence**

1. `OP → ANS`: `make -f Makefile.NixosScripts run` (add
   `INVENTORY=tests/integration/inventory.ini` for the mock; use `dry` for
   `--check --diff`).
2. `ANS → CN`: `stat` the source directory, `<source>/switch-nixos.sh`, and
   `<source>/Makefile`; assert all three exist.
3. `ANS → TER`: ensure `_scripts` exists (`0755`); `stat` it. In `--check` mode
   the directory may not exist, in which case the role prints a skip message and
   does no target inspection, sync, or verification.
4. `ANS → TER`: `stat` `_scripts/.deploy-state`; `slurp` and parse it when present.
5. `ANS → TER`: hash the target tree with `find` + `sha256sum`, excluding
   `.deploy-state`, `.deploy-state.*`, and `.env`.
6. `ANS → TER`: compare that hash with `manifest.tree_sha256`.
7. **Drift branch:** if it differs and `nikolaigogol_scripts_force` is false,
   `ANS → TER` stages the recorded per-file digests in
   `.deploy-state.drift`, runs `sha256sum -c .deploy-state.drift`, removes the
   staging file, and fails **before rsync**, listing the `FAILED` paths (or
   falling back to the tree hashes for added files).
8. `ANS → TER`: rsync the source into `_scripts` with `archive: true`,
   `checksum: true`, `delete: false`, excludes `.git`, `.env`, `result-*`,
   `node_modules`, `.yarn/cache`, and `--omit-dir-times`.
9. `ANS → TER`: render `.env` from `env.j2`, mode `0600`.
10. `ANS → TER`: hash the deployed tree and collect per-file `sha256sum` lines.
11. `ANS → TER`: write `.deploy-state` (`role`, `source`, `tree_sha256`,
    `deployed_at`, `files`) when the manifest is absent or the tree hash changed.
12. `ANS → TER`: find every `*.sh` recursively and run `bash -n` on each.
13. `ANS → TER`: `command -v docker`; if present, run
    `docker compose -f docker-compose-system.yml config -q` in `_scripts`;
    otherwise print a skip message.
14. `ANS → TER`: `command -v make`; if present, run `make -n image-name` in
    `_scripts`; otherwise print a skip message.
15. `ANS → OP`: report the scripts path and whether the sync changed.

**Alternates / branches**

- Source missing/incomplete → assert fails on `CN`; remediation is
  `-e nikolaigogol_scripts_source_dir=/path/to/@NikolaiGogol` or clone the repo.
- Target directory absent in `--check` → skip target work, no failure.
- Clean target → rsync is a checksum no-op; `.deploy-state` is rewritten only if
  the tree hash changed.
- Drift → fail before rsync (S8 covers revert/force).
- `force=true` → the drift guard is skipped; rsync overwrites recorded files.
- Docker absent → compose validation skipped, role continues.
- Make absent → image-name probe skipped, role continues.
- `.env` hand-edited → excluded from the digest, so it causes no drift; it is
  re-rendered and overwritten regardless.

**Outcome**

`_scripts` matches the upstream checkout byte-for-byte for included files;
`.env` is rendered; `.deploy-state` records the tree and per-file digests; no
container, compose, or bind-mount change occurs.

**Notes / caveats**

- This is the Phase 0 evidence path. It **validates** scripts; it never executes
  `switch-nixos.sh`, `connect.sh`, or any other upstream script.
- `_scripts` is a debug surface, not a container dependency. `TAGS=container`
  does not run this role.
- `delete: false` means stale files and debugger additions are retained; the
  drift report is the visibility mechanism.

---

### S2 — Ad-hoc debug/edit on remote (no Ansible)

| | |
|---|---|
| **Id** | `S2` |
| **Actors** | `OP`, `TER`, `SD`, `DOC`, `CON`, `UP` |
| **Precondition** | `_scripts` has been deployed (S1); the operator has SSH access to `@terra`; the container may be running. |

**Sequence**

1. `OP → TER`: `ssh terra` (or `make -f Makefile.NixosContainer shell-ssh`).
2. `OP → SD`: `cd /zterra/local-/Projects/@NikolaiGogol/_scripts`.
3. `OP → SD`: edit a script, `docker-compose-system.yml`, the `Makefile`, or
   `.env` directly on the target.
4. `OP → SD`: run local checks: `bash -n <edited>.sh` and
   `docker compose -f docker-compose-system.yml config -q`.
5. `OP → DOC`: optionally invoke an upstream target, e.g.
   `make stop-system-container`, `make rm-system-container`, `make import-nixos`,
   `make start-system`, `make connect-nixos`, or `make connect`.
6. `OP → SD` / `OP → CON`: optionally run an upstream script such as
   `./switch-nixos.sh` or `./connect.sh`.
7. `DOC → CON`: stop, remove, import, start, and/or attach as requested.
8. `OP → OP`: observe the result; there is no Ansible report and no manifest
   update from this path.

**Alternates / branches**

- Edit only → no runtime change until a make target or script is run.
- `switch-nixos.sh` → stops and removes the container, builds the rootfs from
  the hard-coded `~/.bookmarks/shared-configs/Unix_dotfiles`, imports, starts,
  then connects. On `@terra` the hard-coded path is not the Phase 0 path; the
  build step is expected to fail or use the wrong source.
- `connect.sh` → retries `make connect-nixos`; `info`/`fatal` are not backed by a
  `REQUIRES_FUNCS` declaration, so they may be undefined.
- `sudo docker` → may fail if `sudo` is absent on uid-0 `terra`.
- `.env` edit → used by the current shell only; the next S1/S0 run overwrites it.

**Outcome**

The operator's local edits and any runtime changes exist only on `@terra`.
They are outside the managed role and outside `.deploy-state`.

**Notes / caveats**

- This path bypasses Ansible and can **race** the Ansible-managed container
  (`nixos_container` / `community.docker.docker_compose_v2`). Two writers to the
  same container are undefined.
- A subsequent S1/S0 run will detect changed payload files as drift and refuse to
  overwrite them without `force=true` (S8).
- `.env` is excluded from the drift digest, so an edited `.env` is not reported
  as drift and is silently replaced on the next deploy.

---

### S3 — Edge config iteration inside the container

| | |
|---|---|
| **Id** | `S3` |
| **Actors** | `OP`, `TER`, `CON`, `SD`, `UP` |
| **Precondition** | The container is running; the `Unix_dotfiles` checkout is bind-mounted at `/home/ds13/.bookmarks/shared-configs/Unix_dotfiles`; a change has been staged there (or in `_scripts` for script-level experiments). |

**Sequence**

1. `OP → CON`: enter the container with
   `make -f Makefile.NixosContainer connect-container` (runs
   `docker exec -it --user ds13 ... /run/current-system/sw/bin/bash`), or via
   `ssh-container` / direct `docker exec`.
2. `OP → CON`: edit the flake source in the bind mount
   `/home/ds13/.bookmarks/shared-configs/Unix_dotfiles` (the `NikolaiGogol`
   configuration).
3. `OP → CON`: run `nixos-rebuild test --flake
   /home/ds13/.bookmarks/shared-configs/Unix_dotfiles#NikolaiGogol` (default
   edge mode).
4. `CON → CON`: activate the new system for the current boot; no boot entry is
   created.
5. `OP → CON`: observe services/configuration and run the experiment.
6. `OP → CON`: choose a follow-up mode:
   - `nixos-rebuild switch --flake <flake>#NikolaiGogol` — create a boot
     generation **inside the container**;
   - `nixos-rebuild --rollback switch` — return to the previous generation.
7. `CON → OP`: report the active generation / rollback result.

**Alternates / branches**

- `test` fails → the previous generation remains active; fix the source or
  roll back.
- `switch` → survives a plain container restart, but not a container recreate.
- `--rollback switch` → returns to the previous generation; this is a
  container-local generation, not an image/content-tag rollback.
- Optional `nixos_edge_sync` helper → off by default and present at base HEAD;
  its current implementation rsyncs with `delete: true` and runs
  `nixos-rebuild switch` (unsafe defaults recorded in the RFC). Its refactor is
  `TBD`. Prefer S3 manually or the refactor.

**Outcome**

The changed system is active only inside the running container.

**Notes / caveats**

- Ephemeral: `nixos-rebuild test` and `switch` generations, installed packages,
  `/etc` edits, systemd units, and `virsh edit` changes live in the container's
  writable layer and are lost on `docker rm`/recreate.
- The source edit itself may survive if it is in the `Unix_dotfiles` bind; the
  **activation** does not.
- Promotion is not a copy-out. Use S4 (commit → pin → S0).
- `_scripts` is not the flake; the flake path is the bind-mounted
  `Unix_dotfiles` checkout. `TBD`: exact flake attribute/path if the refactor
  moves it.

---

### S4 — Promotion of an edge fix

| | |
|---|---|
| **Id** | `S4` |
| **Actors** | `OP`, `UP`, `PIN`, `CN`, `ANS`, `TER`, `DOC`, `CON`, `SD` |
| **Precondition** | A change has been validated with S2/S3; the operator has commit access to the relevant upstream repo. |

**Sequence**

1. `OP → UP`: commit the validated change in the owning repository:
   `Unix_dotfiles` for the system configuration, `Virt_scripts_bootstrap` for
   `vmDefinition.xml`/VM definitions, or the `@NikolaiGogol` repo for scripts.
2. `OP → PIN`: pin the commit (S5 `refs-update`), so the deploy uses a concrete
   sha rather than a moving branch. `TBD (planned)` for dependency repos; the
   current `_scripts` role has no pin var.
3. `OP → CN`: build the image artifact from the pinned checkout (S0 step 1).
4. `OP → ANS`: run the full deploy (S0), normally
   `TAGS=image,container` and `scripts` if the script surface changed.
5. `ANS → DOC`: import the new content-tagged image and recreate the container.
6. `ANS → SD`: refresh `_scripts` only if the `scripts` tag is included.
7. `OP → TER`: verify with S7 and, for VM changes, S6.

**Alternates / branches**

- Change is script-only → commit the script, refresh the pin (if any), run S0
  with `scripts`; the image may remain unchanged.
- Change is VM-definition-only → commit `Virt_scripts_bootstrap`, run S0 (and
  re-define the domain in S6); the qcow2 itself is data, not a build artifact.
- No pin available yet (`TBD (planned)`) → an unset ref falls through to the
  repo's configured default branch for short experiments; this must be re-pinned
  before delivery.

**Outcome**

A durable image/scripts deploy reproducible from the pinned commit. The edge
change is not copied out of the container.

**Notes / caveats**

- Edge changes never ship as-is. There is no copy-out path from the container to
  the source.
- A change that exists only in the container (or only in `_scripts` on `@terra`)
  is not promoted by S0; it must be committed first.

---

### S5 — Dependency ref pinning

| | |
|---|---|
| **Id** | `S5` |
| **Actors** | `OP`, `PIN`, `UP`, `CN`, `ANS`, `TER` |
| **Precondition** | `TBD (planned)`: `Makefile.NixosDeps`, the dependency roles, and the pin vars exist. At base HEAD only the RFC/plan describe them. The operator has a control-node key/agent with GitHub access. |

**Sequence**

1. `OP → PIN`: `refs-list`.
2. `PIN → UP`: resolve each repo's configured ref to a full 40-hex commit and
   read that commit's subject.
3. `PIN → OP`: print one row per repo:
   `repo | configured ref | resolved sha | subject`.
4. `OP → PIN`: `refs-update [REF=]`.
5. `PIN → UP`: if `REF` is supplied, resolve it; if no ref is supplied, resolve
   the repo's configured default branch:
   - `Virt_scripts` → `main`;
   - `Unix_dotfiles` → `dev`.
6. `PIN → PIN`: write the **resolved sha** into the pin var, not the branch name.
7. `OP → ANS`: run S0. `ANS → CN` checks out the pinned sha detached, asserts
   `git rev-parse HEAD` equals the pin, and rsyncs the payload; `.deploy-state`
   records `ref`, `commit`, and the tree digest.
8. `ANS → TER`: deploy the dependency payload(s) before the container.

**Alternates / branches**

- `REF` is a branch/tag → `refs-update` resolves it once to a sha; the branch is
  not stored.
- No `REF` → the repo-specific default branch is resolved and pinned.
- Wrong/absent ref → resolution fails; remediation is `refs-update` or a valid
  `-e <repo>_ref=`.
- Git auth failure on `CN` → `Permission denied (publickey)`; load the key/agent
  and confirm `known_hosts` contains `github.com`. The target is unaffected.
- Dirty control-node checkout → refused unless the dev-only dirty opt-in is set
  (`TBD` exact var names for the implemented roles).

**Outcome**

Both dependency payloads are checked out at concrete shas and their manifests
record those shas; a later deploy is reproducible.

**Notes / caveats**

- `refs-list`/`refs-update` are descriptive names from the dependency-layer plan;
  the exact Makefile targets and pin storage location are `TBD`.
- The target never sees git or a key; resolution happens only on `CN`.
- `refs-update` writes a sha because a branch is a moving target.

---

### S6 — `@Manilov` VM lifecycle inside the container

| | |
|---|---|
| **Id** | `S6` |
| **Actors** | `OP`, `TER`, `CON`, `LIB`, `MAN`, `DOC` |
| **Precondition** | The container is running and privileged; the HAOS qcow2 is bind-mounted at `/opt/HomeServer__HomeAssistant/haos_ova.qcow2`; `Virt_scripts_bootstrap` is bind-mounted at `/home/ds13/.bookmarks/Virt_scripts_bootstrap`. |

**Sequence**

1. `OP → CON`: enter the container (S3 step 1) and change to the
   `Virt_scripts_bootstrap` directory. Confirmed path:
   `/home/ds13/.bookmarks/Virt_scripts_bootstrap`; host source:
   `/zterra/local-/Projects/nikolaigogol/data/Virt_scripts_bootstrap`.
   `TBD`: a path written as `_scripts/Virt_scripts_bootstrap` is not confirmed
   at base HEAD.
2. `OP → LIB`: `make install` → `./install.sh` → `sudo virt-install
   --connect qemu:///system --name hass_qemu16 ... --import
   --disk /opt/HomeServer__HomeAssistant/haos_ova.qcow2,bus=scsi ...
   --network none --print-xml > ./vmDefinition.xml`.
3. `OP → LIB`: `make define-vm` → `sudo virsh define ./vmDefinition.xml`.
4. `OP → LIB`: `make attach-devices` → `virsh -c qemu:///system attach-device
   hass_qemu16 ./UsbDevices/ZigbeeDongle.xml --config`.
5. `OP → LIB`: `make start` → `define-vm` + `attach-devices` +
   `sudo virsh start hass_qemu16`.
6. `LIB → MAN`: boot the HAOS domain from the qcow2; `@Manilov` runs.
7. `OP → LIB`: `make info` → `virsh -c qemu:///system dumpxml hass_qemu16`.
8. `OP → LIB`: `make undefine-vm` → `./undefine.sh`:
   `destroy hass_qemu16` then `undefine hass_qemu16 --nvram --remove-all-storage`.

**Alternates / branches**

- `install` writes `vmDefinition.xml` with `--network none`; this disagrees with
  the `tap0`/MAC intent in the checked-in XML. Network mode is `TBD`.
- `attach-devices` fails when `./UsbDevices/ZigbeeDongle.xml` is absent; the
  device path is hard-coded.
- `define-vm` fails when `vmDefinition.xml` is absent (run `install` first).
- `start` includes `define-vm` and `attach-devices`, so either failure stops the
  start.
- `undefine-vm` **destroys the qcow2** (`--remove-all-storage`), even though the
  file is a host bind; this is the current destructive path.

**Outcome**

The `hass_qemu16` domain is defined/started and `@Manilov` boots from the qcow2;
`info` shows the live XML; `undefine-vm` removes the domain and its storage.

**Notes / caveats**

- The qcow2 itself is a host bind and survives a container recreate.
- `/var/lib/libvirt` (domain definitions, NVRAM) is **not** mounted, so domain
  metadata is lost on container recreate. The qcow2 comes back with a fresh
  identity unless the domain is redefined.
- The RFC recommends either binding `/var/lib/libvirt` or redefining from
  `vmDefinition.xml` (ideally both).
- The refactor should make `undefine` keep storage by default and put
  `--remove-all-storage` behind a separate, confirmed `purge`.

---

### S7 — Post-deploy remote check (Phase 0 acceptance)

| | |
|---|---|
| **Id** | `S7` |
| **Actors** | `OP`, `TER`, `SD`, `DOC` |
| **Precondition** | S1 (or S0 with `scripts`) has completed; `_scripts` exists on `@terra`. |

**Sequence**

1. `OP → TER`: `ssh terra`.
2. `OP → SD`: `ls -A /zterra/local-/Projects/@NikolaiGogol/_scripts`; confirm the
   expected upstream files, no `.git`, a `.env` with mode `0600`, and a
   `.deploy-state`.
3. `OP → SD`: syntax-check every shell script:
   `for f in $(find . -name '*.sh' -type f); do bash -n "$f"; done`.
4. `OP → SD/DOC`: `docker compose -f docker-compose-system.yml config -q`.
5. `OP → SD`: `make -n image-name`; expect `ds-omega/nikolai-gogol:latest` with
   the debug `.env` (no import or start is performed).
6. `OP → TER/DOC`: optional container check with
   `docker inspect HomeServer__HomeAssistant.NikolaiGogol` or
   `docker exec ... nixos-version` (mirrors `verify-nikolaigogol.yml`).

**Alternates / branches**

- `docker` absent on `@terra` → step 4 fails at the shell; S1 itself would have
  skipped the same validation.
- `make` absent → step 5 fails at the shell; S1 itself would have skipped it.
- `.env` missing → compose config fails on the `:?error` keys until S1 re-renders
  it.
- `make -n image-name` prints a content tag instead of `latest` when a tarball is
  present in the target tree; both are valid debug outputs, but only the content
  tag is the deploy identity.

**Expected Phase 0 caveats (not failures of S7)**

- `switch-nixos.sh` hard-codes `~/.bookmarks/shared-configs/Unix_dotfiles`; on
  `@terra` the checkout is at
  `/zterra/local-/Projects/nikolaigogol/data/Unix_dotfiles`. The deployed `.env`
  sets `UNIX_DOTFILES` for compose, but the build step ignores it.
- The scripts call `sudo docker`; on TOS 6 `terra` is uid 0, so `sudo` may be
  absent.
- `connect.sh` never sources `REQUIRES_FUNCS`; `info`/`fatal` may be undefined
  on a bare TOS shell.

**Outcome**

Phase 0 acceptance evidence: the expected bytes are present, shell syntax is
valid, compose renders with the rendered `.env`, and the Makefile resolves an
image name without importing or starting anything.

**Notes / caveats**

- This scenario checks the debug surface only. It does not prove the upstream
  `switch-nixos.sh` cycle runs end-to-end on `@terra`; the RFC explicitly does
  not claim that.
- Compare against the S1 role output and `.deploy-state`; S7 is the human
  confirmation, not a second implementation.

---

### S8 — Dirty-target conflict

| | |
|---|---|
| **Id** | `S8` |
| **Actors** | `OP`, `SD`, `ANS`, `TER`, `CN` |
| **Precondition** | `_scripts` has a valid `.deploy-state`; the operator has made an ad-hoc edit on `@terra` (S2); a redeploy (S1 or S0 with `scripts`) is started. |

**Sequence**

1. `OP → SD`: make an ad-hoc edit to a payload file (script, `Makefile`, compose,
   or another included file) on `@terra`.
2. `OP → ANS`: rerun S1 (`make -f Makefile.NixosScripts run`) or S0 with
   `TAGS=...scripts`.
3. `ANS → TER`: hash the target tree, excluding `.deploy-state*` and `.env`.
4. `ANS → TER`: compare the hash with the manifest `tree_sha256`.
5. `ANS → OP`: on mismatch with `force=false`, stage the recorded digests,
   run `sha256sum -c`, and fail before rsync. The message names the manifest,
   the current tree hash, the drifted (`FAILED`) files where available, and the
   `-e nikolaigogol_scripts_force=true` override.
6. **Branch A — revert:** `OP → SD` restores the edited file(s) to the manifest
   state; rerun S1 → hashes match → rsync proceeds (likely a no-op) and
   verification runs.
7. **Branch B — force:** `OP → ANS` reruns with
   `-e nikolaigogol_scripts_force=true`.
8. `ANS → TER`: the drift guard is skipped; rsync overwrites the recorded files
   whose content differs, **does not delete** extra/stale files (`delete: false`),
   re-renders `.env` (`0600`), recomputes the tree and per-file digests, and
   writes a new `.deploy-state`.
9. `ANS → OP`: reports the scripts path and `changed` status.

**Alternates / branches**

- Only added files → `sha256sum -c` reports no `FAILED` lines; the failure message
  falls back to the tree-hash comparison.
- Only `.env` edited → no drift is detected (it is excluded); the redeploy
  overwrites `.env` without warning.
- Editor reverts to recorded content → guard passes; `.deploy-state` may be
  rewritten only if the tree hash differs (normally it does not).
- Force run with an extra file present → the extra file remains; it is not in the
  new manifest's `files` list unless the digest collection includes it (the role
  hashes all non-excluded files, so an added file is included in the new tree and
  per-file digests, while rsync did not delete it).

**Outcome**

Either the conflict is resolved by reverting to the recorded state, or the
operator explicitly accepts overwriting recorded files with `force=true`. The
manifest then describes the resulting tree.

**Notes / caveats**

- What is overwritten: files whose content differs from the rsync source and
  whose paths are included (excluding `.git`, `.env`, `result-*`,
  `node_modules`, `.yarn/cache`). Extra files are **not** removed.
- What the manifest becomes: `tree_sha256` over the post-sync tree (excluding
  `.env`/`.deploy-state*`), fresh per-file digests for every included file, the
  same `source`, and a new `deployed_at`.
- The guard fails **before** rsync, so a failed dirty run leaves the previous
  payload intact.
- `force=true` is a one-run override; it is not persisted in the manifest.

---

### S9 — Reverse flow

| | |
|---|---|
| **Id** | `S9` |
| **Actors** | `OP`, `CN`, `ANS`, `TER`, `SD`, `UP`, `PIN` |
| **Precondition** | A fix exists only in `_scripts` on `@terra` (S2, or a script edit made during S3), `.deploy-state` is intact, the `@NikolaiGogol` submodule checkout and its superproject pin exist on `CN`, and `CN` holds the only GitHub credential. |

**Sequence**

1. `OP → ANS`: re-run the scripts step — `make -f Makefile.NixosScripts dry`
   (or `run`). The role hashes the target tree, excluding `.env` and
   `.deploy-state*`, and compares it with `manifest.tree_sha256`.
2. `ANS → OP`: on mismatch with `force=false`, fail **before rsync** and list the
   drifted (`FAILED`) paths. This failure is the detection signal (S8 step 5), not
   an error to force past.
3. `OP → CN`: create `$PULL_ROOT/<stamp>/` and its `snapshot/` directory,
   with `PULL_ROOT` outside the repository; the worktree is created by git
   in step 6.
4. `OP → TER/SD`: rsync the target to `snapshot/` with
   `-az --checksum --no-owner --no-group`, excluding `.env`, `.deploy-state`,
   `.deploy-state.*`, `.git`, `node_modules`, `.yarn/cache`, `result-*`.
   No `--delete`.
5. `OP → UP`: resolve the pin. `@NikolaiGogol` is the submodule
   `ConvPlatProv__NikolaiGogol`; the superproject pin records a gitlink.
   `PIN_SUB="$(git -C "$SUPER" rev-parse "$PIN_SUPER:@NikolaiGogol")"`.
   At base HEAD `PIN_SUPER=fd56f6b…` resolves to `e6bd599…`.
6. `OP → UP`: `git -C "$SUB" worktree add --detach "$WORKTREE" "$PIN_SUB"`.
7. `OP → UP`: overlay `snapshot/` onto `$WORKTREE` with
   `rsync -a --checksum --delete --exclude=.git`; `--delete` is confined to the
   disposable worktree and is what expresses remote deletions.
8. `OP → UP`: `git add -A`; review `git diff --cached --stat`,
   `--summary` (mode changes, new/deleted files), `--numstat` (binaries) and
   `--cached` (content). The diff is remote **vs pin**, not vs the dirty
   control-node checkout.
9. `OP → UP`: validate: `bash -n` on every `*.sh`; `git diff --cached --check`;
   compose validation on `@terra` with the rendered `.env` (`@terra` is
   authoritative). A control-node `--env-file .env.example` check is a shape
   check only; `.env` is never pulled.
10. `OP → UP`: create `edge/terra-<date>` in the worktree, commit one logical fix
    per commit, and state in the body that the change came from an on-`@terra`
    debug session and was reviewed against `PIN_SUB`.
11. `OP → UP`: `git push -u origin edge/terra-<date>`; open a PR in
    `ConvPlatProv__NikolaiGogol`; merge normally, **no auto-merge**.
12. `OP → PIN`: after the merge, bump the `@NikolaiGogol` gitlink in the
    superproject (`git add @NikolaiGogol`, commit only that path, push), then
    record the new superproject sha with `refs-update` (planned) or the pin var.
13. `OP → ANS`: run S0 (`TAGS=image,container,scripts`), or S1
    (`TAGS=scripts`) for a script-only fix that changes no image/bind payload.
    The role re-syncs, re-renders `.env`, and rewrites `.deploy-state` from the
    new tree.
14. `OP → TER`: verify with S7. The next scripts run must be clean (no drift).

**Alternates / branches**

- Remote deletion → the `--delete` overlay stages it; review the deletion and
  commit it with an explicit reason. Without `--delete` the pinned copy would
  silently remain and the deletion would be lost.
- Stale file reappears as an addition → `delete: false` kept a file upstream
  already deleted. Check upstream history; do not commit it blindly.
- Remote added file → appears in `git add -A`; commit it if it is source,
  otherwise remove it on the target.
- `.env` edited remotely → not drift (excluded) and never pulled; change
  `env.j2`/group vars instead.
- Manifest missing/corrupt → the guard is blind; diff the target against the pin
  manually before deploying.
- Mode change → `rsync -a` preserved it, but this submodule has
  `core.filemode=false`; use `git update-index --chmod=+x <path>` and verify
  with `git ls-tree`.
- Binary change → `--stat` shows `Bin`, `--numstat` shows `-`; review bytes.
- Upstream moved since the pin → the diff is vs the old pin; optionally add a
  second worktree at `origin/main`, then branch from the pin and rebase/merge
  normally. No force-push.
- Syntax/review failure → fix inside the disposable worktree and re-check; no
  commit or push is produced.
- Compose validation unavailable → skip the control-node shape check; the
  target-side check in S7 remains authoritative.
- `Unix_dotfiles` bind edit → the same S9 pattern in the `Unix_dotfiles` repo
  with `nixos_unix_dotfiles_ref` (default branch `dev`). Do not run
  `nixos_edge_sync` first: its `delete: true` would remove the remote edits.
- `@Manilov` XML edit → run `virsh -c qemu:///system dumpxml hass_qemu16` in the
  container, diff against the pinned `Virt_scripts_bootstrap/vmDefinition.xml`,
  commit the intended delta in `Virt_scripts`, re-pin
  `nixos_virt_scripts_ref`. Do not copy runtime-generated XML verbatim, and do
  not use `undefine --remove-all-storage` as cleanup.
- `force=true` before pulling → forbidden. If a discard is genuinely intended,
  take the snapshot first, then force; the snapshot is the only remaining copy.
- `INVENTORY=tests/integration/inventory.ini` → the mock has no `_scripts`; the
  planned `scripts-pull` target refuses it.

**Outcome**

The on-`@terra` fix exists as a reviewed commit on a branch/PR in the owning
repository, the superproject pin records the new gitlink, and the next S0/S1 run
rewrites `.deploy-state` with no drift. `@terra` still has no git, no key, and no
GitHub access.

**Notes / caveats**

- The flow is pull-based from `CN`; nothing is pushed from `@terra`. There is no
  copy-out path that bypasses review.
- `_scripts/.deploy-state` is the **detector**, not a backup. It stores digests,
  not content; once `force=true` overwrites the tree, the only copy of the fix is
  gone. Hence the fixed order: pull → review → commit → re-pin → deploy.
- `@NikolaiGogol` is a submodule. A commit in the superproject alone records a
  gitlink, not script content; the worktree and the commit belong to
  `ConvPlatProv__NikolaiGogol`.
- The scripts role has no pin variable at base HEAD and
  `.deploy-state.source` records a path, not a commit. The dependency pin
  (`nixos_virt_scripts_ref`/`_commit`, planned) is the commit anchor; adding
  `source_commit` to the manifest is the RFC §6.3 refactor item.
- The design brief's "`@NikolaiGogol` pin var" does not exist at base HEAD; the
  exact storage location remains `TBD` with the planned `refs-update`.
- `scripts-pull` is specified in the RFC §11.10 and must stop before
  branch/commit/push/pin/deploy.

## 4. Failure branches

| Failure | Detected by | Behaviour | Remediation |
|---|---|---|---|
| Missing source (control node) | `stat` + assert in the scripts role (and planned dependency checkout asserts) | Fail before target sync; no target mutation | Clone the repo at the expected path, or set `nikolaigogol_scripts_source_dir` / the dependency source var |
| Wrong / absent ref | Planned git resolution on `CN` | Fail before checkout/sync; unknown ref cannot be resolved to a sha | `refs-update` to pin a sha, or pass a valid `-e <repo>_ref=` |
| Git auth failure | Planned `git fetch`/checkout on `CN` | Fail on `CN`; `@terra` is unaffected | Load the control-node key/agent; confirm `known_hosts` has `github.com`; verify repo access |
| Dirty target | Target tree hash vs `.deploy-state` | Fail before rsync; list drifted files | Inspect edits, then revert or rerun with `nikolaigogol_scripts_force=true` |
| Missing `docker` on target | `command -v docker` in the scripts role | Compose validation skipped with a debug message; role continues | Install Docker (Layer 0) or accept the skipped validation |
| Missing `make` on target | `command -v make` in the scripts role | `make -n image-name` probe skipped with a debug message; role continues | Install `make` or accept the skipped probe |
| Missing `rsync` on target | Image-sync `command -v rsync` | Fail early unless automatic install is allowed | Install `rsync`, or set `nixos_image_sync_install_rsync=true` |
| Compose env error | `docker compose config -q` | Compose validation fails; the container role stops before/at compose | Ensure all 11 `.env` keys and the three `${...:?error}` mount sources exist |
| Missing HAOS file mount | `stat` of the file mount source | Fail closed before `docker compose up` | Stage the qcow2 at `nixos_container_home_assistant_image` |
| Empty image tag / no artifact facts | Container and image-load input asserts | Fail before import/recreate | Build the artifact, run `TAGS=image`, or pin a literal `nixos_image_tag` |

## 5. Diagram guidance for the architect

Render **S0, S1, S2, S3, S6, S7, and S8** as separate `@startuml` blocks: S0 is
the authoritative end-to-end deploy, S1 is the Phase 0 scripts-only flow, S2 and
S3 are the two unmanaged edge paths (remote files vs in-container rebuild), S6 is
the VM/libvirt lifecycle, S7 is the acceptance check, and S8 is the dirty-target
conflict. S4 and S5 are short enough to render as their own blocks if the diagram
needs the promotion and pinning contracts visible; otherwise fold S4 into S0 as a
precondition note and S5 into a note on the planned `PIN` actor. Use `alt/else`
inside S1 and S8 for the clean/drift/force branches, inside S2 for
"edit only" vs "make/script run", inside S3 for `test` vs `switch` vs rollback,
inside S6 for define/start vs undefine, and inside S0 for artifact
missing/present, image already loaded/imported, and dependency layers
enabled/disabled. Do not draw a single mega-sequence: the scenarios have
different authority (S0 authoritative; S1/S2/S3/S6/S7 debug/edge; S4/S5
promotion) and merging them would imply a single writer and a single lifetime
that the RFC explicitly rejects.

`S9` (reverse flow: recovering on-`@terra` edits) is also rendered as its own
block. It is appended here rather than folded into S0–S8 because it runs in the
opposite direction and has its own authority boundaries (pull, review, commit,
re-pin, deploy).
