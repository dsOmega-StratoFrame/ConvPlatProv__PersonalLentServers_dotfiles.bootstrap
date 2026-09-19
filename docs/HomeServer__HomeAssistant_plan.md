# HomeServer / Home Assistant — rollout plan

Ansible-side implementation plan for turning this repository into the bootstrap
for the `@terra` / `@NikolaiGogol` / `@Manilov` home-server stack.

Companion documents:

- system relationships: [`Deploy#NixContainer.puml`](./Deploy#NixContainer.puml)
- Ansible architecture decisions:
  [`adr/0001-HomeServer__HomeAssistant.md`](./adr/0001-HomeServer__HomeAssistant.md)

## 1. Inputs & pinned revisions

| Input | Value |
|---|---|
| Target repo | `PersonalLentServers%Russian_dotfiles.bootstrap` |
| Layer-0 host | `@terra` — TerraMaster NAS, TOS 6 |
| Nix installer role | `danielrolls.nix` (`danielrolls/nix-install`) |
| Pinned commit | `7bef4db07967e433ca9bcf7c7de84eb87814583a` (Release with Nix 2.34.7) |
| Collections | `community.docker` |
| Tooling gap | `ansible` is installed on the control node via `make install`; TOS 6 provides `systemd` and an Ubuntu-22.04-compatible rootfs |

## 2. Goal & target architecture

Three layered, independently idempotent units:

| Layer | Host | Managed by |
|---|---|---|
| 0 | `@terra` (TOS 6) | this repo: backup → SSH access → base → Nix → Docker |
| 1 | `@NikolaiGogol` (NixOS system container) | roadmap: deploy NixOS container image + compose |
| 2 | `@Manilov` (HomeAssistant OS VM) | roadmap: libvirt VM; config partly via Nix, partly volumes from `@terra` |

`@terra` is the only default SSH target. `@NikolaiGogol` and `@Manilov` are
provisioned on top of it; their inventory groups allow a direct SSH override for
debugging.

## 3. Assumptions

1. TOS 6 SSH is enabled manually and uses the superuser account `terra`.
2. Ansible's reported `ansible_distribution` on TOS 6 is not yet confirmed; the
   `bootstrap_base` var lookup falls back to `default.yml`.
3. The NAS admin password is new and stored only in `group_vars/terra/vault`.
4. `become`/`sudo` is available on TOS 6; if the superuser account does not need
   it, `ansible_become` can be set to `false` in `group_vars/terra/vars.yml`.

## 4. Phases

### Phase 0 — Cleanup & scaffold — **done in this revision**
- Removed the VLESS playbook, `bootstrap_clone` / `bootstrap_run` /
  `bootstrap_links` / `nixos` roles, `group_vars/MelisStoke`, the stale
  `RealiTLScanner` submodule entry, the ipsubnet demo, and the empty
  `roles/repositories`.
- Renamed `bootstrap_ssh` → `access_ssh` and `bootstrap_prereqs` →
  `bootstrap_base` (Docker moved out).
- **Tests:** `tests/unit/test_repo_structure.py` guards the structure
  (role references, namespaced vars, pinned deps, ignored secrets);
  `make unit`.

### Phase 1 — `@terra` access & facts — **done in this revision**
- Added `group_vars/terra/vars.yml` and the `terra` inventory host.
- `access_ssh` establishes key auth for `terra` and is idempotent.
- **Tests:** integration — `make it-up && make it-run TAGS=access` against the
  mock container; E2E — `make run TAGS=access`; manual —
  `make -f Makefile.AccessSsh run` (`shell-ssh` for a human).

### Phase 2 — Backup first — **done in this revision**
- `backup_tos` archives the TOS system configuration and pulls it to
  `backups/<host>/` before any change.
- **Tests:** integration — `make it-run TAGS=backup` (archive lands in
  `tests/artifacts/`); E2E — `make run TAGS=backup`; manual —
  `make -f Makefile.BackupTos run` and `... inspect`.

### Phase 3 — Bootstrap Nix — **done in this revision**
- `bootstrap_nix` wraps `danielrolls.nix` (pinned), gates on `command -v nix`,
  and applies `experimental-features` / `trusted-users`.
- Open risk: if the TOS 6 kernel cannot sandbox Nix builds, disable the sandbox
  via `bootstrap_nix_extra_config`.
- **Tests:** integration — `make it-run TAGS=nix` (container uses
  `sandbox: false`; heavy, downloads Nix); E2E — `make run TAGS=nix`; manual —
  `make -f Makefile.NixBootstrap run`. No unit tests: the installer itself is
  the pinned upstream role.

### Phase 4 — Bootstrap Docker — **done in this revision**
- `bootstrap_docker` detects the TOS-provided Docker; installs Docker CE from
  the Ubuntu `jammy` repo only when missing; enables the daemon; adds the
  deployment user to the `docker` group; records
  `bootstrap_docker_managed_by_us` for rollback.
- **Tests:** unit — `tests/unit/test_docker_step.py` (detection default, jammy
  suite, package set, rendered apt line); integration —
  `make it-run TAGS=docker` (detection + package logic; starting the daemon is
  E2E-only); E2E — `make run TAGS=docker` and `make test`; manual —
  `make -f Makefile.DockerDeployment run`.

### Phase 5 — Roadmap
- `deploy-nikolaigogol.yml`: import a NixOS system-container image and start it
  with `docker-compose-system.yml` (see
  `ConvPlatProv-HomeServer__HomeAssistant/@NikolaiGogol`).
- `deploy-manilov.yml`: provision the HomeAssistant OS VM (libvirt) and hoist
  configuration volumes from `@terra`.
- `configure-services.yml`: service-level configuration once both layers run.
- **Tests (required per step):** each roadmap play gets the same four layers —
  unit tests for any pure logic, an integration run against the mock container
  (extend `tests/integration/playbook.yml`), an E2E run against the real host,
  and a `Makefile.<Step>` manual-testing file.

## 5. Interfaces

- Playbook: `HomeServer__HomeAssistant.yml` (Layer 0), tagged
  `backup`, `access`, `base`, `nix`, `docker`.
- Verification: `verify-terra.yml`.
- Role contracts: each role declares its variables in `defaults/main.yml`;
  `group_vars/<host>/vars.yml` supplies values; secrets use the `vault_*`
  indirection.

## 6. Verification

Four layers, cheapest first:

| Layer | Command | Checks |
|---|---|---|
| Unit | `make unit` | repo structure, role var namespacing, pinned deps, docker apt-line logic |
| Integration | `make it-up && make it-run [TAGS=…] && make it-down` | the real roles against the mock `@terra` container |
| E2E | `make run [TAGS=…]`, `make test` | the real roles against the real NAS + `verify-terra.yml` |
| Lint | `make check`, `make lint` | playbook syntax, ansible-lint |

- `make test` runs `verify-terra.yml` (`nix --version`, `docker --version`,
  `systemctl is-active docker`).
- Idempotency — a second `make run-terra` and a second `make it-run` must
  report no changes.

## 7. Rollback

| Change | Rollback |
|---|---|
| Repo restructuring | revert the cleanup commits |
| `access_ssh` | remove the uploaded key from the target account |
| Nix | run the installer's uninstall script |
| Docker | remove only if `bootstrap_docker_managed_by_us` is true |

## 8. Completion evidence

- `rg -i vless` returns nothing.
- `make check` clean.
- `--tags nix` and `--tags docker` runs succeed and print versions.
- Follow-up run reports no changes.
- `README.md`, this plan and the ADR describe the current state.

## 9. Unresolved / to confirm on first live run

1. `ansible_distribution` / `os_family` reported by TOS 6.
2. Whether `become`/`sudo` is required for the `terra` account.
3. Whether Docker is pre-installed and on which path.
4. Whether Nix sandboxing works on the TOS 6 kernel.
5. `@terra` reachability (`ansible_host`) and the deployment key path.

## 10. Testing per step (matrix)

Every major step gets a test substep at each layer that applies. `—` means the
layer does not add signal for that step.

| Step (tag) | Unit | Integration (mock) | E2E (real `@terra`) | Manual makefile |
|---|---|---|---|---|
| backup (`backup`) | structure tests | `make it-run TAGS=backup` | `make run TAGS=backup` | `Makefile.BackupTos` |
| access (`access`) | structure tests | `make it-run TAGS=access` | `make run TAGS=access` | `Makefile.AccessSsh` |
| base (`base`) | structure tests | `make it-run TAGS=base` | `make run TAGS=base` | `Makefile.Steps` (via any) |
| nix (`nix`) | — | `make it-run TAGS=nix` | `make run TAGS=nix` | `Makefile.NixBootstrap` |
| docker (`docker`) | `test_docker_step.py` | `make it-run TAGS=docker` | `make run TAGS=docker`, `make test` | `Makefile.DockerDeployment` |

Test-layer definitions and usage live in [`../tests/README.md`](../tests/README.md).

When adding a role/step:

1. Add it to `HomeServer__HomeAssistant.yml` with a tag.
2. Add/extend a unit test if it contains logic worth parsing.
3. Add its tag to `tests/integration/playbook.yml`.
4. Create `Makefile.<Step>` (`STEP_TAGS := <tag>` + `include Makefile.Steps`).
5. Record the row in the matrix above.
