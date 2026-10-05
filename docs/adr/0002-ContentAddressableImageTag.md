# ADR 0002 — Content-addressable image tags derived by one shared command

- **Status:** Accepted (user-approved 2026-09-27) for the Layer-1 cross-repo
  contract. Publication to `ai-shared-Architecture_system` requested; not yet
  published.
- **Relation to ADR 0001:** complements [`0001-HomeServer__HomeAssistant.md`](./0001-HomeServer__HomeAssistant.md)
  (Ansible-side layered model). ADR 0002 neither supersedes nor changes any
  ADR 0001 decision; it fixes the *identity* contract that ADR 0001 §6 refers to
  as "content-addressed … never a moving tag".
- **Enforced by:** `roles/nixos_image_artifact` (this repo) +
  the shared task in `~/.bookmarks/shared-scripts`.
- **Rollout plan:** [`../HomeServer__StratoFrame__ConvPlatProv__NikolaiGogolDeployment_plan.md`](../HomeServer__StratoFrame__ConvPlatProv__NikolaiGogolDeployment_plan.md) §12.
- **Scope:** **cross-repo.** Covers this deploy repository, `~/.bookmarks/shared-scripts`,
  `~/.bookmarks/shared-configs/Unix_dotfiles`, and
  `ConvPlatProv-HomeServer__HomeAssistant/@NikolaiGogol`. This is wider than
  ADR 0001, which is explicitly "the Ansible side only".

## Context

The `@NikolaiGogol` system-container image is content-addressed: its tag is the
first 12 hex characters of the rootfs tarball's `sha256`,
`ds-omega/nikolai-gogol:<sha12>` — never `latest`. Deploy and verify depend on
this: "is this exact image present?" is answerable, and a re-run is a no-op when
nothing changed.

Before this decision the `sha256[:12]` rule lived **only in the Ansible role**.
The build-side repos (`Unix_dotfiles`, `@NikolaiGogol`) had their own separate
notion of image identity, so a locally built/tested tag could disagree with the
tag the remote deploy derived from the same bytes. The follow-up request was:
*"support such tag creation at the NikolaiGogol repo, so local testing matches
remote."* The rule was therefore extracted into **one shared command**:

```
invoke --search-root=~/.bookmarks/shared-scripts conv-plat-prov.content-tag <tarball>
```

`conv_plat_prov.py` gained `compute_content_tag()` (streaming sha256) and an
`@task content_tag` (namespace `conv-plat-prov.content-tag`; the module is
already registered in that repo's `tasks.py` collection). The build-side
Makefiles and the Ansible role all shell out to that command.

## Decision drivers

- Local build/test and remote deploy must agree on the tag **by construction**,
  not by convention.
- No moving tags in the deploy/verify paths.
- No new runtime dependency and no secret/artifact transfer to `@terra` for tag
  derivation.
- Hermetic unit/integration tests (no `invoke`, no real build required).
- One rule, one implementation — a change to the rule is a change in one place.

## Decision

### D1 — One implementation of the tag rule

The content-addressable tag rule `sha256(tarball)[:12]` has a **single
implementation**: `compute_content_tag()` / `conv-plat-prov.content-tag` in
`~/.bookmarks/shared-scripts/conv_plat_prov.py`. Every consumer derives the tag
from it:

| Consumer | How it derives the tag |
|---|---|
| `Unix_dotfiles` | `make image-tag-<machine>` → `$(CONTENT_TAG)` (shared command) |
| `@NikolaiGogol` | `Makefile` computes `IMAGE_TAG`/`IMAGE_NAME` via `$(CONTENT_TAG)` |
| this deploy repo | `roles/nixos_image_artifact` runs the shared command |

No repository may carry a second, independent implementation of the rule.
The role's in-role `checksum[:12]` slice is retained only as the hermetic-test /
degraded fallback (see D2/D3), not as an alternative rule.

### D2 — The role runs the shared command on the control node

`roles/nixos_image_artifact` already runs `delegate_to: localhost` +
`become: false`, so it invokes the shared command **on the control node**;
nothing (neither the command nor the tarball) is sent to `@terra`. This
requires `invoke` on the control node `PATH`, guaranteed by this repo's dev
shell (`flake.nix` adds `invoke`).

- Production sets `nixos_image_artifact_content_tag_required: true`
  (`group_vars/nikolaigogol/vars.yml`).
- The role default is `false`, so tests remain hermetic and fall back to the
  built-in sha256 slice when `invoke`/`shared-scripts` is absent.
- Command variable: `nixos_image_artifact_content_tag_command`
  (`invoke --search-root=~/.bookmarks/shared-scripts conv-plat-prov.content-tag`).

### D3 — The role cross-checks the shared command against the artifact

Before using it, the role asserts the shared command's output equals the
artifact `stat` result's sha256 slice (`nixos_image_artifact_checksum_slice`).
If the two disagree the role fails with a message pointing at
`~/.bookmarks/shared-scripts` / pinned revisions. This is defense in depth: the
deploy can never silently import a tag that does not match the bytes it staged.

### D4 — `:latest` is a local convenience alias only

The `@NikolaiGogol` repo keeps a `:latest` alias (`make import-nixos` imports
the content tag, then `docker tag`s `:latest`). `:latest` is a **local alias
only**: the deploy and verify paths use exclusively the content tag. The repo's
`.env.example` documents `IMAGE_TAG=latest` as a fallback for the case where the
artifact is not built yet — never as the deployed identity.

### D5 — Scope of the implementing change (user approved)

The change that established D1–D4 edits four separate git repositories. The
user explicitly approved editing the two non-deployment repos in addition to
shared-scripts:

1. `~/.bookmarks/shared-scripts/` — canonical rule + task (D1).
2. `~/.bookmarks/shared-configs/Unix_dotfiles/` — `Makefile.ConvPlatProv-docker`
   gains `image-tag-<machine>` and `tarball-<machine>` targets.
3. `.../ConvPlatProv-HomeServer__HomeAssistant/@NikolaiGogol/` — `Makefile`
   derives `IMAGE_TAG` via the shared command, exports it for compose, and adds
   the `:latest` alias; `.env.example` documents the fallback.
4. this deploy repo — role wiring + new defaults + `flake.nix` dev shell + README.

No commits were made in any of the four repositories.

## Cross-repo dependency edges

```text
                         ~/.bookmarks/shared-scripts
                         conv_plat_prov.compute_content_tag()
                         task: conv-plat-prov.content-tag        <-- single source of truth
                                      ^
             +------------------------+------------------------+
             |                        |                        |
   Unix_dotfiles             @NikolaiGogol              deploy repo (this one)
   Makefile.ConvPlatProv-    Makefile (IMAGE_TAG)       roles/nixos_image_artifact
   docker (image-tag-*)      import-nixos (:latest alias)  (delegate_to: localhost)
```

Explicit contract edges (all are *runtime* edges; none transfers the tarball to
a third party):

- **deploy repo → shared-scripts**: `conv-plat-prov.content-tag`, executed on
  the control node; `invoke` supplied by this repo's dev shell. Production
  requires it (`..._content_tag_required: true`).
- **`Unix_dotfiles` → shared-scripts**: `make image-tag-<machine>`.
- **`@NikolaiGogol` → shared-scripts**: `Makefile` `IMAGE_TAG`/`IMAGE_NAME`;
  `make import-nixos` tags the content tag then adds the local `:latest` alias.

The shared command signature is a cross-repo interface:
`content-tag <tarball> [--length N]`, default `N=12`; exits 1 with a clean
message on a missing artifact or an invalid length.

## Findings from the build (evidence-backed)

- **F1 — `invoke` runs on its own interpreter.** A plain
  `python3 shared-scripts/<module>.py` cannot `import invoke`; the entrypoint is
  `invoke --search-root=<dir> <collection>.<task>`. This is why `invoke` had to
  be added to this repo's `flake.nix` dev shell.
- **F2 — ansible-core 2.20 rejects a nested filter+slice inside
  `assert.that`** ("Conditional expressions must be strings"). The slice is
  precomputed into a fact (`nixos_image_artifact_checksum_slice`) and compared
  with a simple expression.
- **F3 — `ansible.builtin.stat` does not follow a symlink that is the FINAL
  path component**, so a symlinked artifact reports no `checksum`. The real
  artifact path (`result-NikolaiGogol/tarball/...`) is a regular file, so this
  is a **test-fixture caveat, not a role bug**.
- **F4 — the shared command streams the sha256** in 1 MiB chunks, so it works on
  large rootfs tarballs without loading them into memory.

## Compatibility guarantees

- For a given tarball's bytes, `conv-plat-prov.content-tag` returns exactly
  `sha256(tarball)[:12]` (or `[:N]` with an explicit `--length N`).
- The tag used for `docker import`, the compose image reference, and verify is
  the same content tag for the same bytes.
- The command emits the tag with no trailing newline (`print(tag, end="")`);
  consumers `.strip()`/capture it accordingly.

## Prohibited changes

- Adding a second implementation of the tag rule in any repository.
- Using a moving tag (`latest` or otherwise) in the deploy/verify paths, or in
  `group_vars/nikolaigogol/vars.yml`.
- Transferring the shared command, `invoke`, or `shared-scripts` to `@terra`.
- Replacing the role's cross-check (D3) with a non-failing "prefer shared output"
  behaviour in production.

## Validation gates

- `tests/unit/test_nixos_image_step.py`:
  `test_artifact_content_tag_command_uses_shared_task`,
  `test_artifact_content_tag_not_required_by_default`,
  `test_group_vars_require_content_tag_command`,
  `test_fixture_tag_is_first_12_hex_of_sha256`,
  `test_shared_content_tag_command_matches_fixture`.
- Evidence at acceptance: `make unit` → **57 passed**; `make check` → 4 playbooks
  syntax-clean; `make lint` → 0 failures / 0 warnings (production profile).
- Localhost role run against the fixture → `ok=8 failed=0`, tag
  `ecfcf1d2a1e3`, image `ds-omega/nikolai-gogol:ecfcf1d2a1e3`; the
  required-but-missing-command guard fired as intended.
- **Outstanding (needs Docker + the real NAS):** integration/E2E. The unit and
  localhost evidence above are the currently available gates.

## Rollback

| Change | Rollback |
|---|---|
| Shared command unavailable/wrong | set `nixos_image_artifact_content_tag_required: false` (role falls back to the in-role sha256 slice) and restore `shared-scripts`; build-side repos lose parity until restored |
| Role wiring | revert the role/defaults to the pre-D1 in-role slice derivation |
| `:latest` alias | harmless to leave; `docker rmi ds-omega/nikolai-gogol:latest` on the local build host (never referenced by deploy/verify) |

A rollback that falls back to the in-role slice re-introduces exactly the drift
risk D1 removes; it is a break-glass measure, not a steady state.

## Alternatives considered

1. **Keep the rule in the Ansible role only, and copy it into each Makefile.**
   Rejected: three implementations that can drift — the problem being solved.
2. **Put the rule in a shared shell snippet / Makefile include rather than a
   Python `invoke` task.** Rejected: `shared-scripts` already exposes Python
   tasks as the shared-command mechanism, and a streaming sha256 is trivial
   there; a shell one-liner would re-open the interpreter/portability issues
   (F1).
3. **Have the role read the tag from an artifact-side manifest the build
   produces.** Rejected: adds a second source of truth (the manifest) that can
   disagree with the bytes; the bytes are the identity.
4. **Resolve the tag on `@terra` at load time.** Rejected: would require the
   command and/or the tarball on the NAS and violate D2's no-transfer model.

## Open questions escalated (not decided here)

1. **Ownership of the shared command.** `conv-plat-prov.content-tag` is now a
   shared contract consumed by three repos, but `~/.bookmarks/shared-scripts`
   has no named owner for it. Per the Architect stop-condition ("missing owner
   for a shared contract"), a human should assign ownership/review for that
   module. Recommendation pending that decision: treat it as a versioned
   interface (the `--length` default and exit codes above).
2. **Pinning policy for the shared command.** ADR 0001 §6 pins dependencies, but
   the shared command is invoked by working-tree path with no revision pin.
   Should consumers pin a `shared-scripts` revision (or the command grow a
   compatibility version) so a change there cannot silently change both build
   and deploy tags? This is a new architectural question for human decision
   (it intersects the existing collection-pinning question in the plan §10.6).
3. **Control-node guarantee for `invoke`.** Production requires `invoke`; the
   dev shell provides it, but `bin/dot-bootstrap` may auto-install Ansible via
   the OS package manager outside `nix develop`. Confirm that the production
   control node is always the dev shell, or define a non-Nix `invoke`
   provisioning path. Not decided here.

## References

- [`0001-HomeServer__HomeAssistant.md`](./0001-HomeServer__HomeAssistant.md) — Ansible-side architecture baseline.
- [`../HomeServer__StratoFrame__ConvPlatProv__NikolaiGogolDeployment_plan.md`](../HomeServer__StratoFrame__ConvPlatProv__NikolaiGogolDeployment_plan.md) — Layer-1 implementation plan (§1.2, §3 Step 3, §12).
- [`../HomeServer__HomeAssistant_plan.md`](../HomeServer__HomeAssistant_plan.md) — Phase 5.
- `.agents/build-result-nikolaigogol-deployment-2026-09-27.md` §6b — "Tag-parity extension" build result.
- `~/.bookmarks/shared-scripts/conv_plat_prov.py` — `compute_content_tag()`, `@task content_tag`.
