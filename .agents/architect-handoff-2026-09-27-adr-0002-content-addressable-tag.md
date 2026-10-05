# Architect handoff — Logseq journal entry for 2026-09-27 (ADR 0002 content-addressable image tag)

> Scratch handoff. This is **not** repository documentation. It exists because the
> dedicated architect journal instance (`architect-kbn`) could not bind the
> `logseq-summ-architect*` MCP tools in this harness (same harness issue recorded
> in `analyst-handoff-2026-09-27-nikolaigogol-deployment-plan.md`). A
> **directly-invoked** `@architect` (top-level session, where the
> `logseq-architect*` / `logseq-summ-architect*` MCP tools bind) should publish
> the content below through the architect → `architect-kbn` journaling workflow.
> Safe to delete after publishing. **Do not edit the four git repositories; no
> commits exist (git unavailable — revisions are working-tree/uncommitted). Do
> NOT set `reviewed-by`.**

## What changed (architecture/contract documentation only)

The architect recorded a new **Accepted** cross-repo ADR and updated architecture
docs in `PersonalLentServers%Russian_dotfiles.bootstrap`:

1. **NEW** `docs/adr/0002-ContentAddressableImageTag.md` — ADR 0002
   "Content-addressable image tags derived by one shared command"; status
   Accepted (user-approved 2026-09-27); publication to
   `ai-shared-Architecture_system` requested, **not yet published**.
2. **EDITED** `docs/adr/0001-HomeServer__HomeAssistant.md` — added a "Tag
   identity contract" pointer bullet after Status, a pointer sentence in §6
   "Dependencies are pinned", and a References entry. **No ADR 0001 decision
   changed.**
3. **EDITED** `docs/HomeServer__StratoFrame__ConvPlatProv__NikolaiGogolDeployment_plan.md`
   (Layer-1 plan) — §1 item 2, §2 diagram, §3 Step 3, §7, §10 (new items 7–9),
   and **NEW §12** "Cross-repo content-addressable tag contract (follow-up;
   ADR 0002)".
4. **EDITED** `docs/HomeServer__HomeAssistant_plan.md` — companion-docs list +
   Phase 5 (Layer-1) section + test bullet.

All docs; no code, no Makefiles, no tests, no commits.

## Task for the publishing architect

Publish the content below to Logseq, following the normal architect →
`architect-kbn` journaling workflow:

- **Dedicated page:** `ai-arc Architect_system/ADR 0002 — Content-addressable image tags derived by one shared command`
  (reconcile with the existing graph; the task's suggested label was
  `Architecture/ADR 0002 — Content-addressable image tag (cross-repo contract)`).
- **Journal entry:** `ai-arc Architect_system/_journals/2026-09-27` →
  `Updated [[ai-arc Architect_system/ADR 0002 — Content-addressable image tags derived by one shared command]]`
  **+ a simplified copy of the page** (below).
- **Cross-link with ADR 0001 page:** link from the ADR 0001 page to this page and
  back. Relation is **complementary, not `supersedes`** — ADR 0002 fixes the tag
  *identity* contract ADR 0001 §6 references ("content-addressed … never a moving
  tag"); it neither supersedes nor changes any ADR 0001 decision. Scope is
  cross-repo (wider than ADR 0001's Ansible-only scope).
- **Publish / request immutable revision:** `ai-shared-Architecture_system/ADR 0002 — Content-addressable image tags derived by one shared command`
  (now Accepted). Link with the ADR 0001 shared revision via the complementary
  relationship, **not** `supersedes`. Do **not** set `reviewed-by`.

If the publishing path cannot bind the shared-namespace MCP tools, publish to
`ai-arc Architect_system` and leave the `ai-shared-Architecture_system` request
open (the ADR itself already states "publication requested; not yet published").

---

## Content to publish (simplified copy)

**Title:** ADR 0002 — Content-addressable image tags derived by one shared command.

**Status:** Accepted (user-approved 2026-09-27). Complements
`[[ADR 0001 — HomeServer/Home Assistant Ansible bootstrap architecture]]`; does
**not** supersede or change it. Scope is **cross-repo** — wider than ADR 0001's
explicitly Ansible-only scope. Enforced by `roles/nixos_image_artifact` (deploy
repo) + the shared task in `~/.bookmarks/shared-scripts`. Rollout plan: the
NikolaiGogol deployment plan §12. Publication to
`ai-shared-Architecture_system` requested; not yet published.

**Source (reference, do not copy):**
`docs/adr/0002-ContentAddressableImageTag.md` in
`PersonalLentServers%Russian_dotfiles.bootstrap`; page reference
`[[ADR 0002 — Content-addressable image tags derived by one shared command]]`.
Working tree only — four separate git repos, **no commits** (git unavailable).

### Context / problem

The `@NikolaiGogol` system-container image is content-addressed:
`ds-omega/nikolai-gogol:<sha12>` where `sha12` = first 12 hex of the rootfs
tarball sha256 — never `latest`. Before this decision the `sha256[:12]` rule
lived **only in the Ansible role**; the build-side repos had a separate notion of
image identity, so a locally built/tested tag could disagree with the remote
deploy tag for the same bytes. The rule was extracted into **one shared
command** so build and deploy agree by construction.

### Decisions

- **D1 — Single source of truth for the rule.** `sha256(tarball)[:12]` has
  **one implementation**: `conv_plat_prov.compute_content_tag()` /
  `conv-plat-prov.content-tag`
  (`invoke --search-root=~/.bookmarks/shared-scripts conv-plat-prov.content-tag <tarball>`)
  in `~/.bookmarks/shared-scripts/conv_plat_prov.py` (streaming sha256; default
  `--length 12`). Consumers: deploy repo `roles/nixos_image_artifact`;
  `Unix_dotfiles` `Makefile.ConvPlatProv-docker` (`image-tag-<machine>` /
  `tarball-<machine>`); `@NikolaiGogol` `Makefile` (`IMAGE_TAG`/`IMAGE_NAME`,
  `import-nixos`). No repo may carry a second implementation; the role's in-role
  `checksum[:12]` slice is only the hermetic-test / degraded fallback.
- **D2 — Control-node execution.** The Ansible role runs the command on the
  control node (`delegate_to: localhost`, `become: false`); nothing is sent to
  `@terra`. Requires `invoke` on the control-node PATH, provided by this repo's
  `flake.nix` dev shell. Production
  `nixos_image_artifact_content_tag_required: true` (`group_vars`); role default
  `false` so tests stay hermetic. Command var:
  `nixos_image_artifact_content_tag_command`.
- **D3 — Defense in depth.** The role asserts the shared command's output equals
  the artifact `stat` sha256 slice (`..._checksum_slice`); a mismatch fails with a
  message pointing at `~/.bookmarks/shared-scripts` / pinned revisions.
- **D4 — `:latest` is a LOCAL ALIAS ONLY** (in `@NikolaiGogol`
  `make import-nixos`); deploy/verify use **exclusively** the content tag.
  `.env.example` documents `IMAGE_TAG=latest` as a not-yet-built fallback, never
  the deployed identity.
- **D5 — User-approved scope extension.** The implementing change edits **four**
  separate git repos: shared-scripts (canonical rule), `Unix_dotfiles`,
  `@NikolaiGogol`, and this deploy repo. User explicitly approved editing the two
  non-deployment repos + shared-scripts. **No commits made** in any repo; git
  unavailable, so revisions are working-tree/uncommitted.

### Cross-repo dependency edges (runtime; no tarball to a third party)

- deploy repo → shared-scripts: `conv-plat-prov.content-tag`, control node;
  `invoke` from this repo's dev shell; production requires it.
- `Unix_dotfiles` → shared-scripts: `make image-tag-<machine>`.
- `@NikolaiGogol` → shared-scripts: `Makefile` `IMAGE_TAG`/`IMAGE_NAME`;
  `make import-nixos` tags the content tag then adds the local `:latest` alias.

Shared command interface: `content-tag <tarball> [--length N]`, default `N=12`;
exits 1 with a clean message on missing artifact / invalid length.

### Findings (F1–F4)

- **F1:** `invoke` runs on its own interpreter; `python3 shared-scripts/<module>.py`
  cannot `import invoke`; entrypoint is
  `invoke --search-root=<dir> <collection>.<task>` — hence `invoke` added to the
  flake dev shell.
- **F2:** ansible-core 2.20 rejects nested filter+slice inside `assert.that`
  ("Conditional expressions must be strings"); slice precomputed into a fact.
- **F3:** `ansible.builtin.stat` does not follow a symlink that is the **final**
  path component (reports no checksum); the real artifact is a regular file →
  **test-fixture caveat, not a role bug**.
- **F4:** the shared command streams sha256 in 1 MiB chunks (works on large
  rootfs tarballs); errors exit 1 with a clean message.

### Compatibility guarantees / prohibited changes

Guarantees: for a given tarball, the command returns exactly `sha256(tarball)[:12]`
(or `[:N]`); `docker import`, compose reference and verify use the same content
tag for the same bytes; output has no trailing newline
(`print(tag, end="")`). Prohibited: a second implementation of the rule in any
repo; moving tags in deploy/verify or `group_vars/nikolaigogol/vars.yml`;
transferring the command/`invoke`/`shared-scripts` to `@terra`; replacing the D3
cross-check with a non-failing "prefer shared output" behaviour in production.

### Validation evidence

- `make unit` → **57 passed** (incl. `test_shared_content_tag_command_matches_fixture`).
- `make check` → 4 playbooks syntax-clean; `make lint` → 0 failures / 0 warnings
  (production profile).
- Localhost role run on the fixture → tag `ecfcf1d2a1e3`, image
  `ds-omega/nikolai-gogol:ecfcf1d2a1e3`; the required-but-missing-command guard
  fired as intended.
- **Outstanding:** integration/E2E (need Docker + the real NAS).

### Rollback (break-glass)

Set `nixos_image_artifact_content_tag_required: false` (role falls back to the
in-role slice) and restore shared-scripts; or revert the role/defaults to the
pre-D1 in-role derivation. `:latest` alias is harmless to leave
(`docker rmi ... :latest`). Falling back re-introduces exactly the drift D1
removes — break-glass, not steady state.

### Open questions ESCALATED (do not resolve; human decision needed)

1. **Ownership of the shared command** — `conv-plat-prov.content-tag` is a shared
   contract with three consumers but `~/.bookmarks/shared-scripts` has no named
   owner (Architect stop-condition: "missing owner for a shared contract").
2. **Pinning policy** — the command is invoked by working-tree path with no
   revision pin; should consumers pin a shared-scripts revision / version the
   interface? (intersects plan §10.6 collection pinning).
3. **`invoke` guarantee on a non-dev-shell control node** (e.g.
   `bin/dot-bootstrap` OS-package auto-install outside `nix develop`).

### Alternatives considered (rejected)

1. Keep the rule in the Ansible role and copy it into each Makefile — three
   implementations that drift (the problem).
2. Shared shell snippet / Makefile include instead of a Python `invoke` task —
   re-opens the interpreter/portability issues (F1).
3. Read the tag from a build-side manifest — adds a second source of truth that
   can disagree with the bytes.
4. Resolve the tag on `@terra` at load time — violates D2's no-transfer model.

### References (repo docs)

- `docs/adr/0001-HomeServer__HomeAssistant.md` — Ansible-side baseline.
- `docs/HomeServer__StratoFrame__ConvPlatProv__NikolaiGogolDeployment_plan.md`
  §1.2, §3 Step 3, §12.
- `docs/HomeServer__HomeAssistant_plan.md` — Phase 5.
- `.agents/build-result-nikolaigogol-deployment-2026-09-27.md` §6b
  ("Tag-parity extension").
- `~/.bookmarks/shared-scripts/conv_plat_prov.py` —
  `compute_content_tag()`, `@task content_tag`.
