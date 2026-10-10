# HomeServer / Home Assistant — rollout plan

Ansible-side implementation plan for turning this repository into the bootstrap
for the `@terra` / `@NikolaiGogol` / `@Manilov` home-server stack.

Companion documents:

- system relationships: [`Deploy#NixContainer.puml`](./Deploy#NixContainer.puml)
- Ansible architecture decisions:
  [`adr/0001-HomeServer__HomeAssistant.md`](./adr/0001-HomeServer__HomeAssistant.md)
- Cross-repo image-tag contract:
  [`adr/0002-ContentAddressableImageTag.md`](./adr/0002-ContentAddressableImageTag.md)
- TOS 6 platform decisions (split out of ADR 0001 §8):
  [`adr/0003-Tos6PrivilegeModel.md`](./adr/0003-Tos6PrivilegeModel.md),
  [`adr/0004-Tos6OsDetection.md`](./adr/0004-Tos6OsDetection.md),
  [`adr/0005-AptMirrorRepoint.md`](./adr/0005-AptMirrorRepoint.md)

## 1. Inputs & pinned revisions

| Input | Value |
|---|---|
| Target repo | `PersonalLentServers%Russian_dotfiles.bootstrap` |
| Layer-0 host | `@terra` — TerraMaster NAS, TOS 6 |
| Nix installer role | `danielrolls.nix` (`danielrolls/nix-install`) |
| Pinned commit | `7bef4db07967e433ca9bcf7c7de84eb87814583a` (Release with Nix 2.34.7) |
| Collections | `community.docker`, `ansible.posix` (`synchronize`/rsync) |
| Tooling gap | `ansible` is installed on the control node via `make install`; TOS 6 provides `systemd` and an Ubuntu-22.04-compatible rootfs |

## 2. Goal & target architecture

Three layered, independently idempotent units:

| Layer | Host | Managed by |
|---|---|---|
| 0 | `@terra` (TOS 6) | this repo: backup → SSH access → base → Nix → Docker |
| 1 | `@NikolaiGogol` (NixOS system container) | this repo: `deploy-nikolaigogol.yml` — image sync + compose |
| 2 | `@Manilov` (HomeAssistant OS VM) | roadmap: libvirt VM; config partly via Nix, partly volumes from `@terra` |

`@terra` is the only default SSH target. `@NikolaiGogol` and `@Manilov` are
provisioned on top of it; their inventory groups allow a direct SSH override for
debugging.

## 3. Assumptions

1. TOS 6 SSH is enabled manually and uses the superuser account `terra`.
2. **TOS 6 OS detection (see [ADR 0004](./adr/0004-Tos6OsDetection.md)) — confirmed on the live device (revision `f1d3d1a` +
   build fix).** A verbose `gather_facts` run
   (`logs/20261006T212942-access_ssh.log`) reports `ansible_distribution:
   OtherLinux`, `ansible_distribution_release: NA`,
   `ansible_distribution_version: NA`, `ansible_distribution_major_version: NA`,
   `ansible_os_family: OtherLinux`, and `ansible_pkg_mgr: apt`. TOS 6 is
   Ubuntu-22.04-compatible but does **not** identify as Debian/Ubuntu. The
   `bootstrap_base` var lookup therefore selects `vars/apt-family.yml` through
   the `pkg_mgr`-keyed candidate
   (`{{ ansible_facts['pkg_mgr'] }}-family.yml`), ahead of the `os_family`
   candidate; `default.yml` remains the last-resort fallback.
3. The NAS admin password is new and stored only in `group_vars/terra/vault`.
4. **TOS 6 privilege model (see [ADR 0003](./adr/0003-Tos6PrivilegeModel.md)) — confirmed on the live device (revision
   `f1d3d1a` + build fix).** The first/admin account `terra` (the SSH user,
   `ansible_user: terra`) is **uid 0 and root-equivalent**; the separate `root`
   account is **uid 9999 and unprivileged** (empty capability set). Ansible's
   default `become_user: root` therefore runs `sudo -u root` and *drops*
   privileges (uid 0 → 9999), breaking apt (cannot create
   `/var/lib/apt/lists/partial`) and tar (root-only `/var/spool/cron/crontabs`
   unreadable). Therefore `ansible_become` **MUST** be `false`, or any forced
   escalation (`ansible_become_user`) **MUST** target the uid-0 account — never
   `root`. `group_vars/terra/vars.yml` pins `ansible_become: false` and
   `ansible_become_user: "terra"`. **Enforcement:** the read-only preflight
   `tasks/preflight_privilege_model.yml` (asserts
   `ansible_facts['user_uid'] == 0`) is imported from `pre_tasks` with
   `tags: [always]` in `HomeServer__HomeAssistant.yml` and
   `deploy-nikolaigogol.yml`; privileged Layer-1 roles additionally set
   `become_user: "{{ ansible_become_user | default('root') }}"` explicitly.
   Evidence: `logs/20261006T212942-access_ssh.log` (`ansible_user_uid=9999`,
   `SUDO_UID=0`, `SUDO_USER=terra`); corroborated by TerraMaster community
   documentation.
5. **Package-management convention (see [ADR 0004](./adr/0004-Tos6OsDetection.md)) — confirmed on the live device.**
   Package-management decisions **must** key on
   `ansible_facts['pkg_mgr'] == 'apt'` (`!=` for the non-apt path), never on
   `os_family == 'Debian'` or a `distribution*` fact: TOS 6 reports
   `os_family: OtherLinux` while apt is present, so a Debian/`os_family` gate
   silently skips and leaves prerequisites missing. This is the same class of
   issue as the privilege-model fact in assumption 4. It is applied in
   `bootstrap_base` (`dependencies.yml` + the `variables.yml` lookup),
   `access_sftp`, `nixos_image_sync`, and `bootstrap_docker`, and guarded
   repo-wide by `test_roles_gate_package_management_on_pkg_mgr_not_os_family`.
   Docker CE's `jammy` apt-suite selection is unaffected — that is a repository
   choice, not an OS-detection gate.
6. **Default Ubuntu mirrors are not assumed reachable (see [ADR 0005](./adr/0005-AptMirrorRepoint.md)) — confirmed on the live
   device (base revision `523dfdb`, before the build fix).** The NAS network
   blocks `archive.ubuntu.com` / `security.ubuntu.com`, so `make run TAGS=base`
   hangs at "Install base packages (apt)": the `apt` module shells out to
   `apt-get update` / `apt-get -y install` and sits on connect
   (`logs/20261009T233042-base.log` ends at that task; user-confirmed).
   `bootstrap_base` therefore runs an optional `tasks/apt_mirror.yml` **first**
   (imported before `variables.yml`/`dependencies.yml`). When
   `bootstrap_base_apt_mirror_enabled` is true it asserts a suite + candidates,
   probes each candidate at `<base>/dists/<suite>/Release` via
   `ansible.builtin.uri` (HTTP 200, `validate_certs: false` because
   `ca-certificates` may not be installed yet — reachability only), selects the
   first reachable candidate, fails with guidance if none are, and rewrites
   **only Ubuntu hostnames**
   (`https?://(archive|security|ports)\.ubuntu\.com/ubuntu`) in `/etc/apt`
   source files with `backup: true`. Non-Ubuntu sources (TOS's own repo, Docker)
   are left untouched. It is **off by default**; `@terra` enables it
   (`bootstrap_base_apt_mirror_suite: "jammy"`; candidates
   `ru.archive.ubuntu.com`, `mirror.yandex.ru`, `mirror.truenetwork.ru`,
   `ubuntu.mipt.ru`). Tests: `tests/unit/test_base_step.py`.

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

### Phase 5 — `@NikolaiGogol` system container — **implemented**
- `deploy-nikolaigogol.yml` (targets `terra`, pulls in `group_vars/nikolaigogol`
  via `vars_files`) implements the full path from the workstation build to a
  running privileged systemd container:
  - `image` tag — `nixos_image_artifact` (locate + sha256 + 12-hex content tag
    derived via the shared command `conv-plat-prov.content-tag` on the control
    node; see ADR 0002), `nixos_image_sync` (rsync `--checksum` to
    `/var/tmp/nixos-images/<sha256>.tar.xz`), `nixos_image_load`
    (`docker import`, gated on `docker image inspect`).
  - `container` tag — `nixos_container` renders `docker-compose-system.yml` +
    `.env` from `group_vars`, ensures the mount sources (directory mounts are
    created, file mounts fail-closed) and runs `community.docker.docker_compose_v2`;
    a handler recreates the container on config change.
  - `edge_sync` tag — optional, off-by-default helper (`nixos_edge_sync`).
- `verify-nikolaigogol.yml` checks the image, the running container and
  `nixos-version` inside it.
- **Tests:** unit — `tests/unit/test_nixos_image_step.py` (tag derivation incl.
  shared-command ↔ fixture parity, no moving tags, compose/env render
  invariants, sync/load defaults);
  structure — `test_repo_structure.py` now validates the Layer-1 playbook;
  integration — `tests/integration/playbook.yml` runs `TAGS=image` and
  `TAGS=container` against the mock (import/compose skipped without a daemon);
  E2E — `make -f Makefile.NixosImage run` then `Makefile.NixosContainer run`,
  `verify`; manual — `Makefile.NixosImage`, `Makefile.NixosContainer`,
  `Makefile.NixosEdgeSync`.
- Open risk: the mount roots in `group_vars/nikolaigogol/vars.yml` are
  placeholders until the real TOS volume layout is confirmed; direct SSH to the
  container (port 2223) needs the `Unix_dotfiles` sshd wiring.

### Phase 6 — Roadmap
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
- Playbook: `deploy-nikolaigogol.yml` (Layer 1, targets `terra`), tagged
  `image`, `container`, `edge_sync`.
- Verification: `verify-terra.yml` (Layer 0), `verify-nikolaigogol.yml`
  (Layer 1).
- Role contracts: each role declares its variables in `defaults/main.yml`;
  `group_vars/<host>/vars.yml` supplies values; secrets use the `vault_*`
  indirection.

## 6. Verification

Four layers, cheapest first:

| Layer | Command | Checks |
|---|---|---|
| Unit | `make unit` | repo structure, role var namespacing, pinned deps, docker apt-line logic, apt-mirror probe/rewrite logic |
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
| apt sources repointed to a custom mirror | restore the timestamped `backup` copy next to each edited `/etc/apt` source file (or clear `bootstrap_base_apt_mirror_enabled`) |

## 8. Completion evidence

- `rg -i vless` returns nothing.
- `make check` clean.
- `--tags nix` and `--tags docker` runs succeed and print versions.
- Follow-up run reports no changes.
- `README.md`, this plan and the ADR describe the current state.

## 9. Unresolved / to confirm on first live run

1. ~~`ansible_distribution` / `os_family` reported by TOS 6.~~ **Resolved (see §3,
   assumption 2): `ansible_distribution`/`ansible_os_family` = `OtherLinux`
   (release/version `NA`), `ansible_pkg_mgr` = `apt`. Package gates key on
   `pkg_mgr`, never on `os_family == 'Debian'` (assumption 5).**
2. ~~Whether `become`/`sudo` is required for the `terra` account.~~ **Resolved
   (see §3, assumption 4): no escalation is needed — `terra` is already uid 0 — and
   `become_user: root` would drop privileges to uid 9999.**
3. Whether Docker is pre-installed and on which path.
4. Whether Nix sandboxing works on the TOS 6 kernel.
5. `@terra` reachability: the connection host comes from the inventory
   (`terra-local`); confirm it resolves on the control node.
6. **apt still hangs after a reachable mirror is selected.** The TOS
   `apt`/`apt-get` shell wrappers (`/etc/tos/scripts/apt*`, aliased in
   `/root/.bashrc`) can intercept `apt-get` and read stdin; if the install still
   stalls even though `apt_mirror.yml` selected a reachable mirror, feeding `yes`
   to the wrapper would be required. Not implemented — `apt_mirror.yml` only
   handles mirror reachability. (The TOS `apt` confirmation prompt is a separate
   concern: the `apt` module invokes `apt-get`, not `apt`.)

## 10. Testing per step (matrix)

Every major step gets a test substep at each layer that applies. `—` means the
layer does not add signal for that step.

| Step (tag) | Unit | Integration (mock) | E2E (real `@terra`) | Manual makefile |
|---|---|---|---|---|
| backup (`backup`) | structure tests | `make it-run TAGS=backup` | `make run TAGS=backup` | `Makefile.BackupTos` |
| access (`access`) | structure tests | `make it-run TAGS=access` | `make run TAGS=access` | `Makefile.AccessSsh` |
| base (`base`) | `test_base_step.py` | `make it-run TAGS=base` | `make run TAGS=base` | `Makefile.Steps` (via any) |
| nix (`nix`) | — | `make it-run TAGS=nix` | `make run TAGS=nix` | `Makefile.NixBootstrap` |
| docker (`docker`) | `test_docker_step.py` | `make it-run TAGS=docker` | `make run TAGS=docker`, `make test` | `Makefile.DockerDeployment` |
| image (`image`) | `test_nixos_image_step.py` | `make it-run TAGS=image` | `make -f Makefile.NixosImage run` | `Makefile.NixosImage` |
| container (`container`) | `test_nixos_image_step.py` | `make it-run TAGS=container` | `make -f Makefile.NixosContainer run`, `... verify` | `Makefile.NixosContainer` |
| edge_sync (`edge_sync`) | structure tests | — (inert by default) | `... run EXTRA_ARGS='-e nixos_edge_sync_enabled=true'` | `Makefile.NixosEdgeSync` |

Test-layer definitions and usage live in [`../tests/README.md`](../tests/README.md).

When adding a role/step:

1. Add it to `HomeServer__HomeAssistant.yml` with a tag.
2. Add/extend a unit test if it contains logic worth parsing.
3. Add its tag to `tests/integration/playbook.yml`.
4. Create `Makefile.<Step>` (`STEP_TAGS := <tag>` + `include Makefile.Steps`).
5. Record the row in the matrix above.

## 11. `@terra` file transfer — SFTP vs `piped` (decision)

TOS 6's `/etc/ssh/sshd_config` declares
`Subsystem sftp /usr/lib/openssh/sftp-server`, but native sftp cannot be
restored on the device:

- The TerraMaster build of the `openssh-sftp-server` package ships
  `/usr/sbin/sftpd` (a second sshd daemon), **not**
  `/usr/lib/openssh/sftp-server`; `dpkg -S /usr/lib/openssh/sftp-server` finds
  nothing.
- The platform protects the package: `openssh-client`, `openssh-server` and
  `openssh-sftp-server` are listed in `/etc/disallowed_packages.conf`, and the
  `apt`/`apt-get` shell wrappers (`/etc/tos/scripts/apt*`, aliased in
  `/root/.bashrc`) refuse to install them. Independently,
  `/etc/apt/preferences.d/lock_system_packages.pref` pins the same packages with
  `Pin-Priority: -1`, so apt has no candidate to upgrade to.
- Pointing the main sshd at `internal-sftp` (the value TOS's own
  `/etc/ssh/sftpd_config` uses) makes the daemon **segfault** on the first SFTP
  operation (`dmesg`: `sshd[...]: segfault ... in libc.so.6`).

Ansible's `sftp`/`scp` transfer methods reuse the control connection's SSH
channel, so a transfer method cannot be aimed at a different daemon or port; the
only ways to get native sftp would be to move the whole connection to TOS's
`sftpd` (port 9333) or to drop a stock `sftp-server` binary into the referenced
path.

Comparison for this repository's workloads:

| Criterion | `piped` | TOS sftpd (port 9333) | Stock `sftp-server` binary |
|---|---|---|---|
| Works today | ✅ known-good fallback | ❓ unverified; likely the same segfault | ❓ plausible, but mixes an 8.9p1 binary with TOS's 8.8p1 sshd |
| System change | none | enable + persist a non-default TOS service; move Ansible to 9333 | drop one file at `/usr/lib/openssh/sftp-server` |
| Ansible integration | one variable | `ansible_port: 9333` + sftpd must support full exec/PAM auth | transparent (the path is already referenced) |
| Performance | negligible here — module transfers are small; large artifacts use `synchronize`/rsync | good if it works | good if it works |
| TOS compatibility | respects TOS | fights TOS (enables a protected service) | survives until a TOS update overwrites the file |
| Testability | unit + E2E | hard to mock a port-9333 daemon | unit + E2E |
| Rollback | revert the variable | stop the service, revert the port | delete the file |

**Decision: use `piped`.** `group_vars/terra/vars.yml` sets
`ansible_ssh_transfer_method: piped`, and the `access_sftp` role is retained but
guarded off on TOS (`access_sftp_install: false`) so it still documents the
intent and remains available for apt hosts where the binary really is
installable. Native sftp would be revisited only if a real `copy`/`fetch`
throughput need appears; if so, prefer dropping in the stock binary (T3) over
reconfiguring TOS's sshd (T1).
