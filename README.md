# PersonalLentServers%Russian_dotfiles.bootstrap

## Home Server. Home Assistant

Ansible bootstrap for the home-server stack built around a TerraMaster NAS
(`@terra`). This repository prepares the NAS itself — it installs **Nix** and
**Docker** — and is the foundation the inner hosts are layered on:

| Layer | Host | What it is | Handled by |
|---|---|---|---|
| 0 | `@terra` | TerraMaster NAS running **TOS 6** | this repository (Nix + Docker) |
| 1 | `@NikolaiGogol` | NixOS system container (the reusable Nix "SDK") on `@terra` | this repository (`deploy-nikolaigogol.yml`) |
| 2 | `@Manilov` | HomeAssistant OS VM hosted by `@NikolaiGogol` | roadmap |

`@terra` is the only host reached directly over SSH by default. The inner hosts
are provisioned on top of it; their inventory groups exist so a direct SSH entry
can be added for debugging. The system relationships are drawn in
[`docs/Deploy#NixContainer.puml`](./docs/Deploy#NixContainer.puml); the Ansible
side is described in
[`docs/adr/0001-HomeServer__HomeAssistant.md`](./docs/adr/0001-HomeServer__HomeAssistant.md)
and the rollout plan in
[`docs/HomeServer__HomeAssistant_plan.md`](./docs/HomeServer__HomeAssistant_plan.md).

### What gets deployed on `@terra`

The playbook runs these roles in order:

1. **`backup_tos`** — snapshots the whole `/etc` configuration (plus a separate
   credentials archive and in-archive DB dumps) and pulls it to
   `backups/<host>/` on the control node. This always runs first.
2. **`access_ssh`** — generates the deployment keypair on the control node,
   uploads its public key and verifies key-based login (idempotent). To reuse an
   already-deployed key instead, see
   [`docs/AccessSsh_ExistingKey.md`](./docs/AccessSsh_ExistingKey.md).
3. **`access_sftp`** — installs `openssh-sftp-server` when the binary referenced
   by TOS 6's `sshd_config` is missing, so Ansible uses the fast `sftp` transfer
   instead of silently falling back to `piped`.
4. **`bootstrap_base`** — installs only the commands the Nix installer needs
   (`curl`, `xz`, …) if they are missing, and refuses to continue on xz versions
   affected by CVE-2024-3094 (5.6.0 / 5.6.1).
5. **`bootstrap_nix`** — installs the Nix package manager (multi-user, systemd)
   via the pinned `danielrolls.nix` role and enables `nix-command` + `flakes`.
6. **`bootstrap_docker`** — detects the Docker shipped with TOS 6 and only
   installs Docker CE (Ubuntu `jammy` repo) when it is missing. This is a
   host-side fallback for the NAS rootfs and is independent of the NixOS
   system-container image, which is imported as a prebuilt tar.

### Prerequisites on `@terra`

Before the first run, on the NAS:

- A storage pool and volumes are configured (already the case).
- **SSH is enabled**: Control Panel → Network Services → Terminal & SNMP.
- An admin account exists (here named `terra`; TOS 6 makes the first account a
  superuser, uid 0). TOS 6 keeps a separate `root` account that is **uid 9999 and
  unprivileged**, so the play runs with `ansible_become: false` and never
  sudo-escalates to `root` (doing so would *drop* privileges and break apt).
- Security Isolation Mode is **off** — it disables SSH.

### Configure

1. Point the inventory at the device. `hosts.ini` uses the hostname
   `terra-local`; the connection host comes from the inventory, so set
   `ansible_host` in `group_vars/terra/vars.yml` only if that name does not
   resolve from the control node.

   Easiest way to check is to ssh to the host: `ssh terra@terra-local` (or `ssh
   terra@terra` when the short name resolves). If you already have a key
   deployed, see
   [`docs/AccessSsh_ExistingKey.md`](./docs/AccessSsh_ExistingKey.md) for the
   checks and the variables to reuse it.

2. Create the host vault and set the admin password (used for sudo, and for the
   very first password-based connection on a device with no key yet):

   ```sh
   make vault-edit-terra
   ```

   Required variable:

   - vault_terra_admin_password — the TOS admin password (also used for
     sudo; required even when SSH is key-based). If the password contains a
     double quote ("), escape it with a backslash (\") or wrap the value in
     single quotes.

Review the other knobs in [`group_vars/terra/vars.yml`](./group_vars/terra/vars.yml).
Role defaults (declarations) live in each role's `defaults/main.yml`.

### Deploy

```sh
make install      # install the pinned galaxy role + collections
make run-terra    # runs HomeServer__HomeAssistant.yml (all tags)
```

To run a subset, select tags:

```sh
make run TAGS=nix
make run TAGS=docker
make run TAGS=backup
```

`bin/dot-bootstrap` is the wrapper behind `make run`: it takes a playbook and a
tag selector, and offers to install Ansible if it is missing.

#### Run logs

Every ansible-running `make` target is logged through `bin/run-log`: combined
output goes to `logs/<timestamp>-<tag>.log`, with `logs/latest.log` pointing at
the newest run (`logs/` is git-ignored). Terminal highlighting is preserved
(`ANSIBLE_FORCE_COLOR`, overridable with `ANSIBLE_FORCE_COLOR=0`); the stored log
is stripped of ANSI codes. Log an ad-hoc command with:

```sh
make run-log CMD='ansible-playbook ...'
```

### Verify and test

```sh
make test         # verify-terra.yml against @terra (nix, docker CLI, daemon)
make check        # syntax-check the playbooks
make lint         # ansible-lint
make unit         # repository + role unit tests (tests/unit)
```

A re-run of `make run-terra` on an already-bootstrapped device should report no
changes, which is the idempotency guarantee the layered model relies on.

#### Development shell (Nix flake)

A pinned dev shell provides the test/lint tooling without depending on the host:

```sh
nix develop .            # or `nix develop path:.` before flake.nix is committed
make unit                # 57 unit tests
make check               # syntax-check all four playbooks
make lint                # ansible-lint
```

It pins nixpkgs through `flake.lock` and bundles Python 3.13 with
pytest/PyYAML/Jinja2, `ansible-core`, `ansible-lint`, `invoke` (the shared
content-tag command, below), and the `ansible.posix` / `community.docker`
collections. Docker is intentionally not provided, so the `make it-*` and
`make e2e` targets still need a Docker host; `ansible-lint` fetches the external
`danielrolls.nix` role (git + network) on first run.

To exercise the roles without touching the NAS, run them against a mock `@terra`
(Ubuntu-22.04 systemd container):

```sh
make it-up        # build + start the mock target (ssh on 127.0.0.1:2222)
make it-run       # run the roles against tests/integration/inventory.ini
make it-shell     # interactive shell inside the mock target
make it-down
```

Each step also has a small makefile for manual testing (mixed human/agent
targets — `run`, `dry`, `verify`, `shell`, `shell-ssh`, `logs`):

```sh
make -f Makefile.BackupTos help
make -f Makefile.AccessSsh help
make -f Makefile.NixBootstrap help
make -f Makefile.DockerDeployment help
```

See [`tests/README.md`](./tests/README.md) for the four testing layers (unit,
integration, E2E, manual) and
[`docs/HomeServer__HomeAssistant_plan.md`](./docs/HomeServer__HomeAssistant_plan.md)
for the per-step test matrix.

### Layer 1 — `@NikolaiGogol` (NixOS system container)

`deploy-nikolaigogol.yml` takes the NixOS system-container rootfs built on the
workstation, pushes it to `@terra`, imports it into Docker and starts it as a
privileged systemd container (the same container
`ConvPlatProv-HomeServer__HomeAssistant/@NikolaiGogol` starts by hand).

It is content-addressed: the image tag is the first 12 hex characters of the
tarball's sha256, so "is this image present?" is meaningful and a re-run is a
no-op when nothing changed.

**Tag parity with local testing.** The tag is produced by one shared command —
`invoke --search-root=~/.bookmarks/shared-scripts conv-plat-prov.content-tag` —
so this deploy, `Unix_dotfiles` (`make image-tag-NikolaiGogol`) and the
`@NikolaiGogol` repo (`make import-nixos`, which also keeps a `:latest` alias)
compute the same tag; the role asserts its result equals the artifact checksum
slice. `invoke` is provided by the dev shell, and real deploys require it
(`nixos_image_artifact_content_tag_required: true` in `group_vars`).

Roles, in order, by tag:

- `image` — `nixos_image_artifact` (locate + checksum the artifact on the
  control node; derive the tag via the shared command) → `nixos_image_sync`
  (rsync `--checksum` to
  `/var/tmp/nixos-images/<sha256>.tar.xz`) → `nixos_image_load` (`docker import`
  gated on `docker image inspect`).
- `container` — `nixos_container` (render `docker-compose-system.yml` + `.env`
  from `group_vars/nikolaigogol/vars.yml`, ensure the mount sources, `docker
  compose up -d`; a handler recreates the container when the config changes).
- `edge_sync` — optional, **off by default** fast-iteration helper (see below).

**Prerequisites**

- The image build on the workstation (control node):
  `make --directory=~/.bookmarks/shared-configs/Unix_dotfiles build-NikolaiGogol`
  → `result-NikolaiGogol/tarball/nixos-system-x86_64-linux.tar.xz`.
- `rsync` on `@terra` (the role can install it via apt with
  `nixos_image_sync_install_rsync=true`, otherwise it fails early with guidance).
- Review `group_vars/nikolaigogol/vars.yml` — the mount roots are placeholders
  until the real TOS volume layout is confirmed.

**Two speeds, both idempotent**

```sh
# Fast loop while iterating: edit Unix_dotfiles, rebuild, redeploy only what
# changed. A new sha tag triggers import + recreate; nothing else changes.
make --directory=~/.bookmarks/shared-configs/Unix_dotfiles build-NikolaiGogol
make -f Makefile.NixosImage run
make -f Makefile.NixosContainer run

# Whole layer, no-op when already converged
make -f Makefile.NixosImage run
make -f Makefile.NixosContainer run
```

The per-step makefiles are thin wrappers over `deploy-nikolaigogol.yml`
(`STEP_TAGS := image` / `container`). They accept the shared targets
(`run`, `dry`, `verify`, `up`, `down`, `shell-ssh`, `logs`, `clean`) and
`INVENTORY=tests/integration/inventory.ini` for the mock. `Makefile.NixosContainer`
adds `connect-container`, `ssh-container` and `ps`.

**Verify and connect**

```sh
make -f Makefile.NixosContainer verify          # verify-nikolaigogol.yml
make -f Makefile.NixosContainer connect-container  # shell inside the container
make -f Makefile.NixosContainer ssh-container      # direct SSH (port 2223)
```

`make check` syntax-checks both Layer-0 and Layer-1 playbooks.

**Optional edge iteration (`nixos_edge_sync`, off by default)**

If you decide the TOS host needs it, this helper rsyncs the local
`Unix_dotfiles` checkout into the container's bind mount and runs
`nixos-rebuild switch --flake` inside the running container:

```sh
make -f Makefile.NixosEdgeSync run EXTRA_ARGS='-e nixos_edge_sync_enabled=true'
```

It is inert unless `nixos_edge_sync_enabled=true`; the canonical path stays
"rebuild the artifact, redeploy".

See
[`docs/HomeServer__StratoFrame__ConvPlatProv__NikolaiGogolDeployment_plan.md`](./docs/HomeServer__StratoFrame__ConvPlatProv__NikolaiGogolDeployment_plan.md)
for the full plan, testing matrix and rollback.

### Backups

`backup_tos` runs first and snapshots the **whole `/etc` tree** (anchored vendor
excludes, `--one-file-system`) into a timestamped config archive under
`backups/<host>/`. Out-of-`/etc` extras (cron, Samba private), in-archive
database dumps (PostgreSQL logical dump on port `5032`, SQLite `.backup`
snapshots) and the enabled systemd-unit state are folded in, and a manifest with
checksums and member counts is written next to the archive.

Credential material (shadow/gshadow, SSH host keys, TLS private keys, Samba
secrets) is captured into a **separate** `<host>-tos-secrets-<ts>.tar.gz` under
`backups/<host>/secrets/` (`0700` directory, `0600` files), gated by
`backup_tos_include_secrets`. This is a *configuration* backup, not a block-level
image: `/Volume1` state data is **out of scope**. `@Manilov` (HAOS VM) is still
roadmap, so its state is not covered by this role either. For risky changes pair
it with TerraMaster's own configuration export; `backups/` is git-ignored and
must never be committed.

### Inner hosts (roadmap)

Layer 1 (`@NikolaiGogol`) is implemented by `deploy-nikolaigogol.yml` (see
above). `@Manilov` (HomeAssistant OS VM) is still roadmap; its inventory group
and placeholder variables (`group_vars/manilov/`) exist so the next stage can be
added as a separate idempotent play; see the plan.

### Repository layout

```
HomeServer__HomeAssistant.yml   # Layer-0 playbook for @terra
deploy-nikolaigogol.yml         # Layer-1 playbook: NixOS system container
verify-terra.yml                # idempotent Layer-0 checks
verify-nikolaigogol.yml         # idempotent Layer-1 checks
hosts.ini                       # local / terra / nikolaigogol / manilov
group_vars/<host>/              # per-host values (+ encrypted vault)
roles/backup_tos/               # snapshot TOS config before changes
roles/access_ssh/               # key-based SSH access
roles/access_sftp/              # restore the sshd SFTP server binary (TOS 6)
roles/bootstrap_base/           # minimal base prerequisites
roles/bootstrap_nix/            # Nix (multi-user)
roles/bootstrap_docker/         # Docker detection / install
roles/nixos_image_artifact/     # locate + checksum the image on the control node
roles/nixos_image_sync/         # rsync the artifact to @terra
roles/nixos_image_load/         # docker import on @terra
roles/nixos_container/          # compose + env + mount/container lifecycle
roles/nixos_edge_sync/          # optional fast-iteration helper (off by default)
tests/                          # unit + integration tests (see tests/README.md)
Makefile.Steps                  # shared manual-test targets
Makefile.<Step>                 # per-step manual testing
docs/                           # diagram, ADR, rollout plan, existing-key guide
```

### Secrets

Never commit decrypted vaults, private keys, or backup archives. The vault
password file (`.vault_pass.py`) is git-ignored and derived from
`.vault_pass_example.py`; `backups/` is git-ignored too.
