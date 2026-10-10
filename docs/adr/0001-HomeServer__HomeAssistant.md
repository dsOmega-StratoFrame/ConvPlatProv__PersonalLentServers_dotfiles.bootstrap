# ADR 0001 — HomeServer / Home Assistant Ansible bootstrap architecture

- **Status:** Accepted for Layers 0–1 (`@terra`, `@NikolaiGogol`); Proposed for Layer 2 (`@Manilov`)
- **Tag identity contract:** [`0002-ContentAddressableImageTag.md`](./0002-ContentAddressableImageTag.md) — cross-repo; refines §6 below.
- **Context diagram:** [`../Deploy#NixContainer.puml`](../Deploy#NixContainer.puml)
- **Rollout plan:** [`../HomeServer__HomeAssistant_plan.md`](../HomeServer__HomeAssistant_plan.md)
- **Scope:** the Ansible side only. Physical/logical relationships between
  `@terra`, `@NikolaiGogol` and `@Manilov` are depicted in the PlantUML diagram.

## Context

The home server is a TerraMaster NAS (`@terra`) running **TOS 6** — an
Ubuntu-22.04-compatible, systemd-based rootfs. On top of it we want:

- `@NikolaiGogol` — a NixOS system container that acts as a reusable Nix "SDK";
- `@Manilov` — a HomeAssistant OS VM, configured partly through Nix and partly
  through configuration volumes hoisted from `@terra`.

The repository started as a copy of a VLESS-on-VPS bootstrap. Layers 0 and 1 are
implemented: Nix + Docker on `@terra`, and the `@NikolaiGogol` NixOS system
container layered on top of it.

## Decision drivers

- The NAS is a long-lived device with existing data — nothing may change before
  a backup exists.
- Each layer must be independently re-runnable (idempotent) and independently
  debuggable.
- The device is partly UI-managed (TOS), so the Ansible scope must stop where
  the UI owns the resource.
- The repository must remain a normal Ansible project: one control node, a
  small set of roles, clear per-host variables, secrets in a vault.

## Decision

### 1. Layered, idempotent provisioning

Every layer is a separate, re-runnable unit. The default path orchestrates each
layer from the one below (`@terra` provisions `@NikolaiGogol`, which hosts
`@Manilov`), while the inventory keeps a group per layer so a direct SSH entry
can be added for debugging. Idempotency at every layer is the contract that
makes mixed direct/layered access safe.

### 2. One playbook per layer

- `HomeServer__HomeAssistant.yml` — Layer 0, targeted at `terra`.
- `deploy-nikolaigogol.yml` — Layer 1, targeted at `terra`. Because a
  `terra`-targeted play does not auto-load `group_vars/nikolaigogol`, the play
  pulls that file in explicitly with `vars_files` (which also means it must never
  define `ansible_*` connection variables). Tags: `image`, `container`,
  `edge_sync`.
- `deploy-manilov.yml`, `configure-services.yml` — roadmap layers.

Stages inside a play are selected with tags (`backup`, `access`, `base`, `nix`,
`docker`), so operators can re-run a single concern.

### 3. Backup is the first role, always

`backup_tos` archives the TOS system configuration and fetches it to the control
node before any other role runs. It is deliberately a *configuration* backup,
not a block-level image; TerraMaster's own config export is the complementary
mechanism. This encodes "no change without a restore point" as structure rather
than convention.

### 4. Feature-scoped roles

The deployment decomposes into small roles, each a single concern:

| Role | Responsibility |
|---|---|
| `backup_tos` | snapshot TOS config |
| `access_ssh` | establish key-based SSH (generate/upload the deployment keypair) |
| `bootstrap_base` | minimal base prerequisites; optional Ubuntu apt-mirror repoint (Decision 8b) |
| `bootstrap_nix` | Nix (multi-user) via the pinned galaxy role |
| `bootstrap_docker` | detect/ensure Docker |
| `nixos_image_artifact` | locate + checksum the image artifact (control node) |
| `nixos_image_sync` | rsync the artifact to `@terra` (checksum-based) |
| `nixos_image_load` | `docker import`, gated on `docker image inspect` |
| `nixos_container` | render compose/env, ensure mounts, compose up |
| `nixos_edge_sync` | optional fast-iteration helper (off by default) |

New capability becomes a new role rather than a larger existing one.

### 5. Declarations vs values vs secrets

- Role `defaults/main.yml` declares the adjustable interface with safe defaults.
- `group_vars/<host>/vars.yml` supplies the deployment values.
- Secrets live in `group_vars/<host>/vault` behind a `vault_*` variable.
  `backups/`, the vault password file and private keys are git-ignored.

### 6. Dependencies are pinned

The Nix installer is pinned to a commit in `requirements.yml`; collection
dependencies are declared there too (`community.docker`, `ansible.posix`).
Reproducibility beats "latest". The deployed container image is likewise
content-addressed: its tag is the artifact sha256 prefix, never a moving tag.
The cross-repo contract for deriving that tag — one shared command
(`conv-plat-prov.content-tag`), control-node execution, and the
`:latest`-alias-only rule — is fixed in [ADR 0002](./0002-ContentAddressableImageTag.md).

### 7. Detect before installing (Docker), wrap the installer (Nix)

- Docker ships with TOS 6 via the App Center. The role detects it and only falls
  back to installing Docker CE from the Ubuntu `jammy` repo when it is missing;
  `manual` mode is available to fail with App Center guidance instead.
- Nix is installed through the maintained `danielrolls.nix` role (multi-user,
  systemd) rather than a bespoke script; this repo adds only the
  HomeServer-specific `nix.conf` settings and verification.

### 8. TOS 6 privilege model — the SSH account is already uid 0

On TOS 6 the first/admin account (`terra`, the SSH user / `ansible_user`) is
**uid 0 and root-equivalent**, while the separate `root` account is **uid 9999
and unprivileged** with an empty capability set. Confirmed on the live device via
the verbose run log: after Ansible's `sudo -H -S ... -u root ... BECOME-SUCCESS`,
the facts report `ansible_user_uid=9999`,
`ansible_system_capabilities=[""]`, `SUDO_UID=0`, `SUDO_USER=terra`.

Consequence: Ansible's default `become_user: root` runs `sudo -u root` and
*drops* privileges (uid 0 → 9999), surfacing as confusing failures — apt cannot
create `/var/lib/apt/lists/partial`, tar cannot read the root-only cron spool.

Decision: **never assume `become_user: root` on TOS 6.** `group_vars/terra/vars.yml`
pins `ansible_become: false` and `ansible_become_user: "terra"`; privileged
Layer-1 tasks (nixos_image_load, nixos_container + handler, nixos_edge_sync,
verify-nikolaigogol) set
`become_user: "{{ ansible_become_user | default('root') }}"` explicitly, so any
forced escalation targets the uid-0 account and not TOS's unprivileged `root`.

Enforcement: the shared read-only preflight
`tasks/preflight_privilege_model.yml` asserts `ansible_facts['user_uid'] == 0`
and is imported from `pre_tasks` with `tags: [always]` in both
`HomeServer__HomeAssistant.yml` and `deploy-nikolaigogol.yml`. It fails fast with
guidance rather than surfacing later as apt/tar errors.

### 8a. OS detection on TOS 6 — gate on `pkg_mgr`, not `os_family`

Confirmed on the live device (verbose `gather_facts`,
`logs/20261006T212942-access_ssh.log`): TOS 6 reports
`ansible_distribution: OtherLinux`, `ansible_distribution_release: NA`,
`ansible_distribution_version: NA`, `ansible_distribution_major_version: NA`,
`ansible_os_family: OtherLinux`, and `ansible_pkg_mgr: apt`. TOS 6 is
Ubuntu-22.04-compatible but does **not** identify as Debian/Ubuntu.

Consequence: any `os_family == 'Debian'` (or `distribution*`-based) gate
silently skips on TOS even though apt is present — the same failure class as
Decision 8.

Decision: package-management decisions **must** key on
`ansible_facts['pkg_mgr'] == 'apt'` (`!=` for the non-apt path), never on
`os_family == 'Debian'`. The `bootstrap_base` var lookup selects
`vars/apt-family.yml` via the `{{ ansible_facts['pkg_mgr'] }}-family.yml`
candidate (renamed from `Debian-family.yml`), with `default.yml` as the
last-resort fallback. This applies to `bootstrap_base`, `access_sftp`,
`nixos_image_sync`, and `bootstrap_docker`, and is guarded repo-wide by
`test_roles_gate_package_management_on_pkg_mgr_not_os_family`.

Docker's `jammy` apt suite is unaffected: it remains the correct Docker CE
suite for TOS 6's Ubuntu-22.04 compatibility; only the install gate is keyed on
`pkg_mgr`.

### 8b. Default Ubuntu mirrors are not assumed reachable — opt-in, Ubuntu-scoped apt mirror

The NAS network blocks the default Ubuntu mirrors (`archive.ubuntu.com` /
`security.ubuntu.com`). With untouched `/etc/apt` sources, `bootstrap_base`'s
package install hangs on connect: the `apt` module shells out to `apt-get update`
/ `apt-get -y install`, which never returns. Confirmed on the live device —
`logs/20261009T233042-base.log` ends at the "Install base packages (apt)" task.

Decision: `bootstrap_base` **must not assume the default Ubuntu mirrors are
reachable.** It runs an **off-by-default** pre-step
(`roles/bootstrap_base/tasks/apt_mirror.yml`, imported before
`variables.yml`/`dependencies.yml`). When `bootstrap_base_apt_mirror_enabled` is
true it:

1. asserts a suite and a non-empty candidate list are configured;
2. probes `<base>/dists/<suite>/Release` for each candidate (`status_code: 200`,
   `validate_certs: false` — a reachability probe only, since `ca-certificates`
   may not be installed yet);
3. selects the first candidate answering 200, and fails with guidance if none do;
4. rewrites **only Ubuntu hostnames**
   (`https?://(archive|security|ports)\.ubuntu\.com/ubuntu`) in the `/etc/apt`
   source files, with `backup: true`.

The suite is explicit (`jammy`) because TOS 6 reports
`distribution_release: NA` (Decision 8a), so it cannot be derived from facts.
Non-Ubuntu sources — TOS's own repo, Docker's — are deliberately out of scope, so
the change cannot disturb the appliance's own package feeds. `@terra` enables the
feature in `group_vars/terra/vars.yml`; every other host keeps the role default
(`false`).

Consequences: the opt-in default keeps the role deterministic for hosts whose
default mirrors work, and the Ubuntu-hostname scope plus per-file backups bound
the blast radius. **Residual risk / fallback:** if `apt-get` still stalls once a
reachable mirror has been selected, the TOS `apt`/`apt-get` wrapper
(`/etc/tos/scripts/apt*`) is intercepting the call and stdin would have to be fed
`yes`; that is not implemented.

## Consequences

**Positive**

- Safe first contact with a data-bearing NAS (backup first).
- Re-runnable stages; partial remediation without full redeploys.
- Clear extension path: each new layer is another playbook + roles.
- Provider-agnostic control node; only SSH to `@terra` is required by default.

**Negative / risks**

- TOS is not a general-purpose distro: OS detection is now confirmed — TOS 6
  reports `ansible_distribution`/`ansible_os_family` = `OtherLinux`
  (release/version `NA`) while `ansible_pkg_mgr` = `apt`; package gates key on
  `pkg_mgr`, never on `os_family == 'Debian'` (see Decision 8a). Docker's install
  path on the NAS still remains to be confirmed on the first live run. `become`
  behaviour is likewise confirmed — see Decision 8 (the SSH account is already
  uid 0; escalate only to it, never to TOS's uid-9999 `root`).
- The Ubuntu-`jammy` Docker fallback assumes TOS 6 keeps its Ubuntu-22.04
  compatibility; `manual` mode is the escape hatch. This is a repository-suite
  choice, not OS detection — the install gate is `pkg_mgr`-based (Decision 8a).
- A blocked default Ubuntu mirror is handled by an opt-in,
  Ubuntu-hostname-scoped apt-source rewrite (Decision 8b), backed up per file.
  Untested residual risk: TOS's own apt wrapper can still intercept `apt-get`
  even against a reachable mirror.
- Nix sandboxing may be restricted by the NAS kernel.
- De-provisioning is conservative: Docker is never removed unless this repo
  installed it.

## Alternatives considered

1. **Keep the VLESS deployment in the same repo.** Rejected: unrelated purpose,
   and it carried host-specific roles (`clone`/`run`/`links`) and a submodule
   that do not apply to a NAS.
2. **`nixos-anywhere` on `@terra`.** Rejected: it targets Linux installs, not a
   TOS appliance.
3. **One monolithic playbook with no layers.** Rejected: breaks idempotent
   partial re-runs and mixes UI-managed and code-managed resources.
4. **Direct SSH to all three layers as the primary model.** Rejected as the
   default; kept only as a debugging override. The target model has `@terra`
   managing the layers beneath it.

## References

- [`0002-ContentAddressableImageTag.md`](./0002-ContentAddressableImageTag.md) — cross-repo content-addressable tag contract
- [`../Deploy#NixContainer.puml`](../Deploy#NixContainer.puml) — system diagram
- [`../HomeServer__HomeAssistant_plan.md`](../HomeServer__HomeAssistant_plan.md)
- `danielrolls/nix-install` — Ansible role installing multi-user Nix
