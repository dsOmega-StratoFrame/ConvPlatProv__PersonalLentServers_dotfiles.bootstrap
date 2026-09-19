# ADR 0001 — HomeServer / Home Assistant Ansible bootstrap architecture

- **Status:** Accepted for Layer 0 (`@terra`); Proposed for Layers 1–2
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

The repository started as a copy of a VLESS-on-VPS bootstrap. Only Layer 0 is
implemented so far: put Nix and Docker on `@terra`.

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
- `deploy-nikolaigogol.yml`, `deploy-manilov.yml`, `configure-services.yml` —
  roadmap layers.

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
| `access_ssh` | establish key-based SSH |
| `bootstrap_base` | minimal prerequisites + control-node keypair |
| `bootstrap_nix` | Nix (multi-user) via the pinned galaxy role |
| `bootstrap_docker` | detect/ensure Docker |

New capability becomes a new role rather than a larger existing one.

### 5. Declarations vs values vs secrets

- Role `defaults/main.yml` declares the adjustable interface with safe defaults.
- `group_vars/<host>/vars.yml` supplies the deployment values.
- Secrets live in `group_vars/<host>/vault` behind a `vault_*` variable.
  `backups/`, the vault password file and private keys are git-ignored.

### 6. Dependencies are pinned

The Nix installer is pinned to a commit in `requirements.yml`; collection
dependencies are declared there too. Reproducibility beats "latest".

### 7. Detect before installing (Docker), wrap the installer (Nix)

- Docker ships with TOS 6 via the App Center. The role detects it and only falls
  back to installing Docker CE from the Ubuntu `jammy` repo when it is missing;
  `manual` mode is available to fail with App Center guidance instead.
- Nix is installed through the maintained `danielrolls.nix` role (multi-user,
  systemd) rather than a bespoke script; this repo adds only the
  HomeServer-specific `nix.conf` settings and verification.

## Consequences

**Positive**

- Safe first contact with a data-bearing NAS (backup first).
- Re-runnable stages; partial remediation without full redeploys.
- Clear extension path: each new layer is another playbook + roles.
- Provider-agnostic control node; only SSH to `@terra` is required by default.

**Negative / risks**

- TOS is not a general-purpose distro: `ansible_distribution`, `become`
  behaviour and Docker's install path must be confirmed on the first live run.
- The Ubuntu-`jammy` Docker fallback assumes TOS 6 keeps its Ubuntu-22.04
  compatibility; `manual` mode is the escape hatch.
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

- [`../Deploy#NixContainer.puml`](../Deploy#NixContainer.puml) — system diagram
- [`../HomeServer__HomeAssistant_plan.md`](../HomeServer__HomeAssistant_plan.md)
- `danielrolls/nix-install` — Ansible role installing multi-user Nix
