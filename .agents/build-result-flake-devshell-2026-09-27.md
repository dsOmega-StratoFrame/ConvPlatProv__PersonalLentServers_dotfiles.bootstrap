# Build result — flake-based development shell

- **Date:** 2026-09-27
- **Task:** Add a bounded, additive `flake.nix` dev shell so contributors/agents can run the
  repo's test/lint tooling (`make unit`, `make check`, `make lint`) without host provisioning.
- **Repository (only write scope):**
  `/home/tangerineDream/.bookmarks/shared-projects/ChronoIndex/2026/PersonalLentServers%Russian_dotfiles.bootstrap`
  (from inside the sandbox this resolves to
  `/ztangerineDream/shared-/@salt/shared-/Projects/ChronoIndex/2026/PersonalLentServers%Russian_dotfiles.bootstrap`)
- **Plan step:** add flake dev shell (no discovery/architecture/playbook/role changes).
- **Architecture baseline:** unchanged. No files under `roles/**`, `*.yml`, `group_vars/**`,
  `tests/**`, `Makefile*`, `requirements*.yml`, or `docs/**` were modified.
- **Git:** `git` is not installed in this environment; **no commits were made**. Revision
  reference below is the working-tree change set.
- Task/session IDs: none were supplied in the task packet; recorded as `n/a`.

---

## 1. Files added / modified

| File | State | Purpose |
|---|---|---|
| `flake.nix` | **added** | Pins nixpkgs; exposes `devShells.default` for `x86_64-linux` and `aarch64-darwin` with Python 3.13 (pytest/PyYAML/Jinja2/ansible-core), `ansible-lint`, `rsync`, `git`, and `ANSIBLE_COLLECTIONS_PATH` wired to the pinned collection source. |
| `flake.lock` | **added** | Locks `nixpkgs` to a fixed rev + narHash. |
| `.envrc` | **modified** | Kept `dotenv ./.env.dev`; appended `use flake` (with a comment about the commit requirement). Existing dotenv behaviour preserved. |
| `.gitignore` | **modified** | Added `.direnv/` (required because `.envrc` was touched). |
| `README.md` | **modified** | Added a short, accurate `#### Development shell (Nix flake)` note under "Verify and test". |
| `.agents/build-result-flake-devshell-2026-09-27.md` | **added** | This manifest. |

No secrets. Nothing was committed. `.ansible/` was restored to its (empty) baseline after the
lint test side effect was removed.

---

## 2. Pinned input and how `flake.lock` was generated

- **Input:** `github:NixOS/nixpkgs/bcc4a9d9533c033d806a46b37dc444f9b0da49dd`
  - This is the exact rev of the host's `nixos-26.05` channel (`/nix/store/8kkak9hmfs1j5h76bpyiv0152j66gs4a-source`,
    `release = 26.05`, `revisionWithDefault = bcc4a9d9533c033d806a46b37dc444f9b0da49dd`).
  - **Locked narHash:** `sha256-K7Dg9TQ0mOcAtWTO/FX/FaprtWQ8BmEXTpLIaNRhEwU=`
    (`lastModified = 1771423170`, i.e. 2026-02-18).
- **Choice rationale:** a concrete, Hydra-built release-branch revision (not a moving
  `unstable` branch). A `nix build --dry-run` of every shell dependency reported
  **"will be fetched"** only (no source builds), so the shell substitutes from
  `cache.nixos.org` quickly. The rev also matches the host's system channel, which is already
  warm locally.
- **Generation:** `nix flake lock` in-place fails because the repo has a `.git/` directory but
  no `git` binary to track the new `flake.nix` ("Path 'flake.nix' … is not tracked by Git").
  Workaround used (no `git` needed, no writes outside a scratch dir):

  ```sh
  TMP=$(mktemp -d /tmp/flakelock.XXXXXX)
  cp flake.nix "$TMP/flake.nix"
  nix flake lock "path:$TMP"
  cp "$TMP/flake.lock" ./flake.lock
  ```

  The lock is content-only (input URL → rev/narHash), so location is irrelevant. Re-running
  `nix flake lock` in the repo will work once `flake.nix`/`flake.lock` are committed.

### Collection pinning approach (Nix-native)

No `ansible-galaxy install` runs on shell entry, and nothing is fetched at lint/syntax-check
time for collections.

- Collection source = `pkgs.python3Packages.ansible` (the **Ansible community distribution
  13.3.0**), a content-addressed Nix derivation whose wheel bundles
  `lib/python3.13/site-packages/ansible_collections/ansible/posix` (2.1.0) and
  `.../community/docker` (5.0.5).
- `ANSIBLE_COLLECTIONS_PATH` is set explicitly to
  `${ansibleCollections}/${pkgs.python3.sitePackages}` so the source is intentional and
  documented.
- Note (documented in the flake): in this nixpkgs rev `ansible-core` already **depends on**
  the community distribution (`pkgs/development/python-modules/ansible/core.nix`), so the
  collections also arrive transitively with the interpreter even without the env var; the
  explicit path pins/documents the intended source regardless.

---

## 3. How to invoke the shell

- **Now** (flake files are in the working tree but not committed, `git` unavailable):
  `nix develop path:.` — the `path:.` installable copies the working tree and does not hide
  the untracked `flake.nix`.
- **After committing** `flake.nix` + `flake.lock`: `nix develop .` works normally.
- **direnv:** `.envrc` now ends with `use flake` (after `dotenv ./.env.dev`). It requires the
  flake files to be committed; until then use `nix develop path:.` (direnv was not installed
  in this environment, so `.envrc` was not executed here).
- Interactive use prints a one-line banner; `nix develop --command …` is intentionally quiet
  (banner guarded on a TTY) so script/agent output stays clean.

Exact caveat evidence (before commit):

```sh
nix develop . --command true
# warning: Git tree '…' is dirty
# error: Path 'flake.nix' in the repository "…" is not tracked by Git.
#        To make it visible to Nix, run:
#        git -C "…" add "flake.nix"
# EXIT=1

nix develop path:. --command python3 -m pytest tests/unit -q
# 52 passed in 0.12s
# EXIT=0
```

---

## 4. Exact commands and results (run with the repo as `workdir`)

All of the following were run and exited 0 unless stated. The `[WARNING]: Ansible is being run
in a world writable directory …` line is an environment artifact (the repo path is mode
`drwxrwxrwx`), not a flake issue.

### 4.1 Unit tests — **PASS**

```sh
nix develop path:. --command python3 -m pytest tests/unit -q
```

```
....................................................                     [100%]
52 passed in 0.12s
```

Also via the Makefile:

```sh
nix develop path:. --command make unit
```

```
platform linux -- Python 3.13.11, pytest-8.4.2, pluggy-1.6.0 -- /nix/store/aalczj797wmfa8pxnjs2623yyq2mhrz5-python3-3.13.11-env/bin/python3
...
============================== 52 passed in 0.12s ==============================
```

### 4.2 `ansible-playbook --version` — **PASS**

```sh
nix develop path:. --command ansible-playbook --version
```

```
ansible-playbook [core 2.20.0]
  ansible python module location = /nix/store/aalczj797wmfa8pxnjs2623yyq2mhrz5-python3-3.13.11-env/lib/python3.13/site-packages/ansible
  ansible collection location = /nix/store/p2sr3j6cild0h3219d1j4azmlqmlh2fd-python3.13-ansible-13.3.0/lib/python3.13/site-packages
  executable location = /nix/store/2yk4y08ngxj9cffk7a8xrkmcr8qr9x8k-python3.13-ansible-core-2.20.0/bin/ansible-playbook
  python version = 3.13.11 ... (/nix/store/aalczj797wmfa8pxnjs2623yyq2mhrz5-python3-3.13.11-env/bin/python3.13)
  jinja version = 3.1.6
  pyyaml version = 6.0.3 (with libyaml v0.2.5)
```

### 4.3 `ansible-lint --version` — **PASS**

```sh
nix develop path:. --command ansible-lint --version
```

```
ansible-lint 25.8.2 using ansible-core:2.20.0 ansible-compat:25.12.0 ruamel-yaml:0.18.16 ruamel-yaml-clib:0.2.14
```

### 4.4 Collections resolvable — **PASS**

```sh
nix develop path:. --command ansible-galaxy collection list
```

```
ansible.posix                            2.1.0
community.docker                         5.0.5
```

Also verified by FQCN docs resolution:

```
ansible-doc community.docker.docker_compose_v2   -> OK
ansible-doc ansible.posix.synchronize            -> OK
```

### 4.5 Real payoff: Layer-1 syntax-check — **PASS**

```sh
nix develop path:. --command ansible-playbook -i hosts.ini deploy-nikolaigogol.yml --syntax-check
# EXIT=0
```

```
playbook: deploy-nikolaigogol.yml
```

### 4.6 `make check` (all four playbooks) — **PASS**

```sh
nix develop path:. --command make check
# EXIT=0
```

```
playbook: ./HomeServer__HomeAssistant.yml
playbook: ./verify-terra.yml
playbook: ./deploy-nikolaigogol.yml
playbook: ./verify-nikolaigogol.yml
```

### 4.7 `nix flake check` — **PASS**

```sh
nix flake check path:.
# EXIT=0
```

```
checking flake output 'devShells'...
checking derivation devShells.x86_64-linux.default...
derivation evaluated to /nix/store/6b04iyzai9pswcg0rwv7ghvici57pmd8-personal-lent-servers-bootstrap.drv
all checks passed!
warning: The check omitted these incompatible systems: aarch64-darwin
```

The `aarch64-darwin` devShell evaluates cleanly when asked directly:

```sh
nix eval path:.#devShells.aarch64-darwin.default.drvPath
# "/nix/store/3s9jrd7pslgxplnj88yv3656rldykprj-personal-lent-servers-bootstrap.drv"
```

### 4.8 `make lint` — **RUNS, exits 2 on pre-existing repo violations**

```sh
nix develop path:. --command make lint
# EXIT=2
```

```
Failed: 6 failure(s), 2 warning(s) on 90 files. Last profile that met the validation criteria was 'min'.
fqcn[canonical]: roles/access_ssh/tasks/main.yml:32  (ansible.builtin.authorized_key -> ansible.posix.authorized_key)
command-instead-of-module: roles/backup_tos/tasks/main.yml:8  (tar -> unarchive)
fqcn[action-core]: roles/bootstrap_base/tasks/main.yml:3  (import_tasks)
fqcn[action-core]: roles/bootstrap_base/tasks/main.yml:6  (import_tasks)
jinja[spacing]: roles/nixos_image_artifact/tasks/main.yml:40,41
yaml[line-length]: roles/nixos_image_artifact/tasks/main.yml:41
command-instead-of-module: verify-terra.yml:17  (systemctl -> systemd)
```

These 6 findings are **pre-existing** in repo-owned files and are out of scope for this task
(fixing them would require editing `roles/**` / playbooks, which the task forbids). The flake
does not introduce them.

---

## 5. `make` target status from the shell

| Target | Status | Notes |
|---|---|---|
| `make unit` | **runnable, green** | 52 passed. |
| `make check` | **runnable, green** | All four `--syntax-check` invocations exit 0. |
| `make lint` | **runnable** (exits 2) | `ansible-lint` executes fully; fails only on the 6 pre-existing violations above. Its pre-run `ansible-galaxy role install` of the external `danielrolls.nix` role needs `git` + network (provided via `pkgs.git`); collections do **not** need network. |
| `make it-*` / `make e2e` | **not provided** | Docker intentionally not included (per task). |

---

## 6. Deviations, unresolved issues, follow-ups

1. **`git` added to the dev shell** (not in the original "minimum" list). Reason:
   `ansible-lint` reads `requirements.yml` and, before linting, runs
   `ansible-galaxy role install -r requirements.yml` for the external
   `danielrolls.nix` role; without `git` this aborts before any linting. With `git` the shell
   is functionally equivalent to the repo's documented `make install` workflow. This installs
   the role into the project-local `.ansible/roles/` (ansible-lint default) — a network
   side effect of `ansible-lint`, not of entering the shell. That directory was cleaned back
   to its empty baseline after testing.
2. **`make lint` cannot be green** without editing forbidden files; reported, not fixed.
3. **Duplicate collection listings**: `ansible-galaxy collection list` lists collections from
   both the merged interpreter env and the community-dist site-packages (they are the same
   derivation). Cosmetic warnings only; FQCN resolution and syntax-check are unaffected.
4. **`nix flake lock` cannot run in-tree** until `flake.nix` is committed (untracked file +
   no `git` binary). Generated in a scratch dir as documented in §2.
5. **Docker** deliberately not provided; `make it-*`/`e2e` remain host-dependent.
6. **World-writable repo dir warning** from Ansible is environmental (mode `drwxrwxrwx`) and
   means Ansible ignores the local `ansible.cfg` unless `ANSIBLE_CONFIG=ansible.cfg` is set
   (the Makefile does set it for `make check`). No change made.

## 7. Working-tree change set (no commits)

```
A  flake.nix
A  flake.lock
M  .envrc
M  .gitignore
M  README.md
A  .agents/build-result-flake-devshell-2026-09-27.md
```

- Input revision: `github:NixOS/nixpkgs/bcc4a9d9533c033d806a46b37dc444f9b0da49dd`
  (`sha256-K7Dg9TQ0mOcAtWTO/FX/FaprtWQ8BmEXTpLIaNRhEwU=`).
- Key store paths referenced by the shell (pinned by the lock):
  - `python3-3.13.11` env `/nix/store/aalczj797wmfa8pxnjs2623yyq2mhrz5-python3-3.13.11-env`
  - `ansible-core-2.20.0` `/nix/store/2yk4y08ngxj9cffk7a8xrkmcr8qr9x8k-python3.13-ansible-core-2.20.0`
  - `ansible-13.3.0` (collections) `/nix/store/p2sr3j6cild0h3219d1j4azmlqmlh2fd-python3.13-ansible-13.3.0`
  - `ansible-lint-25.8.2` `/nix/store/zdxljhv7dcs89hz6fn9q8n5m6phm28b5-ansible-lint-25.8.2`

## 8. Proposed knowledge changes (for Architect/Reporter, not applied)

- In nixpkgs 26.05, top-level `ansible` is `ansible-core` (2.20.0), while the community
  distribution is `python3Packages.ansible` (13.3.0); `ansible-core` **depends on** the
  community distribution, so collections ship transitively with the interpreter.
- `nix flake lock` needs the flake files to be tracked when a `.git/` exists; with no `git`
  binary, lock generation must be done via a scratch `path:` flake.
