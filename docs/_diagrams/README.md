# Edge-iteration diagrams

Source and rendered diagrams for the `@NikolaiGogol` / `_scripts` edge-iteration
workflow (RFC-0001). Each scenario is a **single-diagram `.puml` file** so that
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

## Rendering

From the repository root:

```sh
plantuml -tpng -tsvg docs/_diagrams/*.puml
```

Each file contains exactly one `@startuml`/`@enduml` block, so PlantUML emits
`<basename>.png` and `<basename>.svg` next to the source. Do **not** merge the
scenarios back into one multi-block file: that reintroduces index-based output
names.

Filename rules: keep the `EdgeIteration_scripts__` prefix and the `S<id>`
scenario prefix, PascalCase, no spaces.

## Related

- `docs/rfc/RFC-0001-edge-iteration-workflow.md` — workflow, promotion and
  reverse-flow proposal.
- `docs/rfc/RFC-0001-edge-iteration-scenarios.md` — authoritative scenario
  catalogue and diagram guidance.
