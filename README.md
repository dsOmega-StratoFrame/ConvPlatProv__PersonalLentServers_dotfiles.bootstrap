# PersonalLentServers%Russian_dotfiles.bootstrap

## Home Server. Home Assistant

Ansible bootstrap for the home-server stack built around a TerraMaster NAS
(`@terra`). This repository prepares the NAS itself — it installs **Nix** and
**Docker** — and is the foundation the inner hosts are layered on:

| Layer | Host | What it is | Handled by |
|---|---|---|---|
| 0 | `@terra` | TerraMaster NAS running **TOS 6** | this repository (Nix + Docker) |
| 1 | `@NikolaiGogol` | NixOS system container (the reusable Nix "SDK") on `@terra` | roadmap |
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

1. **`backup_tos`** — snapshots the TOS system configuration and pulls the
   archive to `backups/<host>/` on the control node. This always runs first.
2. **`access_ssh`** — generates the deployment keypair on the control node,
   uploads its public key and verifies key-based login (idempotent). To reuse an
   already-deployed key instead, see
   [`docs/AccessSsh_ExistingKey.md`](./docs/AccessSsh_ExistingKey.md).
3. **`bootstrap_base`** — installs only the commands the Nix installer needs
   (`curl`, `xz`, …) if they are missing.
4. **`bootstrap_nix`** — installs the Nix package manager (multi-user, systemd)
   via the pinned `danielrolls.nix` role and enables `nix-command` + `flakes`.
5. **`bootstrap_docker`** — detects the Docker shipped with TOS 6 and only
   installs Docker CE (Ubuntu `jammy` repo) when it is missing.

### Prerequisites on `@terra`

Before the first run, on the NAS:

- A storage pool and volumes are configured (already the case).
- **SSH is enabled**: Control Panel → Network Services → Terminal & SNMP.
- An admin account exists (here named `terra`; TOS 6 makes the first account a
  superuser).
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

### Verify and test

```sh
make test         # verify-terra.yml against @terra (nix, docker CLI, daemon)
make check        # syntax-check the playbooks
make lint         # ansible-lint
make unit         # repository + role unit tests (tests/unit)
```

A re-run of `make run-terra` on an already-bootstrapped device should report no
changes, which is the idempotency guarantee the layered model relies on.

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

### Backups

`backup_tos` writes a timestamped archive and manifest under
`backups/<host>/` (git-ignored). It is a *configuration* backup — system files
such as `/etc/fstab`, `mdadm` config, network config and systemd units — not a
block-level image of the TOS system disk. For risky changes, pair it with
TerraMaster's own configuration export.

### Inner hosts (roadmap)

`@NikolaiGogol` and `@Manilov` are not deployed yet. Their inventory groups and
placeholder variables (`group_vars/nikolaigogol/`, `group_vars/manilov/`) exist
so the next stages can be added as separate idempotent plays; see the plan.

### Repository layout

```
HomeServer__HomeAssistant.yml   # Layer-0 playbook for @terra
verify-terra.yml                # idempotent checks
hosts.ini                       # local / terra / nikolaigogol / manilov
group_vars/<host>/              # per-host values (+ encrypted vault)
roles/backup_tos/               # snapshot TOS config before changes
roles/access_ssh/               # key-based SSH access
roles/bootstrap_base/           # minimal base prerequisites
roles/bootstrap_nix/            # Nix (multi-user)
roles/bootstrap_docker/         # Docker detection / install
tests/                          # unit + integration tests (see tests/README.md)
Makefile.Steps                  # shared manual-test targets
Makefile.<Step>                 # per-step manual testing
docs/                           # diagram, ADR, rollout plan, existing-key guide
```

### Secrets

Never commit decrypted vaults, private keys, or backup archives. The vault
password file (`.vault_pass.py`) is git-ignored and derived from
`.vault_pass_example.py`; `backups/` is git-ignored too.
