# StratoFrame deployment practices — `@terra`, `@NikolaiGogol`, `@Manilov`

How the three hosts are deployed, which layer owns which invariant, and how to
choose the right deployment scope without inventing a dependency path. The
diagrams are the executable version of this document; the tables below say
which one to read.

## 1. Deployment surfaces and ownership

| Surface | Owner | Owns | Does not own |
|---|---|---|---|
| Layer 0 bootstrap | this repo (`roles/bootstrap_*`, `HomeServer__HomeAssistant.yml`) | OS packages, Docker, `/nix` + `nix-daemon` units, the per-user XDG profile parent, the `zterra` layout, the TOS 6 privilege preflight | the package set, home-manager modules, image contents |
| Flake + build | `Unix_dotfiles` (external, reference only) | dependency declarations, flake outputs, deploy-rs profiles, the NixOS image and its content tag | TOS-native services, Ansible orchestration |
| Runtime activation | deploy-rs, `home-manager`, `switch-to-configuration`, Docker on `@terra` | switching a profile/generation, starting services, recreating the container | the declaration; never add packages on the host by hand |
| Layer 1 deploy | this repo (`deploy-nikolaigogol.yml`) | image sync/import, compose render, container lifecycle, the `_scripts` debug surface | the Nix package set and the image contents |

Layer 0 only makes a host *able to receive* Nix work. It does not decide what
is installed: every dependency starts as a declaration in `Unix_dotfiles`.

## 2. The `DEPLOY_HOST` rule

| Value | Meaning | Use for |
|---|---|---|
| `terra-local` | the local/debug network, concrete host | fast iteration against the local NAS |
| `terra` | the production/authoritative target (inventory group/alias) | accepted, promoted changes |

`hosts.ini` is the **source of truth**. Read the current value there instead of
hardcoding either name; the inventory may change the mapping while the meaning
above stays fixed.

The `@NikolaiGogol` home-manager and system flows target the NixOS host
directly (`ds13@NikolaiGogol` and `NikolaiGogol`), so they do not use
`DEPLOY_HOST`. The container redeploy play targets `@terra` (`hosts: terra`),
because the Docker host is the deployment surface; see the TODO on the
container diagram.

## 3. The three `@NikolaiGogol` scopes

| Scope | What changes | Target | Entry point | Diagram |
|---|---|---|---|---|
| Home-manager profile | user packages and dotfiles; only the HM generation switches | `ds13@NikolaiGogol` | deploy-rs `deploy .#homeConfigurations.ds13@NikolaiGogol` | [`Deploy_nikolaigogol__AddDependencyHomeManager.puml`](./_diagrams/Deploy_nikolaigogol__AddDependencyHomeManager.puml) |
| Whole NixOS system | the system closure, systemd units, system packages | `NikolaiGogol` | deploy-rs `deploy .#nixosConfigurations.NikolaiGogol` | [`Deploy_nikolaigogol__AddDependencySystem.puml`](./_diagrams/Deploy_nikolaigogol__AddDependencySystem.puml) |
| Whole container | the image/rootfs, including both layers above | `@terra` (Docker host) | `make build-NikolaiGogol` in `Unix_dotfiles`, then `TAGS=image,container` | [`Deploy_nikolaigogol__AddDependencyContainer.puml`](./_diagrams/Deploy_nikolaigogol__AddDependencyContainer.puml) |

On `@terra` itself there is no NixOS system layer: only the
home-manager-compatible user scope exists — [`Deploy_terra__AddDependency.puml`](./_diagrams/Deploy_terra__AddDependency.puml).

## 4. Diagrams and the edge-iteration scenarios

The `EdgeIteration_scripts__*` diagrams describe the fast edge loop; the
deployment diagrams describe the authoritative path that loop promotes into.
They are complementary, not alternatives.

| Edge scenario | Diagram | Relation to deployment |
|---|---|---|
| S0 full authoritative deploy | [`S0FullAuthoritativeDeploy`](./_diagrams/EdgeIteration_scripts__S0FullAuthoritativeDeploy.puml) | same surface as the container scope |
| S1 scripts-only (Phase 0) | [`S1ScriptsOnlyDeployPhase0`](./_diagrams/EdgeIteration_scripts__S1ScriptsOnlyDeployPhase0.puml) | debug surface, not a dependency deploy |
| S2 ad-hoc debug edit | [`S2AdHocDebugEditOnTerra`](./_diagrams/EdgeIteration_scripts__S2AdHocDebugEditOnTerra.puml) | local overlay before promotion |
| S3 edge config iteration | [`S3EdgeConfigIteration`](./_diagrams/EdgeIteration_scripts__S3EdgeConfigIteration.puml) | in-container iteration |
| S4 promotion of an edge fix | [`S4PromotionOfAnEdgeFix`](./_diagrams/EdgeIteration_scripts__S4PromotionOfAnEdgeFix.puml) | commit + pin, then redeploy |
| S5 dependency ref pinning | [`S5DependencyRefPinning`](./_diagrams/EdgeIteration_scripts__S5DependencyRefPinning.puml) | the declare/pin step before any dependency deploy |
| S6 `@Manilov` VM lifecycle | [`S6ManilovVmLifecycle`](./_diagrams/EdgeIteration_scripts__S6ManilovVmLifecycle.puml) | not Nix-managed |
| S7 post-deploy remote check | [`S7PostDeployRemoteCheck`](./_diagrams/EdgeIteration_scripts__S7PostDeployRemoteCheck.puml) | the verify phase in every deployment diagram |
| S8 dirty-target conflict | [`S8DirtyTargetConflict`](./_diagrams/EdgeIteration_scripts__S8DirtyTargetConflict.puml) | fail before overwriting; explicit force only |
| S9 reverse flow | [`S9ReverseFlow`](./_diagrams/EdgeIteration_scripts__S9ReverseFlow.puml) | pull edge edits back into the source repo |

For system relationships rather than a sequence, read
[`Deploy#NixContainer.puml`](./Deploy#NixContainer.puml). It shows where the
bootstrap, deploy-rs, Docker and the container sit relative to each other.

## 5. Dependency compatibility matrix

| Host | OS / layer | Allowed Nix dependency | Notes |
|---|---|---|---|
| `@terra` | TOS 6, no NixOS system layer | home-manager-compatible **user** packages only | system services stay TOS-native or in Docker/the inner NixOS container |
| `@NikolaiGogol` | NixOS system container | HM profile **and** system closure **and** container image | choose the scope first (§3) |
| `@Manilov` | HomeAssistant OS VM | none | not Nix-managed; only its image is staged |

Adding a system package on `@terra` is not an option: it either belongs in
`@NikolaiGogol` (NixOS) or is a TOS-native/Docker concern.

## 6. Edge debugging: local overlay, promotion, rollback

- **Local vs authoritative.** `terra-local` is the debug network; `terra` is
  the accepted target. Use the debug value to iterate, then promote and deploy
  with the production value.
- **Promotion path.** An edge fix is a source commit in `Unix_dotfiles`, not a
  copy-out from the host. Pin the ref, then run the authoritative deploy for the
  matching scope.
- **Rollback by scope.** Home-manager and system scopes roll back to the
  previous generation; the container scope rolls back by keeping the previous
  content tag and re-running `TAGS=container`. Bind-mounted data is not part of
  any of these swaps.
- **Debug surfaces.** `_scripts` under
  `/zterra/local-/Projects/@NikolaiGogol/_scripts` and the direct container
  SSH entry on port `2223` are debugging aids, not the deployment path.

## 7. Related documents

- [`rfc/RFC-0001-edge-iteration-workflow.md`](./rfc/RFC-0001-edge-iteration-workflow.md) — the edge loop and promotion contract.
- [`rfc/RFC-0001-edge-iteration-scenarios.md`](./rfc/RFC-0001-edge-iteration-scenarios.md) — authoritative scenario catalogue behind S0–S9.
- [`HomeServer__StratoFrame__ConvPlatProv__NikolaiGogolDeployment_plan.md`](./HomeServer__StratoFrame__ConvPlatProv__NikolaiGogolDeployment_plan.md) — image sync, container deploy and rollback.
- [`NikolaiGogol__DependencyLayers_plan.md`](./NikolaiGogol__DependencyLayers_plan.md) — dependency refs, dirty-target protection and rollback.
- [`adr/0001-HomeServer__HomeAssistant.md`](./adr/0001-HomeServer__HomeAssistant.md) — layered Ansible architecture.
- [`adr/0002-ContentAddressableImageTag.md`](./adr/0002-ContentAddressableImageTag.md) — `sha12` image identity.
- [`adr/0003-Tos6PrivilegeModel.md`](./adr/0003-Tos6PrivilegeModel.md) — TOS 6 uid-0 SSH account.
- [`adr/0004-Tos6OsDetection.md`](./adr/0004-Tos6OsDetection.md) — gate on `pkg_mgr`, not `os_family`.
- [`adr/0005-AptMirrorRepoint.md`](./adr/0005-AptMirrorRepoint.md) — apt mirror handling.
- [`_diagrams/README.md`](./_diagrams/README.md) — diagram index and render command.
