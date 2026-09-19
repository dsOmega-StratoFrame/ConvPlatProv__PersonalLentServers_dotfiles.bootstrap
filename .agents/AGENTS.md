# AGENTS.md — agent guide for `PersonalLentServers%Russian_dotfiles.bootstrap`

Ansible bootstrap for the home-server stack built around a TerraMaster NAS
(`@terra`, running **TOS 6**). Layer 0 installs **Nix** and **Docker** on the
NAS; the inner hosts `@NikolaiGogol` (NixOS system container) and `@Manilov`
(HomeAssistant OS VM) are layered on top of it. This file is about *where things
go* and *how to write them*. For the current state of any given piece, read the
files themselves — they change.

## Orient first (pointers, not summaries)

- `README.md` — the user-guide: prerequisites, deploy and test workflow.
- `HomeServer__HomeAssistant.yml` — the roles actually enabled *and their
  order*. Read this before assuming a role is active.
- `roles/<role>/defaults/main.yml` — the tunable variables for that feature.
- `group_vars/<host>/vars.yml` — the values chosen for a host.
- `docs/HomeServer__HomeAssistant_plan.md`, `docs/adr/0001-*.md` — the rollout
  plan and the Ansible-side architecture; `docs/Deploy#NixContainer.puml` — the
  system diagram.
- `tests/README.md` — the four testing layers and how to run them.
- `Makefile` — the operator entrypoints; targets are added/changed over time.

Prefer reading/grepping these over trusting any in-file paraphrase. Names drift
as hosts and roles are added, so treat examples as illustrative, not exhaustive.

## Where a file goes

The deployment is decomposed: **each role is one small, named feature**.
Add a new feature as a new role rather than growing an existing one.

New role → `roles/<feature>/`, split by purpose:

- `defaults/main.yml` — every adjustable variable, with a safe default. This is
  the role's public interface.
- `tasks/main.yml` — orchestration. Push OS/distro-specific work into
  `tasks/<family>.yml` (include it from main), so adding a distro means adding a
  file, not editing the flow.
- `vars/main.yml` (or `vars/<Distro>.yml`) — internal constants that operators
  should not tune.
- `handlers/main.yml` — deferred reactions (restart a service, re-read a group).
- `files/`, `templates/` — static assets and generated config.
- `meta/main.yml` — dependencies, only if genuinely required.

Then enable the role in `HomeServer__HomeAssistant.yml` with a tag.

Other placements:

- Per-host values → `group_vars/<host>/vars.yml`.
- Per-host secrets → the encrypted `group_vars/<host>/vault`, wired through a
  `vault_*` variable in `vars.yml`.
- Inventory group + host → `hosts.ini`. Inner hosts are provisioned through
  `@terra`; add a direct SSH entry only as a debugging override.
- Truly shared defaults → `group_vars/all.yaml`, sparingly.
- A new stage → add the role/tag to `HomeServer__HomeAssistant.yml`; a new
  layer → its own playbook (see the roadmap in the plan/ADR).
- Tests → `tests/unit/` (pure logic, no Ansible), `tests/integration/playbook.yml`
  (add the new tag), `Makefile.<Step>` for manual testing.

## How to write a role

- **One feature per role.** Prefer composable building blocks (backup → establish
  access → prepare deps → acquire → execute → report). New capability = new role.
- **Defaults declare, group_vars supply.** Never hardcode host names, IPs,
  passwords, disk devices or domains in role logic.
- **Secrets go through the `vault_*` indirection**, never inline.
- **Keep host-specific logic out of roles** — it belongs in inventory/group_vars.
- **Namespace role variables with the role name** (e.g. `bootstrap_docker_*`).
  `tests/unit/test_repo_structure.py` enforces this; keep facts distinct from
  inputs.
- **Be explicit about delegation and change status.** Work on the control machine
  uses `delegate_to: localhost` + `become: false`; remote tasks rely on the
  inventory connection variables. For `shell`/`command`, set
  `changed_when`/`failed_when` deliberately.
- **Be idempotent.** Gate on an existing state (`command -v`, `creates:`, a fact)
  so a second run reports no changes; that is the guarantee layered provisioning
  relies on.
- **Tag every role** so it can be selected through the playbook/`dot-bootstrap`.
- **Handle OS variance with data** (include vars keyed by
  `ansible_os_family`/`ansible_distribution`), with a `default.yml` fallback —
  TOS 6's reported distribution is not guaranteed.
- **Validate inputs early** with `fail` instead of letting a later task fail
  obscurely.
- Start YAML files with `---`; give tasks descriptive names.

## Testing (required per major step)

Every step is expected to carry test substeps at the layers that add signal:

1. **Unit** (`tests/unit/`, pytest + PyYAML/Jinja2, no Ansible) — structural
   invariants and any pure logic (e.g. a composed apt line). Run `make unit`.
2. **Integration** (mock `@terra` container) — add the tag to
   `tests/integration/playbook.yml`; run `make it-up && make it-run TAGS=<tag>`.
3. **E2E** (real NAS, mutating) — `make run TAGS=<tag>` then `make test`.
4. **Manual** — a `Makefile.<Step>` (`STEP_TAGS := <tag>` + `include
   Makefile.Steps`) with human (`shell`, `shell-ssh`), agent (`dry`, `verify`,
   `up`, `down`, `clean`) and mixed (`run`, `logs`) targets.

Record the new row in the matrix in the rollout plan. See `tests/README.md`.

## Variables

Do not maintain a var list here — the source of truth is `README.md` plus each
role's `defaults/main.yml`. Look them up by grepping the role-name prefix.

## Running and validating

- Operators run through the `Makefile` (`make run [TAGS=<tag>]`, `make test`,
  `make unit`, `make it-*`, `make e2e`). `bin/dot-bootstrap` is the wrapper: it
  may auto-install Ansible via the local package manager and prompts for tags.
- Before touching a real host, prefer safe checks:
  `ansible-playbook HomeServer__HomeAssistant.yml --syntax-check`,
  `--list-tasks --tags <tag>`, `--check` where meaningful, and `bash -n` on
  edited shell.
- `ansible` is not on this container's PATH; `nix` is. Installing or running it
  hits the network — ask first.

## Secrets and safety boundaries — ask first

1. **Vault files** (`group_vars/<host>/vault`) are ansible-vault encrypted.
   Never print, decrypt, or commit them in plaintext, and never read or print
   `.vault_pass.py` (gitignored; derived from `.vault_pass_example.py`).
2. **Private keys, `.pub` uploads and backup archives** (`backups/`,
   `tests/artifacts/`) must never be committed or echoed.
3. **Running a playbook against `@terra` mutates the NAS over SSH** (installs
   Nix/Docker, changes `/etc/nix/nix.conf`, manages groups). Confirm the exact
   inventory host and tags; never run `all` blindly.
4. **Preconditions the code cannot fix:** TOS SSH is disabled by default and must
   be enabled in the UI, Security Isolation Mode disables SSH, and the first TOS
   account is a superuser. Confirm these instead of trying to automate them.
5. **Network/sudo side effects** — `dot-bootstrap` auto-install,
   `ansible-galaxy install`, image pulls, Nix builds — are escalation
   boundaries. Request permission and prefer a dry/limited run.

## Working agreements

- Read `HomeServer__HomeAssistant.yml` to confirm what is enabled; don't assume
  a role is active.
- **`backup_tos` runs first**: never reorder another role ahead of it.
- Keep changes small and feature-scoped; extend the decomposition rather than
  centralizing logic.
- Never redefine the deployment model (layered, idempotent provisioning on top
  of `@terra`) without an explicit decision from the user.
- Preserve the `defaults` → `group_vars` variable split, the role-name variable
  namespacing, and the `vault_*` indirection.
