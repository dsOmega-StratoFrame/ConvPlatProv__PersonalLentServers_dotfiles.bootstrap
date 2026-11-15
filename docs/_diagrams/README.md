# Deployment and edge-iteration diagrams

Source and rendered diagrams for the deployment path and for the
`@NikolaiGogol` / `_scripts` edge-iteration workflow (RFC-0001). Each scenario
or deployment scope is a **single-diagram `.puml` file** so that
PlantUML renders it to a predictable, scenario-named file instead of an
order-based `_001`, `_002`, … suffix.

All diagram artifacts live here: the `.puml` sources, the pre-rendered `.png`
and `.svg` files. Nothing diagram-related should live directly under `docs/`.

## Scenario → filename

Every name below is the shared basename; the source is `<basename>.puml` and the
renders are `<basename>.png` / `<basename>.svg`.

| Scenario | Diagram | Basename | Pre-rendered |
|---|---|---|---|
| Index | Shared facts and diagram index | `EdgeIteration_scripts__IndexSharedFacts` | yes |
| S0 | Full authoritative deploy | `EdgeIteration_scripts__S0FullAuthoritativeDeploy` | yes |
| S1 | Scripts-only deploy (Phase 0) | `EdgeIteration_scripts__S1ScriptsOnlyDeployPhase0` | yes |
| S2 | Ad-hoc debug/edit on `@terra` | `EdgeIteration_scripts__S2AdHocDebugEditOnTerra` | yes |
| S3 | Edge config iteration in the container | `EdgeIteration_scripts__S3EdgeConfigIteration` | yes |
| S4 | Promotion of an edge fix | `EdgeIteration_scripts__S4PromotionOfAnEdgeFix` | yes |
| S5 | Dependency ref pinning | `EdgeIteration_scripts__S5DependencyRefPinning` | yes |
| S6 | `@Manilov` VM lifecycle | `EdgeIteration_scripts__S6ManilovVmLifecycle` | yes |
| S7 | Post-deploy remote check | `EdgeIteration_scripts__S7PostDeployRemoteCheck` | yes |
| S8 | Dirty-target conflict | `EdgeIteration_scripts__S8DirtyTargetConflict` | yes |
| S9 | Reverse flow (pull on-`@terra` edits back) | `EdgeIteration_scripts__S9ReverseFlow` | **no** |

> **S9 has no pre-rendered image yet.** The `.puml` is present; run the render
> command below to produce `EdgeIteration_scripts__S9ReverseFlow.png` and
> `.svg`.

## Deployment diagrams

The deployment diagrams show the authoritative path: bootstrap → declaration
in `Unix_dotfiles` → deploy-rs / Ansible activation. `DEPLOY_HOST=terra-local`
means the local/debug network; `DEPLOY_HOST=terra` means the
production/authoritative target. `hosts.ini` is the source of truth.

| Scope | Diagram | Basename | Pre-rendered |
|---|---|---|---|
| `@terra` (TOS 6) — HM user dependency | Add a dependency to `@terra` | `Deploy_terra__AddDependency` | yes |
| `@NikolaiGogol` — HM profile | Add a dependency to the HM profile | `Deploy_nikolaigogol__AddDependencyHomeManager` | yes |
| `@NikolaiGogol` — whole system | Add a system dependency | `Deploy_nikolaigogol__AddDependencySystem` | yes |
| `@NikolaiGogol` — whole container | Redeploy the container image | `Deploy_nikolaigogol__AddDependencyContainer` | yes |

## Network topologies

Two approaches are used for `@Manilov`, selected by the host's uplink. The
diagrams use variables only; the real addresses and interface names are decided
during deployment.

| Approach | When to use | Diagram | Basename | Pre-rendered |
|---|---|---|---|---|
| Ethernet bridge | The host has an Ethernet uplink that can be enslaved to a Linux bridge; the VM must be a full L2 peer. | [`NetworkTopology__@terra__@Manilov`](NetworkTopology__@terra__@Manilov.puml) | `NetworkTopology__@terra__@Manilov` | yes |
| Wi-Fi proxyARP | The host has only a Wi-Fi station uplink; Wi-Fi cannot be a bridge port; the VM needs L3 reachability, not full L2. | [`NetworkTopology__@salt__@Manilov`](NetworkTopology__@salt__@Manilov.puml) | `NetworkTopology__@salt__@Manilov` | yes |

The matching documents are
[`docs/NetworkTopology__@terra__@Manilov.md`](../NetworkTopology__@terra__@Manilov.md)
and
[`docs/NetworkTopology__@salt__@Manilov.md`](../NetworkTopology__@salt__@Manilov.md).

## Firewall and forward-path sequences

These diagrams show **ordering** rather than topology: which nftables chain is
evaluated when, and which verdict is final. They exist because the same packet
is subject to two independent traversals — base chains at a hook (ordered by
priority) and rules inside one base chain (ordered by handle) — and conflating
the two is the usual source of a wrong conclusion.

| Path | Diagram | Basename | Pre-rendered |
|---|---|---|---|
| `@Manilov` VM ↔ LAN on `@terra` | Sequence of table/chain jumps: image drop-only tables vs the host `MANILOV_FORWARD` permit, the three failure outcomes, and the OQ5 Docker-order variants | [`Manilov__ForwardJumpSequence`](Manilov__ForwardJumpSequence.puml) | `Manilov__ForwardJumpSequence` | yes |
| `@Manilov` VM ↔ LAN on `@terra` — plain language | **Plain-language companion** to the row above (not a replacement): the same two checkpoints told as two doors and a front desk, with the good and bad orders side by side | [`Manilov__ForwardJumpSequence__ELI5`](Manilov__ForwardJumpSequence__ELI5.puml) | `Manilov__ForwardJumpSequence__ELI5` | yes |

The sequence diagram is the graphical form of the text walk embedded in
[`docs/adr/0006-ManilovNetworkOwnership.md`](../adr/0006-ManilovNetworkOwnership.md)
D4a; §6b carries the three residuals (OQ5, OQ5a, OQ5b) that the diagram
deliberately does not decide.

## Flow ownership (progressive)

Three **ownership** diagrams, one per flow. They are not rule diagrams: they
show which actor controls each surface, where ownership changes, and who may
write, read, or grant at each checkpoint. Every diagram stacks four levels
(L0 intent → L1 logical → L2 segments and hand-offs → L3 checkpoints) so each
level is readable on its own, and all three share one legend — defined once in
[`_shared/ManilovFlowOwnershipCommon.puml`](_shared/ManilovFlowOwnershipCommon.puml)
— where colour identifies the owner.

| Flow | Diagram | Basename | Pre-rendered |
|---|---|---|---|
| F1: `@Manilov` → house router → internet | [`Manilov__FlowOwnership__ManilovToInternet`](Manilov__FlowOwnership__ManilovToInternet.puml) | `Manilov__FlowOwnership__ManilovToInternet` | yes |
| F2: LAN device → `@Manilov` | [`Manilov__FlowOwnership__LanToManilov`](Manilov__FlowOwnership__LanToManilov.puml) | `Manilov__FlowOwnership__LanToManilov` | yes |
| F3: `@Manilov` → another LAN device | [`Manilov__FlowOwnership__ManilovToLan`](Manilov__FlowOwnership__ManilovToLan.puml) | `Manilov__FlowOwnership__ManilovToLan` | yes |

L2 and L3 stay in the rendered diagrams; ADR 0006's
[`Flow ownership (progressive)`](../adr/0006-ManilovNetworkOwnership.md) section
carries the compact L0 + L1 text. The diagrams are companions to
`Manilov__ForwardJumpSequence__ELI5`: the same two checkpoints, stated as
ownership rather than as a packet-filter walk.

## Shared include library

`_shared/DeployCommon.puml` holds the shared skinparams and the reusable
`!procedure` phase macros (bootstrap readiness, declaration, deploy-rs
copy/dry-pass/activate, Ansible image+container deploy, verify, failure/
rollback). It deliberately has **no** `@startuml`/`@enduml`, so it is never a
diagram.

It also lives in a subdirectory so `docs/_diagrams/*.puml` does not match it.
Scenario files include it with a path relative to the including file:

```plantuml
!include _shared/DeployCommon.puml
```

The include is validated transitively whenever a scenario renders; it produces
no `.png`/`.svg` of its own. Scenario files declare their participants and
compose the macros; do not redeclare participants that a macro would add.

## Rendering

From the repository root:

```sh
plantuml -tpng -tsvg docs/_diagrams/*.puml
```

Each rendered file contains exactly one `@startuml`/`@enduml` block, so
PlantUML emits `<basename>.png` and `<basename>.svg` next to the source. Do
**not** merge the scenarios back into one multi-block file: that reintroduces
index-based output names. The `_shared/` include is intentionally exempt from
both rules — no diagram block, no rendered output.

Filename rules: edge scenarios keep the `EdgeIteration_scripts__` prefix and
the `S<id>` scenario prefix; deployment diagrams use
`Deploy_<host>__<PascalCase>`; `@Manilov` datapath and firewall sequences use
`Manilov__<PascalCase>`. No spaces.

## Related

- `docs/rfc/RFC-0001-edge-iteration-workflow.md` — workflow, promotion and
  reverse-flow proposal.
- `docs/rfc/RFC-0001-edge-iteration-scenarios.md` — authoritative scenario
  catalogue and diagram guidance.
- `docs/StratoFrame__DeploymentPractices.md` — deployment surfaces,
  `DEPLOY_HOST`, the three `@NikolaiGogol` scopes and the compatibility matrix.
