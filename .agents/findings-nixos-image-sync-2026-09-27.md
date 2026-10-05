# Findings — deploying the Dockerized NixOS image from `@NikolaiGogol` to TOS (`@terra`)

> **Correction (2026-09-27):** an earlier draft of this file said the image came
> from `@tangerineDream`. That was wrong. The deployed source is the
> **`@NikolaiGogol` project** (`ConvPlatProv-HomeServer__HomeAssistant/@NikolaiGogol`).
> `@tangerineDream` is **not** part of this deployment chain; it is a sibling that
> happens to share the same infrastructure pattern (Makefile + compose + a
> `switch-nixos.sh` that builds and runs a NixOS system container). The user
> wishes `@NikolaiGogol` had `@tangerineDream`'s richer tooling, but that is
> aspirational, not a dependency.
>
> Builder findings for a **future plan session**. Investigation input, **not** an
> architecture decision. Role decomposition below is a *proposal*. Scratch file.

## 1. Goal restatement

Take the NixOS system-container image built for the **`NikolaiGogol` system**
(from `Unix_dotfiles`) and deploy it to the TerraMaster NAS `@terra` (TOS 6) as a
privileged systemd container — expressed as idempotent Ansible roles in
`PersonalLentServers%Russian_dotfiles.bootstrap`, replacing the manual
`switch-nixos.sh` workflow with a remote, re-runnable play (roadmap:
`deploy-nikolaigogol.yml`, Layer 1 `@NikolaiGogol`).

## 2. Evidence gathered (paths)

**Primary (the source in the deployment path):**

- `.../2026/ConvPlatProv-HomeServer__HomeAssistant/@NikolaiGogol`
  - `Makefile` — `import-nixos`, `start-system`, `connect-nixos`, `stop/rm-system-container`
  - `switch-nixos.sh` — stop → rm → build → import → start → connect
  - `docker-compose-system.yml` — the NixOS system container (service `NikolaiGogolSystem`)
  - `docker-compose.yml` — skiffos `ghcr.io/skiffos/docker-nixos:latest` base variant
  - `.env.example` — image/container names, `SYSTEM_NAME=NikolaiGogol`
  - `connect.sh`, `flare.nix`/`options.nix` (placeholder flake config)
- `.../ConvPlatProv-HomeServer__HomeAssistant/docker-nixos/Dockerfile` — skiffos-based
  NixOS image build (`STOPSIGNAL SIGRTMIN+3`, `ENTRYPOINT ["/init"]`, `ENV container=docker`)
- `.../ConvPlatProv-HomeServer__HomeAssistant/Makefile` — NAS UI/DHCP helpers (not image build)

**Infrastructure reference only (NOT in the deploy path):**

- `@tangerineDream` — `/usr/local/darkGreen-/tangerineDream/shared-Projects/ChronoIndex/2026/@tangerineDream`
  - richer tooling: `Makefile.launcher`, `scripts/launcher.ts` `SYSTEM_STRATEGIES`
    (env + compose + `sudo: true` per system), runtime-home-bridge, opencode
    state/share wiring. Useful as a **parity target**, not a dependency.

**Other support:**

- Parent `.../2026/docker-image.yaml` — generic build→export→check→copy→load→run pattern with `community.docker`
- Bootstrap repo: `docs/HomeServer__HomeAssistant_plan.md` (§2 layer 1, Phase 5), `docs/adr/0001-...md`, `docs/Deploy#NixContainer.puml`
- Placeholders: `group_vars/nikolaigogol/vars.yml`, `group_vars/manilov/vars.yml`

## 3. The as-is `@NikolaiGogol` flow (local workstation)

`@NikolaiGogol/switch-nixos.sh` (run from the `@NikolaiGogol` project dir):

1. `make stop-system-container` — `sudo docker stop "${CONTAINER_NAME}"` (tolerant)
2. `make rm-system-container` — `sudo docker rm ${CONTAINER_NAME}` (tolerant)
3. **build** on the control node:
   `make --directory=~/.bookmarks/shared-configs/Unix_dotfiles build-${SYSTEM_NAME}`
   with `SYSTEM_NAME=NikolaiGogol` → `result-NikolaiGogol/tarball/nixos-system-x86_64-linux.tar.xz`
4. **import** the rootfs tarball into Docker:
   `sudo docker import ~/.bookmarks/shared-configs/Unix_dotfiles/result-${SYSTEM_NAME}/tarball/nixos-system-x86_64-linux.tar.xz ${IMAGE_NAME}`
5. **start**: `sudo docker compose -f ./docker-compose-system.yml up --detach`
6. **connect**: `./connect.sh` → retries `make connect-nixos` until it succeeds
   (`sudo docker exec -it --user ${CONTAINER_USERNAME} "${CONTAINER_NAME}" /run/current-system/sw/bin/bash`)

Names from `@NikolaiGogol/.env.example`:

- `SYSTEM_NAME=NikolaiGogol`
- `IMAGE_NAME=ds-omega/nikolai-gogol:latest` (`NAMESPACE=ds-omega`, `IMAGE_BASE_NAME=nikolai-gogol`, `IMAGE_TAG=latest`)
- `CONTAINER_NAME=HomeServer__HomeAssistant.NikolaiGogol`
- `CONTAINER_USERNAME=ds13`

Two image approaches present:

- **(A) rootfs import** — `docker import` of `nixos-system-x86_64-linux.tar.xz` (the main `docker-compose-system.yml` path).
- **(C) skiffos base** — `ghcr.io/skiffos/docker-nixos:latest` via `docker-compose.yml` + `options.nix` (placeholder flake config; not the system-container path).
- (B) `docker save`/`load` appears only in the unrelated `docker-image.yaml` parent play.

## 4. Container requirements (critical constraints)

From `@NikolaiGogol/docker-compose-system.yml`:

- `privileged: true`
- `image: ${IMAGE_NAME}` + `pull_policy: never` (local image must exist first)
- `container_name: ${CONTAINER_NAME}`
- `cgroup_parent: docker.slice`, `cgroup: host`
- `network_mode: host`, `cap_add: [NET_ADMIN]`
- `security_opt: [seccomp=unconfined]`
- `stop_signal: SIGRTMIN+3`, `command: /init` (boots systemd; image `ENTRYPOINT /init`)
- volumes (sources must pre-exist / be staged):
  - `${UNIX_DOTFILES}:/home/${CONTAINER_USERNAME}/.bookmarks/shared-configs/Unix_dotfiles`
  - `${VIRT_SCRIPTS_BOOTSTRAP}:/home/${CONTAINER_USERNAME}/.bookmarks/Virt_scripts_bootstrap`
  - `${HOME_ASSISTANT_IMAGE}:/opt/HomeServer__HomeAssistant/haos_ova.qcow2`
- `docker import` requires `sudo`.

## 5. The gap: local → remote/Ansible

| Concern | Local (`@NikolaiGogol`) | Remote/Ansible need |
|---|---|---|
| Build | `make build-NikolaiGogol` in `Unix_dotfiles` (Nix on workstation) | decide build location (control node vs prebuilt artifact) |
| Transfer | local `docker import` | copy artifact to `@terra` (large; checksum + efficient transfer) |
| Load | local `docker import` | remote `docker import` (rootfs tar) — `community.docker.docker_image_load` expects a `docker save` archive, not a rootfs tar |
| Compose/env | `@NikolaiGogol/.env` + `docker-compose-system.yml` | render on `@terra` from `group_vars/nikolaigogol`; translate paths |
| Paths | `~/.bookmarks/...`, `/opt/...` | TOS-specific mount roots; create dirs |
| Privilege | `sudo docker` | `ansible_become` + docker group / sudo |

## 6. Candidate role decomposition — **PROPOSAL (needs sign-off)**

Repo conventions: one feature per role, namespaced vars, `defaults`→`group_vars`, tags, idempotent, per-step tests.

1. `nixos_image_artifact` — on **control node** (`delegate_to: localhost`, `become: false`): ensure/select the `result-NikolaiGogol/tarball/...` artifact; expose path + checksum. Idempotent via `creates:`/checksum.
2. `nixos_image_load` — copy artifact to `@terra` and `docker import`; gate on `docker image inspect <tag>` + artifact checksum so re-runs are no-change.
3. `nixos_container` — template compose + env from `group_vars/nikolaigogol/`; ensure mount dirs; `docker compose up -d`; handler recreates only on config change.
4. (optional) `nixos_image_sync` — orchestrator, or just role ordering.

Plus playbook `deploy-nikolaigogol.yml` with tags e.g. `image`, `container`, `service`; and `Makefile.NixosContainer` (`STEP_TAGS := image` / a second step) for manual runs.

## 7. Variable mapping (candidate)

Map `@NikolaiGogol/.env*` → `group_vars/nikolaigogol/vars.yml` (values), declarations in role `defaults/main.yml`:

- `system_name` (`NikolaiGogol`), `namespace` (`ds-omega`), `image_base_name` (`nikolaigogol`), `image_tag`, → `image_name`
- `container_name` (`HomeServer__HomeAssistant.NikolaiGogol`), `container_username` (`ds13`)
- `unix_dotfiles` dir, `virt_scripts_bootstrap` path, `home_assistant_image` path
- artifact path + checksum (control-node side)
Host-specific paths live in `group_vars`, never in role logic.

## 8. Idempotency & change semantics

- **Tag content-addressably** (git SHA / artifact checksum), not `:latest`, so "image present?" is meaningful; `docker import` always yields a new image ID, so never re-import unconditionally.
- Load/import gated on remote `docker image inspect` + artifact checksum.
- Compose: render + `docker compose config` validation; `up -d` is idempotent; recreate via handler on template/env change.
- Fail-closed on missing mount sources — role creates them explicitly.

## 9. Open questions for the plan session

1. **Where is the image built?** Workstation `Unix_dotfiles` (`build-NikolaiGogol`) vs control node vs `@terra`. `bootstrap_nix` currently installs Nix on `@terra` — still needed if the image is prebuilt? (Deployment-model change → Architect.)
2. **Artifact format & module:** rootfs `.tar.xz` + `ansible.builtin.command: docker import` (main path) vs `docker save` archive + `community.docker.docker_image_load`. Confirm.
3. **Transfer mechanism** for a large artifact: `copy` vs `synchronize`/`rsync` vs `get_url`; checksum-based idempotency.
4. **Compose source of truth:** commit a template here, or reuse `@NikolaiGogol/docker-compose-system.yml`? Reconcile with `docs/Deploy#NixContainer.puml` (Dockerfile → NixOS Container).
5. **Mount layout on `@terra`** (`/home/<user>/.bookmarks/...`, `/opt/HomeServer__HomeAssistant/haos_ova.qcow2`, storage `/mnt/data`): define `group_vars`, create dirs. Note `HOME_ASSISTANT_IMAGE` binds a HAOS image into the container (Manilov concern).
6. **Image tagging scheme** (git SHA vs `:latest`) and rollback.
7. **TOS Docker compatibility:** `privileged`, `cgroup: host`, `SIGRTMIN+3`, systemd-in-container, USB/Zigbee passthrough — E2E confirms.
8. **`options.nix`** currently points at `misterio77/nix-starter-config` (placeholder); the commented alternatives include the `Unix_dotfiles` `NikolaiGogol` flake. Confirm which config actually produces the deployed image (rootfs import path vs skiffos base).
9. **Infra parity with `@tangerineDream` (aspirational, optional):** `@NikolaiGogol` lacks the launcher/per-system strategies and runtime-home-bridge wiring. Decide whether to port that pattern (could be a separate task, not part of image sync).
10. **Secrets:** age keys / HA config — vault vs pre-staged host files; never commit.

## 10. Testing notes (repo convention: unit / integration / E2E / manual)

- **Unit:** render compose + env from `group_vars`; assert privileged/systemd settings, image tags, path mapping (pattern: `test_docker_step.py`).
- **Integration:** the mock `@terra` (systemd Ubuntu container) can render/`docker compose config`; importing/running the NixOS system container inside it is likely infeasible — render/verify in integration, real import E2E-only.
- **E2E:** `make run TAGS=image` then `TAGS=container` on the real NAS; then connect/verify.
- **Manual:** `Makefile.NixosContainer` (`run`/`dry`/`verify`/`shell`).

## 11. Quick command digest (as-is `@NikolaiGogol`, for reference)

```sh
# build (workstation, Unix_dotfiles), SYSTEM_NAME=NikolaiGogol
make --directory=~/.bookmarks/shared-configs/Unix_dotfiles build-NikolaiGogol
# artifact: result-NikolaiGogol/tarball/nixos-system-x86_64-linux.tar.xz

# import + start (privileged)
sudo docker import ~/.bookmarks/shared-configs/Unix_dotfiles/result-NikolaiGogol/tarball/nixos-system-x86_64-linux.tar.xz ds-omega/nikolai-gogol:latest
sudo docker compose -f ./docker-compose-system.yml up --detach
sudo docker exec -it --user ds13 "HomeServer__HomeAssistant.NikolaiGogol" /run/current-system/sw/bin/bash
```

## 12. Truthfulness / evidence level

All of the above was read from the files in §2 on 2026-09-27; no remote runs were
performed. Container requirements and names are quoted from the `@NikolaiGogol`
compose/env files. The role decomposition and variable mapping are proposals,
not validated designs. `@tangerineDream` is explicitly out of the deployment path.
