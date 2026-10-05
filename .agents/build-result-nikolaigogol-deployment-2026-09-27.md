---
# Build result — sync the NixOS image (local → `@terra`) and deploy the `@NikolaiGogol` system container

- **Task:** implement the accepted plan
  `docs/HomeServer__StratoFrame__ConvPlatProv__NikolaiGogolDeployment_plan.md`
- **Repo:** `PersonalLentServers%Russian_dotfiles.bootstrap`
- **Date:** 2026-09-27
- **Architecture baseline:** ADR 0001 (`docs/adr/0001-HomeServer__HomeAssistant.md`)
  — layered, idempotent, one playbook per layer, backup first, feature-scoped
  roles, defaults→group_vars→vault, pinned dependencies.
- **Plan revision:** the plan file as committed on `main` (163 lines), unchanged.
- **Repository revisions:** `git` is not installed in this container; the repo is
  a single initial commit on `main`. No commit was created (not requested).
  Changed-file list below is the source of truth for the working tree.
- **Result status:** implementation complete; unit evidence green; integration/E2E
  **not executable here** (no Docker/rsync/ansible). NOT verified — hand to Verifier.

## 1. Environment / command permissions

- Bash works only with `workdir` = repo dir:
  `/home/tangerineDream/.bookmarks/shared-projects/ChronoIndex/2026/PersonalLentServers%Russian_dotfiles.bootstrap`.
- Container lacks `pytest`, `ansible`, `ansible-lint`, `docker`, `rsync`, `git`.
  `nix` (2.33.3) + network are available.
- Per user instruction, unit dependencies were provided ad hoc via `nix shell`
  (`python3.withPackages [pytest pyyaml jinja2]`), then permanently via the new
  flake dev shell (see §6a). Installed and used.
- A repo `flake.nix`/`flake.lock` dev shell now provides `ansible-core 2.20.0`,
  `ansible-lint 25.8.2`, and the pinned `community.docker 5.0.5` /
  `ansible.posix 2.1.0` collections, so `make check`/`make lint` are runnable.
  Use `nix develop path:.` until `flake.lock` is committed (no `git` binary;
  `nix develop .` rejects the untracked flake).

## 2. Plan steps — status

| Step | Result |
|---|---|
| 1 — pin collection + structure guard | done (`requirements.yml`, `tests/unit/test_repo_structure.py`) |
| 2 — fill `group_vars/nikolaigogol/vars.yml` | done |
| 3 — role `nixos_image_artifact` | done |
| 4 — role `nixos_image_sync` | done |
| 5 — role `nixos_image_load` | done |
| 6 — role `nixos_container` (+templates/handlers) | done |
| 7 — `deploy-nikolaigogol.yml` + inventory debug entry | done |
| 8 — `verify-nikolaigogol.yml` | done |
| 9 — `tests/unit/test_nixos_image_step.py` | done |
| 10 — integration fixture + playbook tags | done |
| 11 — manual makefiles + connect helper | done |
| 12 — docs + optional edge-sync helper | done (helper inert, off by default) |

## 3. Files created

- `deploy-nikolaigogol.yml`
- `verify-nikolaigogol.yml`
- `roles/nixos_image_artifact/{defaults,tasks}/main.yml`
- `roles/nixos_image_sync/{defaults,tasks}/main.yml`
- `roles/nixos_image_load/{defaults,tasks}/main.yml`
- `roles/nixos_container/{defaults,tasks}/main.yml`, `handlers/main.yml`,
  `templates/docker-compose-system.yml.j2`, `templates/env.j2`
- `roles/nixos_edge_sync/{defaults,tasks}/main.yml`
- `tests/unit/test_nixos_image_step.py`
- `tests/integration/fixtures/minimal-rootfs.tar.xz`
  (sha256 `ecfcf1d2a1e30e5b57955c69e9f8b8de57930afd2d492917ec2ab64add29a9a7`,
  content tag `ecfcf1d2a1e3`)
- `Makefile.NixosImage`, `Makefile.NixosContainer`, `Makefile.NixosEdgeSync`

## 4. Files modified

- `requirements.yml` — added `ansible.posix`.
- `group_vars/nikolaigogol/vars.yml` — replaced the two placeholders with the full
  deployment interface (image identity, artifact path, staging dir, container
  identity, mounts, direct-SSH overrides, secrets note, `ansible_*`-precedence
  warning).
- `hosts.ini` — populated `[nikolaigogol]` + `[nikolaigogol:vars]` debug entry
  (`ansible_host=terra-local ansible_port=2223`).
- `tests/integration/playbook.yml` — added `image`/`container` tags + mock values.
- `tests/integration/Dockerfile.target` — added `rsync`.
- `tests/unit/test_repo_structure.py` — generalized for the Layer-1 playbook;
  `ansible.posix` expected.
- `Makefile.Steps` — added `VERIFY_PLAYBOOK` and `EXTRA_ARGS`.
- `Makefile` — `check` now syntax-checks the Layer-1 playbooks; help updated.
- `README.md` — Layer 1 section, two-speed model, makefiles, layout.
- `docs/HomeServer__HomeAssistant_plan.md` — Phase 5 implemented, Phase 6
  roadmap, interfaces, test matrix rows.
- `docs/adr/0001-HomeServer__HomeAssistant.md` — status Layers 0–1 Accepted;
  roles table, playbook list, collections note.
- `tests/unit/test_base_step.py`, `tests/unit/test_docker_step.py` — see
  deviations §7 (pre-existing broken tests).

## 5. Commands and exit results

| Command | Result |
|---|---|
| `nix shell … python3.withPackages [pytest pyyaml jinja2] --command python3 -m pytest tests/unit -q` | **52 passed** |
| `nix develop . --command make unit` | **57 passed** (52 + 5 tag-parity tests) |
| `nix develop . --command make check` (4 playbooks `--syntax-check`) | **exit 0, all four clean** |
| `nix develop . --command make lint` (ansible-lint) | **0 failures, 0 warnings** (production profile) |
| localhost role run with the fixture (`content_tag_required: true`) | **ok=8, failed=0**; tag `ecfcf1d2a1e3`, image `ds-omega/nikolai-gogol:ecfcf1d2a1e3` |
| localhost role run with `content_tag_command=/nonexistent/...`, required=true | **fails with the intended guard (rc=2)** |
| `python3` YAML parse of all `**/*.yml`/`*.yaml` | **OK** |
| heuristic undefined-`nixos_*` scan (tasks/playbooks/templates) | no real undefined refs (only role names / `_*` doc text) |

## 6. Tests added / updated

- `tests/unit/test_nixos_image_step.py` — tag derivation (12-hex), no moving tag
  in group_vars, artifact archive path, sync/load defaults, compose render
  invariants (privileged, `cgroup: host`, `network_mode: host`, `SIGRTMIN+3`,
  `command: /init`, `NET_ADMIN`, `seccomp=unconfined`, `pull_policy`,
  statuses), per-mount volume lines, env render identity. **All pass.**
- `tests/unit/test_repo_structure.py` — new assertions: Layer-1 play targets
  `terra`, loads `group_vars/nikolaigogol/vars.yml` via `vars_files`, role
  order/tags, roles exist + namespaced defaults, `ansible.posix` declared.
- Integration wiring added but **not executed** (no Docker/rsync in this
  container).

## 6a. Development shell (flake) — added in a follow-up build task

A repo `flake.nix` + `flake.lock` was added by the `nix-build` worker so the
repo's gates are runnable without host tooling. Its full manifest is
`.agents/build-result-flake-devshell-2026-09-27.md`.

- `devShells.default` (x86_64-linux; aarch64-darwin also evaluates) provides
  `python3` + `pytest`/`PyYAML`/`Jinja2`, `ansible-core 2.20.0`,
  `ansible-lint 25.8.2`, and the pinned `community.docker 5.0.5` /
  `ansible.posix 2.1.0` collections via `ANSIBLE_COLLECTIONS_PATH`.
- `nixpkgs` pinned to `bcc4a9d9533c033d806a46b37dc444f9b0da49dd` (nixos-26.05).
- `.envrc` keeps `dotenv ./.env.dev` and adds `use flake`; `.direnv/` gitignored.
- Docker is intentionally not provided (`make it-*`/`e2e` stay host-dependent).
- Usage: `nix develop .` (after the flake files are tracked); otherwise
  `nix develop path:.`.

## 6b. Tag-parity extension (follow-up build task)

Follow-up request: "support such tag creation at the NikolaiGogol repo, so local
testing matches remote." The content-addressable rule (sha256(tarball)[:12])
previously lived in the Ansible role only; it is now derived by **one shared
command** so the build side and the deploy side cannot drift:

`invoke --search-root=~/.bookmarks/shared-scripts conv-plat-prov.content-tag <tarball>`

- **Shared task (separate repo):** `~/.bookmarks/shared-scripts/conv_plat_prov.py`
  gained `compute_content_tag()` (streaming sha256) and an `@task content_tag`
  (namespace `conv-plat-prov.content-tag`; `conv_plat_prov` is already in that
  repo's `tasks.py` collection). No new file needed there.
- **Unix_dotfiles:** `Makefile.ConvPlatProv-docker` gained `image-tag-<machine>`
  and `tarball-<machine>` targets using the shared command.
- **`@NikolaiGogol` repo:** `Makefile` computes `IMAGE_TAG` from the tarball via
  the shared command, exports `IMAGE_TAG`/`IMAGE_NAME` for compose, and
  `import-nixos` imports the content tag then tags a `:latest` alias (user
  choice); `.env.example` documents `IMAGE_TAG=latest` as a fallback only.
- **This repo:** `roles/nixos_image_artifact` runs the shared command on the
  control node (`delegate_to: localhost` — nothing is sent to `@terra`), asserts
  its output equals the artifact sha256 slice, and uses it as the tag. New
  defaults `nixos_image_artifact_content_tag_command` /
  `nixos_image_artifact_content_tag_required` (default false; `group_vars` sets
  true). `flake.nix` dev shell adds `invoke`.
- **Tests:** `tests/unit/test_nixos_image_step.py` gained 5 tests, including
  `test_shared_content_tag_command_matches_fixture` (runs the shared command on
  the fixture and asserts `ecfcf1d2a1e3`).

Scope note: this edits two non-deployment repos (Unix_dotfiles, `@NikolaiGogol`)
and shared-scripts, per explicit user approval ("Both repos" / "Add to
conv_plat_prov.py"). No commits were made in any repo.

## 7. Deviations (need reviewer attention)

1. **Wiring choice (user-approved):** `deploy-nikolaigogol.yml` targets `terra`
   and loads `group_vars/nikolaigogol/vars.yml` via `vars_files`. Documented that
   `vars_files` outranks inventory vars, so no `ansible_*` may appear there.
2. **Fixed two pre-existing unit-test bugs** (present before this task; confirmed
   by running the suite on the untouched tree):
   - `test_base_step.py::_is_blocked` used `bool(render(...))`, which is truthy
     for the string `"False"`; changed to compare against `"true"`.
   - `test_docker_step.py::test_gpg_url_derives_from_base` compared a literal to a
     Jinja-templated default; now renders the template first.
   These are outside the plan's stated affected files but were required for the
   plan's `make unit` green acceptance criterion. No production behaviour changed.
3. **Template renamed** `templates/.env.j2` → `templates/env.j2` because
   `.gitignore`'s `.env.*` pattern would have excluded the dot-named template from
   version control. Task updated accordingly.
4. **Added `nixos_image_load_manage`** (default true; integration sets false) so
   the integration run can exercise wiring without a Docker daemon.
5. **Added `nixos_container_docker_binary`/`nixos_container_become` to
   `group_vars/nikolaigogol/vars.yml`** so `verify-nikolaigogol.yml` (which does
   not run the role) has them; role defaults still declare them.
6. **Edge-sync helper included in `deploy-nikolaigogol.yml`** under the
   `edge_sync` tag (self-gated off). This is a small structural choice (vs a
   separate playbook) to avoid an extra playbook; it never runs for
   `image,container`.
7. **Fixed all ansible-lint findings so `make lint` is green.** Three were in the
   new role (`nixos_image_artifact`: Jinja spacing + a >160-char line). Five were
   pre-existing and fixed without behaviour change: FQCN for
   `ansible.posix.authorized_key` and `ansible.builtin.import_tasks`, plus
   justified `# noqa: command-instead-of-module` annotations on the `tar`
   archive-creation (`backup_tos`) and `systemctl is-active` probe
   (`verify-terra.yml`) tasks. This touched two pre-existing files beyond the
   plan's list, to satisfy the plan's `make lint` clean criterion.

## 8. Unresolved issues / confirm on first live run

From the plan §10, still open (sensible defaults shipped):
1. `Unix_dotfiles` build target/artifact path (`build-NikolaiGogol` assumed).
2. `options.nix` provenance (placeholder vs Unix_dotfiles flake).
3. Container sshd port `2223` + authorized keys (a Unix_dotfiles change).
4. Real `@terra` mount roots / storage volume layout
   (defaults use `/var/lib/nikolaigogol/**`).
5. Whether `bootstrap_nix` stays on `@terra` (left as-is).
6. Collection pinning policy (`community.docker`/`ansible.posix` unpinned).

New risks discovered during build:
- `docker` under `become` may not resolve on TOS `secure_path`; if so, use an
  absolute docker path or rely on docker-group membership (`become: false`).
- `ansible.posix.synchronize` requires `rsync` on both ends; the role fails early
  with guidance (or installs via apt on Debian) — confirm on TOS.
- The integration `nixos_image_tag` is pinned to the fixture's tag; regenerate if
  the fixture changes.

## 9. Migrations / generated artifacts / rollback

- No data migration (new layer; content-addressed import is additive).
- Generated: `tests/integration/fixtures/minimal-rootfs.tar.xz`.
- Rollback: see plan §8 (retag `group_vars` image tag and re-run `container`;
  `rm` the staged tar; revert compose/group_vars). Whole layer:
  `docker compose -f <rendered> down`.

## 10. Proposed knowledge changes (for Architect/Reporter)

- ADR 0001: Layers 0–1 now Accepted (already edited in-repo).
- Establish a repo convention that a `terra`-targeted layer play loads its
  inner-host group_vars via `vars_files` and must never define `ansible_*` there.
- Note the ephemeral-container tooling gap (no ansible) for future agents.

## 11. Handoff

- **Files/interfaces changed:** see §3–§4, plus the flake dev shell in §6a.
- **Evidence:** 57/57 unit tests (incl. shared-command fixture parity);
  `make check` clean on all four playbooks; `make lint` 0 failures/0 warnings
  (production profile); a localhost role run on the fixture produced tag
  `ecfcf1d2a1e3` / image `ds-omega/nikolai-gogol:ecfcf1d2a1e3` and the
  required-command guard fired as intended. Integration/E2E still outstanding
  (need Docker + the real NAS).
- **Not verified.** Next: Reporter turns this into a report; Verifier checks
  acceptance (needs Docker + SSH to `@terra` to complete the integration/E2E
  layers).
