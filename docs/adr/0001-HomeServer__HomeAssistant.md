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
| `bootstrap_base` | minimal base prerequisites; optional Ubuntu apt-mirror repoint (ADR 0005) |
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

### 8. TOS 6 platform specifics

The TOS 6 platform behaviours this bootstrap depends on are recorded as standalone
ADRs and referenced here rather than restated:

- [ADR 0003 — TOS 6 privilege model](./0003-Tos6PrivilegeModel.md) — the SSH
  account is already uid 0; never assume `become_user: root`.
- [ADR 0004 — OS detection on TOS 6](./0004-Tos6OsDetection.md) — gate package
  management on `pkg_mgr`, not `os_family`/`distribution`.
- [ADR 0005 — apt mirror repoint](./0005-AptMirrorRepoint.md) — default Ubuntu
  mirrors are not assumed reachable; opt-in, Ubuntu-scoped mirror.

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
  `pkg_mgr`, never on `os_family == 'Debian'` (see ADR 0004). Docker's install
  path on the NAS still remains to be confirmed on the first live run. `become`
  behaviour is likewise confirmed — see ADR 0003 (the SSH account is already
  uid 0; escalate only to it, never to TOS's uid-9999 `root`).
- The Ubuntu-`jammy` Docker fallback assumes TOS 6 keeps its Ubuntu-22.04
  compatibility; `manual` mode is the escape hatch. This is a repository-suite
  choice, not OS detection — the install gate is `pkg_mgr`-based (ADR 0004).
- A blocked default Ubuntu mirror is handled by an opt-in,
  Ubuntu-hostname-scoped apt-source rewrite (ADR 0005), backed up per file.
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
- [`0003-Tos6PrivilegeModel.md`](./0003-Tos6PrivilegeModel.md) — TOS 6 privilege model (refines §8)
- [`0004-Tos6OsDetection.md`](./0004-Tos6OsDetection.md) — TOS 6 OS detection (refines §8)
- [`0005-AptMirrorRepoint.md`](./0005-AptMirrorRepoint.md) — apt mirror repoint (refines §8)
- [`../Deploy#NixContainer.puml`](../Deploy#NixContainer.puml) — system diagram
- [`../HomeServer__HomeAssistant_plan.md`](../HomeServer__HomeAssistant_plan.md)
- `danielrolls/nix-install` — Ansible role installing multi-user Nix
