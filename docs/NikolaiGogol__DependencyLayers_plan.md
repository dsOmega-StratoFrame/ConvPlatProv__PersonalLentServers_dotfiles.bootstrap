# Plan — `@NikolaiGogol` dependency layers (HAOS image + `Unix_dotfiles` + `Virt_scripts`)

## 0. Inputs & pinned revisions

| Input | Value |
|---|---|
| Target repo | `PersonalLentServers%Russian_dotfiles.bootstrap` (workspace `/app/...` only; `/shared/...` does not exist here) |
| Base HEAD | `004ee9e` (three commits above `c67f007`: `628fa62` zterra layout, `a267938` layout tests, `004ee9e` docs). The storage/container work is committed; only this plan doc and its cross-reference are uncommitted. `git` is only reached through `nix develop --command git`. |
| Companion docs | `docs/HomeServer__StratoFrame__ConvPlatProv__NikolaiGogolDeployment_plan.md`, `docs/HomeServer__HomeAssistant_plan.md`, `docs/adr/0001-*.md`–`0005-*.md`, `.agents/AGENTS.md`, `tests/README.md` |
| Control-node sources | this repo; `~/.bookmarks/shared-configs/Unix_dotfiles` (local checkout); `~/.bookmarks/shared-scripts` (content-tag command); the upstream monorepo checkout |
| Upstream repo | `git@github.com:dsOmega-StratoFrame/ConvPlatProv-HomeServer__HomeAssistant.git` |
| Upstream pinned commit | `fd56f6bdd1c8b9f3820c223296f2fbd1aeb27a01` — current local reference (`[Chore](Git): Init ConvPlatProv__NikolaiGogol as @NikolaiGogol submodule.`) |
| Upstream dep subfolder | `Virt_scripts_bootstrap/` (also holds `@NikolaiGogol/` at the same commit) |
| Default branches | `Virt_scripts`: `main`; `Unix_dotfiles`: **`dev`** (user-stated 2026-10-28; the local checkout has no remote, so the branch's presence is unverified) |
| HAOS | **16.3**, upstream qcow2 `haos_ova-16.3.qcow2` (user-tested). Digest value is an open item (§13). |
| Target host | `@terra` — TerraMaster NAS, TOS 6, Docker 29. No `git`, no GitHub access, no key (§7). |
| Target root | `zterra_root = /zterra` (`group_vars/terra/vars.yml`) |
| HAOS target path | `{{ zterra_root }}/shared-/@Manilov/dotfiles-/_configs/HomeAssistant__/haos_ova-16.3.qcow2` |
| `Unix_dotfiles` target path | `{{ zterra_root }}/local-/Projects/nikolaigogol/data/Unix_dotfiles` |
| `Virt_scripts` target path | `{{ zterra_root }}/local-/Projects/nikolaigogol/data/Virt_scripts_bootstrap` |

The upstream `.env` still names `/shared/archive-resources-/.../haos_ova-16.3.qcow2`.
That prefix is not a valid path on this control node or on `@terra`; it is a
source/configuration label, not the deployment destination. The destination is
the `zterra` path above.

## 1. Decisions locked with the user

1. **HAOS 16.3, no VDI fallback.** Pin **16.3** — this is the version the user
   has tested. Do not build a VDI/VM-disk fallback path. Require the upstream
   qcow2 (`haos_ova-16.3.qcow2`) for simplicity; stage it as a file, not as a
   converted disk.
2. **`container` implies `deps`.** `TAGS=container` must deploy the dependency
   layers first. `--skip-tags deps` is the explicit escape hatch for a
   containers-only run.
3. **Refs are configurable and strict by default.** If a ref is supplied, use it
   (reproducibility); otherwise fall back to that repo's **configured default
   branch** — `main` for `Virt_scripts`, **`dev`** for `Unix_dotfiles` (real work
   lands on `dev` before it is stabilized onto the main line). **Target state: the
   ref is always set** — it is unset only during short experiment iterations. The
   same pinning mechanics apply to both dependency repos.
4. **Makefile UX.** Add `Makefile.NixosDeps` with `STEP_TAGS := deps`:
   - a **list** target shows, per dependency repo, the configured ref, the
     resolved commit sha, and that commit's subject;
   - an **update** target pins the passed ref by resolving it to a concrete sha.
     With no ref passed it pins the commit currently at that repo's configured
     default branch.
   Updating a pin must never require editing role code — only the vars that hold
   the pins.
5. **Dirty-target protection.** During debugging the user edits files directly
   on `@terra`. The roles must **not** overwrite local modifications. Detect
   drift on the target (there is no `git` there) against the manifest written by
   the last successful deploy; on drift, fail with the affected paths and require
   an explicit `force` override. Never silently clobber.
6. **SSH key placement.** The key is needed **only on the machine that runs
   `ansible-playbook`** (the Ansible control node): that is where the private
   `git@github.com:` repos are cloned/fetched. It lives in that user's `~/.ssh/`
   (or a configured key path), optionally loaded through `ssh-agent`, and
   `known_hosts` must contain `github.com`. It is **never copied to `@terra`**.
   The target has no git, no key, and no GitHub access; it only receives file
   content via rsync over the existing Ansible SSH connection. Placing the key on
   the target is a **defect/security regression, not an option**.

## 2. Architecture summary

The dependency layers are three payload roles on top of the existing image
pipeline, followed by the existing container role. The import stays first so the
container never starts against a missing rootfs:

```
control node (localhost)                         @terra (TOS 6)
──────────────────────────                       ───────────────────────────────
nixos_image_load
  docker import (staged artifact) ───────────▶    ds-omega/nikolai-gogol:<sha12>

nixos_haos_image
  haos_ova-16.3.qcow2 ───── rsync ───────────▶    shared-/@Manilov/dotfiles-/
  sha256 verify                                  _configs/HomeAssistant__/
  .incoming → rename                             haos_ova-16.3.qcow2

nixos_unix_dotfiles
  git checkout @ <sha> ───── rsync ──────────▶    local-/Projects/nikolaigogol/
  (clean by default)                             data/Unix_dotfiles (+ .deploy-state)

nixos_virt_scripts
  git checkout @ <sha> ───── rsync ──────────▶    local-/Projects/nikolaigogol/
  subfolder Virt_scripts_bootstrap/             data/Virt_scripts_bootstrap
                                                 (+ .deploy-state)

nixos_container
  render compose + env from vars ────────────▶    docker compose up -d
                                                  (dep sources now present)
nixos_edge_sync (optional, off by default)
```

Order, and nothing else interleaved:

```
nixos_image_load → nixos_haos_image → nixos_unix_dotfiles
                 → nixos_virt_scripts → nixos_container → nixos_edge_sync
```

Tags per **payload** role: `[deps, <specific>, container]`, where `<specific>` is
`haos` / `unix_dotfiles` / `virt_scripts`. `nixos_image_load` keeps its `image`
membership and is also selected by `container` for this ordering. The effect is
that `TAGS=container` runs the whole dependency chain before `nixos_container`,
while `--skip-tags deps` leaves only the container role (and its existing image
prerequisite) to run.

No new runtime dependency is introduced on `@terra`: the target keeps Docker and
`rsync` (already required by `nixos_image_sync`); it gains no package manager
work, no git, and no key material.

## 3. Sources, destinations, and identity

| Role | Control-node source | Target destination | Identity check |
|---|---|---|---|
| `nixos_haos_image` | control-node copy of `haos_ova-16.3.qcow2` (archive root is an open item, §13) | `{{ zterra_root }}/shared-/@Manilov/dotfiles-/_configs/HomeAssistant__/haos_ova-16.3.qcow2` | file is regular + non-empty; sha256 equals the pinned HAOS digest (value open item) |
| `nixos_unix_dotfiles` | clean `Unix_dotfiles` checkout at the pinned ref | `{{ zterra_root }}/local-/Projects/nikolaigogol/data/Unix_dotfiles` | commit sha in `.deploy-state` + per-file/tree sha256 |
| `nixos_virt_scripts` | upstream monorepo checkout at the pinned ref, subfolder `Virt_scripts_bootstrap/` | `{{ zterra_root }}/local-/Projects/nikolaigogol/data/Virt_scripts_bootstrap` | commit sha in `.deploy-state` + tree sha256 |

Two ownership facts drive the role split:

- `zterra_layout` **already pre-creates**
  `shared-/@Manilov/dotfiles-/_configs/HomeAssistant__/` (see
  `group_vars/terra/vars.yml`). The HAOS role may rely on that directory existing
  but must still validate it.
- `zterra_layout` creates `local-/Projects` only. The
  `local-/Projects/nikolaigogol/data/**` leaves are **not** pre-created; they are
  the dependency roles' responsibility (create the leaf, then populate it).

**One canonical HAOS path (mandatory, Phase A).** `nixos_container` resolves the
bind source through `nixos_container_home_assistant_image`, and `@Manilov` keeps a
second, independent copy in `manilov_home_assistant_image`; both currently point at
the unversioned `haos_ova.qcow2`. Phase A must collapse them to **one** canonical
variable (the versioned path above) used by both the deploy role and the container
mount, so the writer and the fail-closed reader can never diverge. Staging
`haos_ova-16.3.qcow2` while leaving the mount pointed at `haos_ova.qcow2`
reproduces the current `Fail closed when a file mount source is missing` error.
The container-internal target stays `/opt/HomeServer__HomeAssistant/haos_ova.qcow2`.

## 4. Ref pinning policy

Resolution order for every dependency repo, highest precedence first:

1. explicit `-e` (e.g. `-e nixos_unix_dotfiles_ref=<ref>`);
2. the ref stored in group vars;
3. the repo's **configured default branch** (a role var, not a hardcoded literal):

| Repo | Default-branch var | Value |
|---|---|---|
| `Virt_scripts` | `nixos_virt_scripts_default_branch` | `main` |
| `Unix_dotfiles` | `nixos_unix_dotfiles_default_branch` | **`dev`** |

Planned pin vars (role-namespaced; final location is an open item, §13):

| Repo | Ref var | Resolved-commit var |
|---|---|---|
| `Virt_scripts` | `nixos_virt_scripts_ref` | `nixos_virt_scripts_commit` |
| `Unix_dotfiles` | `nixos_unix_dotfiles_ref` | `nixos_unix_dotfiles_commit` |
| HAOS (version, not a git ref) | `nixos_haos_version` | digest var (name TBD) |

Role defaults supply the per-repo default branch; group vars supply the accepted
pin; `-e` supplies a one-off experiment. The fallback differs by repo
(`main` vs `dev`) but the precedence order does not.

**`refs-update` writes a sha, not a branch.** A branch name is a moving target:
a default branch advances between list and deploy, so two runs are not
reproducible. The update target resolves the passed ref — or the repo's
configured default branch when none is passed — to a concrete commit and writes
that sha into the pin var. This makes the recorded intent exactly what the roles
check out.

**`refs-list`** renders one row per repo:

```
repo            configured ref   resolved sha                               subject
Virt_scripts    <ref>            <40-hex sha>                                <commit subject>
Unix_dotfiles   <ref>            <40-hex sha>                                <commit subject>
```

Both columns are shown so an operator can see a pin whose ref has moved (the
configured ref still names a branch but the resolved sha is older/newer).

**Always pinned in target state.** The accepted end state has an explicit sha in
the vars for both repos, and the HAOS version/digest pinned as well. Leaving a
ref unset (falling through to the repo's default branch) is permitted only during
short experiment iterations; it must be re-pinned before the change is considered
delivered.

## 5. Control-node checkout rules

- Default: refresh the remote and check out the **resolved commit detached**, then
  assert `git rev-parse HEAD` equals the pinned sha. No branch checkout, no
  implicit pull.
- Refuse a dirty control-node tree by default. A **dev-only opt-in**
  (`nixos_unix_dotfiles_allow_dirty` / `nixos_virt_scripts_allow_dirty`, default
  `false`) allows the working tree as-is and records `dirty: true` (with the
  dirty paths) in the target manifest.
- `.git` is never part of the payload and is excluded from rsync.
- `Unix_dotfiles` follows the **same** policy as `Virt_scripts`: same clean-checkout
  default, same dirty opt-in, same manifest recording, same rsync exclusion.
- The control node may use `ssh-agent` or a configured key path; this is the only
  place a GitHub credential exists (§7).

## 6. Dirty-target protection

Each dependency directive writes a manifest next to its payload (for example
`<target>/.deploy-state`) after a successful deploy. Minimal shape:

```yaml
role: nixos_unix_dotfiles          # or nixos_virt_scripts / nixos_haos_image
source_repo: <remote or "local-checkout">
ref: <configured ref>
commit: <40-hex sha>               # resolved commit
tree_sha256: <sha256>              # aggregate of the tracked tree
files:                             # per-file digests (or tree digest only)
  relative/path: <sha256>
deployed_at: <UTC timestamp>
dirty: false                       # true only with the dev-only checkout opt-in
```

Pre-flight on the target:

1. Read `.deploy-state` (absent means "first deploy" — proceed).
2. Hash the current files **without git** (`find` + `sha256sum`, or a single tree
   digest) and compare with the manifest.
3. If they differ, **fail** listing the affected paths and stop before rsync.
   The message names the manifest, the drifted paths, and the explicit override.

Override: an explicit `force` (`nixos_unix_dotfiles_force=true` /
`nixos_virt_scripts_force=true`, or a shared `deps_force=true`) is required to
replace drifted content. Nothing is silently clobbered. The same rule applies to
the single HAOS file: a target file whose digest differs from the accepted
manifest is drift, not an upgrade.

`.git` never reaches the target, so the manifest — not repository metadata — is
the only drift reference. That is intentional: the target has no git (§7).

## 7. Key placement and trust boundary

**The key belongs on the Ansible control node only.** The machine running
`ansible-playbook` is the one that clones and fetches the private
`git@github.com:` repositories, so its user owns the key in `~/.ssh/` (or a
configured key path), optionally through `ssh-agent`, with `github.com` present
in `known_hosts`. Nothing is copied to `@terra`. The target has no git, no key,
and no GitHub access; it receives only file content through rsync over the
existing Ansible SSH transport. Putting the key on the target is a
defect/security regression, not an alternative design.

Additional boundary rules:

- **One** key on the control node; no per-run key generation, no key material in
  the repository, no key material in group vars or the vault.
- No agent forwarding to `@terra` (`ForwardAgent no` on that hop). The target
  must never be able to reach GitHub with the operator's identity.
- rsync is pushed over the **existing** Ansible SSH connection; the dependency
  roles do not open a second credential path to the NAS.

## 8. Atomicity / partial state

- **HAOS**: write to `<dest>.incoming`, verify the sha256 there, then `rename()`
  onto the final name. Rename within the same `zterra` filesystem is atomic; an
  interrupted transfer leaves a `.incoming` file that is ignored and discarded on
  the next run. The live qcow2 is never truncated in place.
- **`Unix_dotfiles` / `Virt_scripts`**: rsync into a sibling staging directory
  (e.g. `<dest>.incoming`), verify the tree digest, then swap into place. An
  interrupted rsync or checkout therefore leaves no half-written bind source: the
  live directory remains the last good deploy.
- The manifest is written **after** the payload swap, so a crash between the two
  leaves a payload that the next run treats as drift and requires an explicit
  `force` (or reports a first deploy if the manifest is absent). No partial state
  is presented as success.

## 9. Failure modes and messages

| Failure | Message (intent) | Remediation |
|---|---|---|
| Missing control-node source | names the exact expected path and the repo/ref used | fetch/clone the repo at the pinned sha, or place the qcow2 at the configured path |
| Wrong digest | expected vs actual sha256 for the qcow2 / tree | re-fetch/copy the artifact; never force past a digest mismatch unless the pin is wrong |
| Unpinned / unknown ref | configured ref cannot be resolved to a commit | run `refs-update` (pin a sha) or pass a valid `-e <repo>_ref=` |
| Dirty target | lists the drifted paths and the manifest used for comparison | inspect the target edits; re-run with the explicit `force` override if they are meant to be replaced |
| Git auth failure | `Permission denied (publickey)` while fetching on the control node | load the control-node key (`ssh-agent`/`~/.ssh`), confirm `known_hosts` has `github.com`, verify access to the private repo |

Every failure stops before the next payload role; there is no best-effort
continuation that could mix refs.

## 10. Testing matrix

| Layer | What | Where / command |
|---|---|---|
| Unit | ref-resolution order, pin-var names, tag membership, `.git` exclusion, manifest shape, force gate | `tests/unit/` in the style of `test_zterra_step.py` (planned `test_dependency_layers_step.py`) |
| Integration | rsync/swap against mock paths, no network by default | fixtures under `/var/tmp` (e.g. `/var/tmp/deps-src`, `/var/tmp/zterra`) |
| Lint | Ansible/YAML style | `nix develop --command make lint` |
| Syntax | all playbooks | `nix develop --command make check` |

Unit tests follow the existing repo-checkout convention: parse `defaults`/`tasks`
with PyYAML, assert pure behaviour, no Ansible or Docker required. Integration
fixtures stay under `/var/tmp` so they never touch a real bind source.

Known environment-only failure: `test_shared_content_tag_command_matches_fixture`
(fixture tag `ecfcf1d2a1e3`) fails when `~/.bookmarks/shared-scripts` /
`invoke` is unavailable. It is not caused by this work and must **not** be
"fixed" by weakening the test.

## 11. Rollback

- Restore the previous `.deploy-state` (ref, commit, tree digest) and re-run the
  dependency roles: they re-checkout the previous sha and re-sync.
- **HAOS**: keep the previous qcow2 on replace (e.g.
  `haos_ova-16.3.qcow2.prev-<digest>`) and restore by rename; never rewrite the
  previous copy in place.
- A pin update is rolled back by reverting the pin var to the previous sha and
  re-running; no role-code edit is needed (decision 4).
- There is **no git on the target**; rollback is always a control-node re-run,
  not a target-side checkout.

## 12. Completion evidence / verification commands

On the control node, after a deploy:

```sh
# HAOS is a regular, non-empty file and its digest matches the pin
ssh terra 'test -f /zterra/shared-/@Manilov/dotfiles-/_configs/HomeAssistant__/haos_ova-16.3.qcow2'
ssh terra 'test -s /zterra/shared-/@Manilov/dotfiles-/_configs/HomeAssistant__/haos_ova-16.3.qcow2'
ssh terra 'sha256sum /zterra/shared-/@Manilov/dotfiles-/_configs/HomeAssistant__/haos_ova-16.3.qcow2'

# dependency directories are non-empty and match the manifest
ssh terra 'ls -A /zterra/local-/Projects/nikolaigogol/data/Unix_dotfiles'
ssh terra 'ls -A /zterra/local-/Projects/nikolaigogol/data/Virt_scripts_bootstrap'
ssh terra 'cat /zterra/local-/Projects/nikolaigogol/data/Unix_dotfiles/.deploy-state'
ssh terra 'cat /zterra/local-/Projects/nikolaigogol/data/Virt_scripts_bootstrap/.deploy-state'

# rendered compose still validates with the dependency bind sources present
ssh terra 'cd /zterra/local-/Projects/nikolaigogol && docker compose config -q'
```

Acceptance: every command exits `0`; each `.deploy-state` `ref`/`commit`/tree
digest equals the control-node resolved values; `refs-list` shows the same shas.

## 13. Open items / out of scope

**Open items (values not supplied by the repo/user — do not guess):**

1. **HAOS qcow2 sha256 value** to pin alongside `16.3`.
2. **Pin storage location**: `group_vars/nikolaigogol/vars.yml` or a dedicated
   deps vars file.
3. **`Unix_dotfiles` remote URL**, and whether the role fetches it or only uses
   the existing local checkout. The local checkout currently has no `HEAD` and no
   remote, so this cannot be inferred. Its default branch is **`dev`** (user-stated);
   confirm `dev` exists on the remote when the URL is supplied.
4. **Exact Makefile target names** (`refs-list` / `refs-update` are descriptive
   placeholders in this plan).
5. **HAOS source archive root on the control node.** The upstream `.env` names a
   `/shared/archive-resources-/...` path that does not exist here.

**Out of scope:**

- `@Manilov` (HomeAssistant OS VM) runtime provisioning and boot — only the
  qcow2 is staged for it.
- VDI/VM-disk fallback for HAOS (explicitly rejected in decision 1).
- Role code, playbook, `group_vars`, `tests`, or Makefile edits — this file is
  documentation only; those changes are the implementation follow-up.
