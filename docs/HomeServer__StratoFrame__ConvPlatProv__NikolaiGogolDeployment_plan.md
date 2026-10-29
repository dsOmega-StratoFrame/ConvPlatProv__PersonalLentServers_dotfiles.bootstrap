# Plan — Sync the NixOS image (local → `@terra`) and deploy the `@NikolaiGogol` system container

## 0. Inputs & pinned revisions

| Input | Value |
|---|---|
| Target repo | `PersonalLentServers%Russian_dotfiles.bootstrap` (single initial commit on `main`) |
| Companion docs read | `docs/HomeServer__HomeAssistant_plan.md`, `docs/adr/0001-HomeServer__HomeAssistant.md`, `docs/Deploy#NixContainer.puml`, `docs/NikolaiGogol__DependencyLayers_plan.md`, Logseq `ai-rsh Researcher_system/NG-IMAGE-SYNC-001 NikolaiGogol image sync to @terra evidence` (formerly `.agents/findings-nixos-image-sync-2026-09-27.md`), `.agents/AGENTS.md`, `tests/README.md` |
| Image source (build) | local workstation `~/.bookmarks/shared-configs/Unix_dotfiles`, target `build-NikolaiGogol` → `result-NikolaiGogol/tarball/nixos-system-x86_64-linux.tar.xz` |
| Deployed source of truth | `ConvPlatProv-HomeServer__HomeAssistant/@NikolaiGogol` (`docker-compose-system.yml`, `.env.example`, `switch-nixos.sh`, `Makefile`) |
| Target host | `@terra` — TerraMaster NAS, TOS 6 (already bootstrapped: Docker + Nix by Layer 0) |
| Pinned galaxy role (existing) | `danielrolls.nix` @ `7bef4db07967e433ca9bcf7c7de84eb87814583a` |
| New collection | `ansible.posix` (for `synchronize`/rsync) |
| Existing collection | `community.docker` (used for `docker_compose_v2`, `docker_image_info`) |

## 1. Decisions locked with the user

1. **Scope** — full path: image sync + container deploy + a documented fast *edge-iteration* path. Real container changes are made by editing `Unix_dotfiles` (`NikolaiGogol` host config) and rebuilding; edge-sync helpers are **optional/adhoc**, deployed via Ansible only if required on the TOS host.
2. **Image identity** — content-addressable tag: `ds-omega/nikolai-gogol:<sha12>` where `sha12` = first 12 hex of the tar.xz sha256. The rule has a single implementation, shared with the build-side repos: `invoke --search-root=~/.bookmarks/shared-scripts conv-plat-prov.content-tag <tarball>` (see ADR 0002 and §12).
3. **Transfer** — `ansible.posix.synchronize` (rsync `--checksum`) to a staging dir on `@terra`.
4. **Reach `@NikolaiGogol`** — direct SSH (ProxyJump or a dedicated port, e.g. `2223`) is the **primary path for automatic (Ansible) deployment**; `ssh @terra && docker exec -it …` stays available for ad-hoc debugging (reuses the local dev muscle memory).

## 2. Architecture summary

Layer 1 gets its own playbook, per ADR 0001 §"one playbook per layer": **`deploy-nikolaigogol.yml`** targets `terra` (the artifact is *built on the control node* via `delegate_to: localhost`, then rsynced in). Four small roles, one feature each, namespaced vars, tags `image` / `container`. The play imports the read-only privilege preflight (`tasks/preflight_privilege_model.yml`, `tags: [always]`): on TOS 6 the SSH account `terra` is uid 0 while `root` is uid 9999, so any forced `become` must target `ansible_become_user` (ADR 0003):

```
control node (localhost)          @terra (TOS 6, docker daemon)
─────────────────────             ──────────────────────────────
nixos_image_artifact              nixos_image_sync
  select tar.xz + sha256            rsync --checksum → {{ zterra_root }}/local-/var-/cache/nixos-images/<sha>.tar.xz
  derive content tag                (shared cmd on localhost)
                                    (idempotent: skip if checksum matches)
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
- Tag derivation (ADR 0002): runs the shared command `invoke --search-root=~/.bookmarks/shared-scripts conv-plat-prov.content-tag <tarball>` on the control node (`nixos_image_artifact_content_tag_command`) and asserts its output equals the artifact `stat` sha256 slice. Production sets `nixos_image_artifact_content_tag_required: true` (`group_vars`); the role default is `false` so tests stay hermetic and fall back to the slice. Requires `invoke` on the control-node PATH, provided by the dev shell.
- **Tests:** unit (tag-derivation length/charset); integration (stubbed artifact fixture, no real build).
- **Acceptance:** role emits `nixos_image_artifact_path/checksum/tag/name`; missing artifact fails with a clear message.

### Step 4 — Role `nixos_image_sync` (transfer)
- **Files:** `roles/nixos_image_sync/{defaults,tasks}/main.yml`.
- Behaviour: `ansible.posix.synchronize` with `mode: push`, `checksum: true`, `dest_port`/`rsync_opts` for the large file; target `{{ zterra_root }}/local-/var-/cache/nixos-images/<sha>.tar.xz` (the zterra NVMe namespace; see TOS-ZTERRA-002 / `@terra__ConfigsLocation_strategy`). Idempotent via checksum (rsync skips unchanged). Record remote path + checksum fact for the next role.
- **Tests:** integration against mock `@terra` (tiny fixture transfers once, second run no change).
- **Acceptance:** `make it-run TAGS=image` reports `changed` first run, `ok` (no change) second run.

### Step 5 — Role `nixos_image_load` (import)
- **Files:** `roles/nixos_image_load/{defaults,tasks}/main.yml`.
- Behaviour: gate on `docker image inspect <name>:<sha12>`; if absent run `ansible.builtin.command: docker import <tar> <name>:<sha12>` with `become: true` and explicit `changed_when`. TOS 6 privilege model (ADR 0003): `become_user: "{{ ansible_become_user | default('root') }}"` targets the configured uid-0 admin account, never TOS's unprivileged `root` (uid 9999) — defaulting to `root` drops privileges. Rootfs import intentionally omits ENTRYPOINT/STOPSIGNAL — the compose template supplies `command: /init` + `stop_signal: SIGRTMIN+3` (matches `@NikolaiGogol` today).
- **Tests:** unit (no pure logic → skip); E2E only for the actual import; integration covers the *wiring* via a no-op dry check if the mock daemon is up (documented as best-effort).
- **Acceptance:** E2E `docker image inspect ds-omega/nikolai-gogol:<sha12>` returns; re-run reports no change.
- **Caveat:** `docker image inspect` is metadata-only. A `docker import` that fails mid-unpack (e.g. ENOSPC) can still leave the tag behind, so the next run reports “already loaded” (`logs/20261021T170816-image.log`). Use `nixos_image_load_force=true` to re-import a suspect image; the containerd-root relocation removes the common cause.

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

**New:** `deploy-nikolaigogol.yml`, `verify-nikolaigogol.yml`, `roles/zterra_mount/**`, `roles/zterra_layout/**`, `roles/zterra_binds/**`, `roles/zterra_docker_data/**` (the zterra NVMe namespace; TOS-ZTERRA-002 / `@terra__ConfigsLocation_strategy`, added after the `/var/tmp` ENOSPC in `logs/20261010T180200-image.log`), `roles/nixos_image_artifact/**`, `roles/nixos_image_sync/**`, `roles/nixos_image_load/**`, `roles/nixos_container/**` (+`templates/docker-compose-system.yml.j2`, `.env.j2`), `tests/unit/test_nixos_image_step.py`, `tests/unit/test_zterra_step.py`, `tests/integration/fixtures/*`, `Makefile.Zterra`, `Makefile.NixosImage`, `Makefile.NixosContainer`, (optional) `roles/nixos_edge_sync/**`, `Makefile.NixosEdgeSync`.
**Modified:** `requirements.yml` (`ansible.posix`), `group_vars/nikolaigogol/vars.yml`, `hosts.ini` (`[nikolaigogol]` entry), `tests/integration/playbook.yml`, `tests/unit/test_repo_structure.py`, `Makefile` (`help`), `README.md`, `docs/HomeServer__HomeAssistant_plan.md`, `docs/adr/0001-HomeServer__HomeAssistant.md`.

## 5. Data migration

None (new layer). Content-addressable import is additive; any manual `:latest` images from earlier tinkering are left untouched (document a one-time `docker rmi ds-omega/nikolai-gogol:latest` cleanup as optional). Staging dir `{{ zterra_root }}/local-/var-/cache/nixos-images/` accumulates by sha — document a `clean` target (rsync `--delete` on the current tag or a prune note).

**Docker 29 containerd image store (2026-10-21).** `@terra` runs Docker 29.9.0, which enables the containerd image store on fresh installs. `daemon.json data-root` moves Docker's volumes/metadata but **not** image blobs, snapshots or the unpack temp: those live under containerd's own `root` (`/var/lib/containerd`). The first `docker import` therefore filled md9 `/` (7.5 GiB) and failed with ENOSPC even though `data-root` pointed at zterra (`logs/20261021T170951-image.log`). `zterra_docker_data` now also writes a containerd systemd drop-in (`--root {{ zterra_root }}/var-/lib/containerd`) and a docker drop-in with `RequiresMountsFor` for both roots, so a missing `zterra.mount` (it is `nofail`) fails the daemon instead of silently writing to the root fs. One-time operator step on an existing host: remove/re-import any partial image, then start the stack; `/var/lib/containerd` on the root fs can be moved aside once the new root is verified.

## 6. Testing matrix (repo convention: unit / integration / E2E / manual)

| Step (tag) | Unit | Integration | E2E | Manual |
|---|---|---|---|---|
| zterra (`zterra`) | `test_zterra_step.py` | `make it-run TAGS=zterra` | `make -f Makefile.Zterra run` | `Makefile.Zterra` |
| artifact (`image`) | tag-derivation | stub artifact | real build path | `Makefile.NixosImage` |
| sync (`image`) | — | tiny fixture, no-change on 2nd run | real rsync | `Makefile.NixosImage` |
| import (`image`) | — | wiring only (best-effort) | `docker image inspect <tag>` | `Makefile.NixosImage` |
| container (`container`) | compose render invariants | `docker compose config` + dirs | `up -d` + recreate | `Makefile.NixosContainer` |
| verify | — | — | `verify-nikolaigogol.yml` | `make -f Makefile.NixosContainer verify` |

## 7. Observability

Debug tasks print `artifact path / sha256 / tag`, rsync result, import image id, and `docker compose ps` in verify. Tag parity is logged by comparing the shared-command output with the artifact slice (ADR 0002 D3). No new metrics/log sinks (out of scope for a "simple sync").

## 8. Rollback

| Change | Rollback |
|---|---|
| New image (bad) | keep prior tag; set `group_vars` image tag back, re-run `TAGS=container` (no re-import needed) |
| Staged tar | `rm {{ zterra_root }}/local-/var-/cache/nixos-images/<sha>.tar.xz` (additive only) |
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
7. **Symlinked-artifact stat caveat (F3):** `ansible.builtin.stat` does not follow a symlink that is the *final* path component, so a symlinked artifact reports no `checksum`. The real artifact path (`result-NikolaiGogol/tarball/...`) is a regular file, so this is a test-fixture caveat, not a role bug.
8. **Shared-command ownership / pinning (ADR 0002 open questions 1–2):** the content-tag command is a cross-repo contract invoked by working-tree path, with no revision pin and no named owner yet.
9. **`invoke` guarantee on the control node (ADR 0002 open question 3):** production requires `invoke`; the dev shell provides it, but a control node driven outside `nix develop` (e.g. `bin/dot-bootstrap` auto-install) needs a defined non-Nix path.

## 11. Out of scope (noted, not planned here)

- `@Manilov` (HAOS VM, Layer 2) runtime provisioning — out of scope. HAOS image staging is **planned** — see [`docs/NikolaiGogol__DependencyLayers_plan.md`](./NikolaiGogol__DependencyLayers_plan.md).
- `@tangerineDream` launcher/`SYSTEM_STRATEGIES` parity port — aspirational, separate task.

## 12. Cross-repo content-addressable tag contract (follow-up; ADR 0002)

The original Step 3 derived the tag in-role. A follow-up (build result §6b; user
request "support such tag creation at the NikolaiGogol repo, so local testing
matches remote") moved the rule into ONE shared command so the build side and the
deploy side cannot drift. Full decision record:
[`adr/0002-ContentAddressableImageTag.md`](./adr/0002-ContentAddressableImageTag.md).

- **Single source of truth:** `invoke --search-root=~/.bookmarks/shared-scripts conv-plat-prov.content-tag <tarball>`
  (`conv_plat_prov.compute_content_tag()`, streaming sha256, default `--length 12`).
- **Deploy side (this repo):** `roles/nixos_image_artifact` runs that command on
  the control node (`delegate_to: localhost`; nothing is sent to `@terra`),
  asserts its output equals the artifact `stat` sha256 slice, and uses it as
  `nixos_image_artifact_tag`. New defaults:
  `nixos_image_artifact_content_tag_command` and
  `nixos_image_artifact_content_tag_required` (default `false`;
  `group_vars/nikolaigogol/vars.yml` sets `true`). `flake.nix` adds `invoke` to
  the dev shell.
- **Build side:** `Unix_dotfiles` `Makefile.ConvPlatProv-docker`
  (`image-tag-<machine>` / `tarball-<machine>`) and `@NikolaiGogol` `Makefile`
  (`IMAGE_TAG` / `IMAGE_NAME`; `import-nixos` then adds a local `:latest` alias)
  call the same command.
- **`:latest`:** local alias only; the deploy and verify paths use exclusively
  the content tag.
- **Cross-repo edges:** this repo → shared-scripts; `Unix_dotfiles` →
  shared-scripts; `@NikolaiGogol` → shared-scripts.

Affected files for this follow-up: this repo —
`roles/nixos_image_artifact/{defaults,tasks}/main.yml`,
`group_vars/nikolaigogol/vars.yml`, `flake.nix`, `README.md`; other repos —
`shared-scripts/conv_plat_prov.py`,
`Unix_dotfiles/Makefile.ConvPlatProv-docker`, `@NikolaiGogol/Makefile`,
`@NikolaiGogol/.env.example`. Test:
`test_shared_content_tag_command_matches_fixture` (fixture tag `ecfcf1d2a1e3`).
No commits were made in any repository.

Findings F1–F4, compatibility guarantees and prohibited changes are recorded in
ADR 0002, along with the escalated open questions (shared-command ownership,
revision pinning, and the `invoke` guarantee on a non-dev-shell control node).
