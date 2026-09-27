# Plan — Sync the NixOS image (local → `@terra`) and deploy the `@NikolaiGogol` system container

## 0. Inputs & pinned revisions

| Input | Value |
|---|---|
| Target repo | `PersonalLentServers%Russian_dotfiles.bootstrap` (single initial commit on `main`) |
| Companion docs read | `docs/HomeServer__HomeAssistant_plan.md`, `docs/adr/0001-HomeServer__HomeAssistant.md`, `docs/Deploy#NixContainer.puml`, `.agents/findings-nixos-image-sync-2026-09-27.md`, `.agents/AGENTS.md`, `tests/README.md` |
| Image source (build) | local workstation `~/.bookmarks/shared-configs/Unix_dotfiles`, target `build-NikolaiGogol` → `result-NikolaiGogol/tarball/nixos-system-x86_64-linux.tar.xz` |
| Deployed source of truth | `ConvPlatProv-HomeServer__HomeAssistant/@NikolaiGogol` (`docker-compose-system.yml`, `.env.example`, `switch-nixos.sh`, `Makefile`) |
| Target host | `@terra` — TerraMaster NAS, TOS 6 (already bootstrapped: Docker + Nix by Layer 0) |
| Pinned galaxy role (existing) | `danielrolls.nix` @ `7bef4db07967e433ca9bcf7c7de84eb87814583a` |
| New collection | `ansible.posix` (for `synchronize`/rsync) |
| Existing collection | `community.docker` (used for `docker_compose_v2`, `docker_image_info`) |

## 1. Decisions locked with the user

1. **Scope** — full path: image sync + container deploy + a documented fast *edge-iteration* path. Real container changes are made by editing `Unix_dotfiles` (`NikolaiGogol` host config) and rebuilding; edge-sync helpers are **optional/adhoc**, deployed via Ansible only if required on the TOS host.
2. **Image identity** — content-addressable tag: `ds-omega/nikolai-gogol:<sha12>` where `sha12` = first 12 hex of the tar.xz sha256.
3. **Transfer** — `ansible.posix.synchronize` (rsync `--checksum`) to a staging dir on `@terra`.
4. **Reach `@NikolaiGogol`** — direct SSH (ProxyJump or a dedicated port, e.g. `2223`) is the **primary path for automatic (Ansible) deployment**; `ssh @terra && docker exec -it …` stays available for ad-hoc debugging (reuses the local dev muscle memory).

## 2. Architecture summary

Layer 1 gets its own playbook, per ADR 0001 §"one playbook per layer": **`deploy-nikolaigogol.yml`** targets `terra` (the artifact is *built on the control node* via `delegate_to: localhost`, then rsynced in). Four small roles, one feature each, namespaced vars, tags `image` / `container`:

```
control node (localhost)          @terra (TOS 6, docker daemon)
─────────────────────             ──────────────────────────────
nixos_image_artifact              nixos_image_sync
  select tar.xz + sha256            rsync --checksum → /var/tmp/nixos-images/<sha>.tar.xz
  derive content tag                (idempotent: skip if checksum matches)
                                 nixos_image_load
                                   docker import → ds-omega/nikolai-gogol:<sha12>
                                   (gated on `docker image inspect`)
                                 nixos_container
                                   render compose+env from group_vars
                                   ensure mount dirs
                                   docker compose up -d (recreate on template change)
```

Two speeds, both idempotent:
- **Fast edge iterate** — edit `Unix_dotfiles` → `make build-NikolaiGogol` → `make run TAGS=image,container`. (Optional adhoc: rsync config + `nixos-rebuild switch` inside the running container — Step 12.)
- **Full chain redeploy** — `make run TAGS=image,container` is a no-op if nothing changed; a new sha tag triggers import + recreate only.

No new runtime deps on `@terra` beyond Docker (already bootstrapped). `bootstrap_nix` on `@terra` is **not** required for this model (image is prebuilt); leave it as-is.

## 3. Ordered steps (each independently verifiable by Build)

### Step 1 — Pin the new collection + extend the structure guard
- **Files:** `requirements.yml` (add `ansible.posix`), `tests/unit/test_repo_structure.py` (generalize to also validate `deploy-nikolaigogol.yml`: targets `terra`, roles exist + namespaced, `backup_tos` not reordered ahead of anything it shouldn't be).
- **Tests:** unit (`make unit`).
- **Acceptance:** `make unit` green; `ansible-galaxy install -r requirements.yml` succeeds.

### Step 2 — Fill `group_vars/nikolaigogol/vars.yml`
- **Files:** `group_vars/nikolaigogol/vars.yml` (replace the two placeholder keys).
- Values: `namespace=ds-omega`, `image_base_name=nikolai-gogol`, `image_tag` derived at runtime (do **not** hardcode `latest`), `container_name=HomeServer__HomeAssistant.NikolaiGogol`, `container_username=ds13`, mount roots (`unix_dotfiles_dir`, `virt_scripts_bootstrap_dir`, `home_assistant_image_path`), staging dir, ssh port `2223`, `ansible_connection`/`ansible_user` for the debug override. Document `vault_*` placeholders for age/HA secrets (no secret required for image sync itself).
- **Tests:** unit (structure test asserts namespacing of any new defaults).
- **Acceptance:** `make unit` green.

### Step 3 — Role `nixos_image_artifact` (control node)
- **Files:** `roles/nixos_image_artifact/{defaults,tasks}/main.yml`.
- Behaviour: `delegate_to: localhost`, `become: false`. Locate `result-<system>/tarball/nixos-system-x86_64-linux.tar.xz` (default path from `Unix_dotfiles`), `stat` + `sha256sum` it, derive `nixos_image_name`/`nixos_image_tag` facts. Fail early (per AGENTS.md "validate inputs early") if the artifact is missing.
- **Tests:** unit (tag-derivation length/charset); integration (stubbed artifact fixture, no real build).
- **Acceptance:** role emits `nixos_image_artifact_path/checksum/tag/name`; missing artifact fails with a clear message.

### Step 4 — Role `nixos_image_sync` (transfer)
- **Files:** `roles/nixos_image_sync/{defaults,tasks}/main.yml`.
- Behaviour: `ansible.posix.synchronize` with `mode: push`, `checksum: true`, `dest_port`/`rsync_opts` for the large file; target `/var/tmp/nixos-images/<sha>.tar.xz`. Idempotent via checksum (rsync skips unchanged). Record remote path + checksum fact for the next role.
- **Tests:** integration against mock `@terra` (tiny fixture transfers once, second run no change).
- **Acceptance:** `make it-run TAGS=image` reports `changed` first run, `ok` (no change) second run.

### Step 5 — Role `nixos_image_load` (import)
- **Files:** `roles/nixos_image_load/{defaults,tasks}/main.yml`.
- Behaviour: gate on `docker image inspect <name>:<sha12>`; if absent run `ansible.builtin.command: docker import <tar> <name>:<sha12>` with `become: true` and explicit `changed_when`. Rootfs import intentionally omits ENTRYPOINT/STOPSIGNAL — the compose template supplies `command: /init` + `stop_signal: SIGRTMIN+3` (matches `@NikolaiGogol` today).
- **Tests:** unit (no pure logic → skip); E2E only for the actual import; integration covers the *wiring* via a no-op dry check if the mock daemon is up (documented as best-effort).
- **Acceptance:** E2E `docker image inspect ds-omega/nikolai-gogol:<sha12>` returns; re-run reports no change.

### Step 6 — Role `nixos_container` (compose + mounts)
- **Files:** `roles/nixos_container/{defaults,tasks,handlers,templates}/…` with `templates/docker-compose-system.yml.j2` + `templates/.env.j2`.
- Behaviour: template the system-container compose from `group_vars` (privileged, `cgroup: host`, `network_mode: host`, `cap_add: [NET_ADMIN]`, `security_opt: [seccomp=unconfined]`, `stop_signal: SIGRTMIN+3`, `command: /init`, `pull_policy: never`, three bind mounts); `file`-create the mount source dirs (fail-closed on missing, per findings §8); run `community.docker.docker_compose_v2` (`state: present`, `project_src` = rendered dir). Handler recreates the container when the template/env changes.
- **Tests:** unit (render template; assert all privileged/systemd/mount invariants — the strongest pure-logic target); integration (`docker compose config` validation + dir creation in the mock); E2E (real `up -d`).
- **Acceptance:** rendered `docker compose config` validates; container runs and is recreated only on change.

### Step 7 — Playbook + inventory debug entry
- **Files:** `deploy-nikolaigogol.yml` (hosts `terra`, tags `image` = artifact+sync+load, `container` = container), `hosts.ini` (uncomment/populate `[nikolaigogol]` with `nikolaigogol ansible_host=terra-local ansible_port=2223 …` as the debugging/auto-deploy override).
- **Tests:** `make check` syntax-check; structure test asserts the new playbook.
- **Acceptance:** `make check` clean; `--list-tasks --tags image` and `--tags container` show the expected role order.

### Step 8 — Verification playbook
- **Files:** `verify-nikolaigogol.yml` (targets `terra`; checks `docker image inspect <tag>`, `docker ps` contains the container, `docker exec … /run/current-system/sw/bin/nixos-version`).
- **Tests:** E2E (`make test` equivalent for Layer 1); `make check`.
- **Acceptance:** verify play reports image present + container running + version string.

### Step 9 — Unit tests
- **Files:** `tests/unit/test_nixos_image_step.py` (tag derivation, compose render invariants, default namespacing).
- **Acceptance:** `make unit` green.

### Step 10 — Integration tests
- **Files:** `tests/integration/fixtures/minimal-rootfs.tar.xz` (tiny stub), `tests/integration/playbook.yml` (add `image`/`container` tags with mock vars, stub artifact source), optionally extend `Dockerfile.target` if the mock needs `rsync`.
- **Acceptance:** `make it-up && make it-run TAGS=image && make it-run TAGS=container` succeeds; render + `docker compose config` validate; second run no-change.

### Step 11 — Manual makefiles + connect helper
- **Files:** `Makefile.NixosImage` (`STEP_TAGS := image`), `Makefile.NixosContainer` (`STEP_TAGS := container`), both `include Makefile.Steps`; add a `connect-container` target (`ssh terra … docker exec -it --user ds13 <name> /run/current-system/sw/bin/bash`) and a documented direct-SSH form (`ssh -p 2223 ds13@terra-local` or `ssh -J terra ds13@nikolaigogol`). Update `Makefile` `help`.
- **Acceptance:** `make -f Makefile.NixosImage dry` (agent, `--check --diff`), `make -f Makefile.NixosContainer shell-ssh` (human).

### Step 12 — Docs + optional edge-sync helper
- **Files:** `README.md` (deploy/iterate workflow, two-speed model), `docs/HomeServer__HomeAssistant_plan.md` (mark Phase 5 `deploy-nikolaigogol` as done; add matrix row), `docs/adr/0001-*.md` (flip Layer 1 status to Accepted), and an **optional, off-by-default** `roles/nixos_edge_sync/` + `Makefile.NixosEdgeSync` (rsync `Unix_dotfiles` checkout to the `@terra` bind-mount dir, then `nixos-rebuild switch --flake` inside the running container via SSH) — only deployed if you decide the TOS host needs it; otherwise adhoc only.
- **Acceptance:** docs reflect reality; edge-sync helper is inert unless a `nixos_edge_sync_enabled` flag is set.

## 4. Affected files / interfaces

**New:** `deploy-nikolaigogol.yml`, `verify-nikolaigogol.yml`, `roles/nixos_image_artifact/**`, `roles/nixos_image_sync/**`, `roles/nixos_image_load/**`, `roles/nixos_container/**` (+`templates/docker-compose-system.yml.j2`, `.env.j2`), `tests/unit/test_nixos_image_step.py`, `tests/integration/fixtures/*`, `Makefile.NixosImage`, `Makefile.NixosContainer`, (optional) `roles/nixos_edge_sync/**`, `Makefile.NixosEdgeSync`.
**Modified:** `requirements.yml` (`ansible.posix`), `group_vars/nikolaigogol/vars.yml`, `hosts.ini` (`[nikolaigogol]` entry), `tests/integration/playbook.yml`, `tests/unit/test_repo_structure.py`, `Makefile` (`help`), `README.md`, `docs/HomeServer__HomeAssistant_plan.md`, `docs/adr/0001-HomeServer__HomeAssistant.md`.

## 5. Data migration

None (new layer). Content-addressable import is additive; any manual `:latest` images from earlier tinkering are left untouched (document a one-time `docker rmi ds-omega/nikolai-gogol:latest` cleanup as optional). Staging dir `/var/tmp/nixos-images/` accumulates by sha — document a `clean` target (rsync `--delete` on the current tag or a prune note).

## 6. Testing matrix (repo convention: unit / integration / E2E / manual)

| Step (tag) | Unit | Integration | E2E | Manual |
|---|---|---|---|---|
| artifact (`image`) | tag-derivation | stub artifact | real build path | `Makefile.NixosImage` |
| sync (`image`) | — | tiny fixture, no-change on 2nd run | real rsync | `Makefile.NixosImage` |
| import (`image`) | — | wiring only (best-effort) | `docker image inspect <tag>` | `Makefile.NixosImage` |
| container (`container`) | compose render invariants | `docker compose config` + dirs | `up -d` + recreate | `Makefile.NixosContainer` |
| verify | — | — | `verify-nikolaigogol.yml` | `make -f Makefile.NixosContainer verify` |

## 7. Observability

Debug tasks print `artifact path / sha256 / tag`, rsync result, import image id, and `docker compose ps` in verify. No new metrics/log sinks (out of scope for a "simple sync").

## 8. Rollback

| Change | Rollback |
|---|---|
| New image (bad) | keep prior tag; set `group_vars` image tag back, re-run `TAGS=container` (no re-import needed) |
| Staged tar | `rm /var/tmp/nixos-images/<sha>.tar.xz` (additive only) |
| Compose/config | revert template/`group_vars`, re-run `TAGS=container` (handler recreates) |
| Whole layer | `docker compose -f <rendered> down` + leave image tags intact |

## 9. Completion evidence

- `make check` + `make lint` clean; `make unit` green.
- `make it-up && make it-run TAGS=image,container` renders + validates, second run reports **no changes**.
- E2E: `docker image inspect ds-omega/nikolai-gogol:<sha12>` present; `docker ps` shows the container; `nixos-version` prints from inside; direct SSH (`-p 2223`) works.
- `README`/plan/ADR describe the two-speed model; `rg -i latest` no longer appears in `group_vars/nikolaigogol`.

## 10. Unresolved decisions (confirm on first live run)

1. Exact build target name/artifact path in `Unix_dotfiles` (`build-NikolaiGogol` assumed — findings §11).
2. `options.nix` in `@NikolaiGogol` still points at `misterio77/nix-starter-config` (placeholder); confirm the deployed image is produced by the `Unix_dotfiles` `NikolaiGogol` flake, not the skiffos base (findings §9.8).
3. sshd port (`2223`) and authorized-keys wiring for direct SSH — a `Unix_dotfiles` change, outside this repo.
4. Actual `@terra` mount roots (`UNIX_DOTFILES`, `VIRT_SCRIPTS_BOOTSTRAP`, `HOME_ASSISTANT_IMAGE`) and storage volume layout.
5. Whether `bootstrap_nix` stays on `@terra` (unused by the prebuilt-image model) — leave as-is unless you want it removed.
6. Collection pinning policy — `ansible.posix`/`community.docker` are currently unpinned (only roles are pinned by the structure test); pin to versions if you want stricter reproducibility.

## 11. Out of scope (noted, not planned here)

- `@Manilov` (HAOS VM, Layer 2) provisioning and `HOME_ASSISTANT_IMAGE` staging — only the mount point is created here.
- `@tangerineDream` launcher/`SYSTEM_STRATEGIES` parity port — aspirational, separate task.
