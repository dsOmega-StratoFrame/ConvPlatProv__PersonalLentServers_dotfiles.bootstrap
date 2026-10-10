# Access via an already-deployed SSH key

By default the `access_ssh` role **generates a deployment keypair** on the
control node and uploads its public half to the target account. If you already
have a working key for that account, you can skip generation/upload and let the
playbook reuse your key.

Use this path once `ssh <user>@<host>` already works from the control node — for
example `@terra`, where the `terra` account is reached as `terra-local` on port
`9222` (see `~/.ssh/config`).

This is an alternative to the default first-contact flow; the default
(password → key upload) still applies on a fresh device that has no key yet.

## How the pieces fit

One variable, `deploy_ssh_private_key_file`, drives both sides:

| Consumer | Effect |
|---|---|
| `ansible_ssh_private_key_file` (in `group_vars/terra/vars.yml`) | the key the Ansible connection uses |
| `access_ssh_private_key_file` (role default) | the key `access_ssh` checks/uses |

`access_ssh_generate_key: false` disables keypair creation, and a blank
`access_ssh_password` disables the password-based `authorized_key` upload. The
role then only **verifies** that key login works.

`vault_terra_admin_password` is **retained but not needed for routine
escalation**: on TOS 6 `terra` is already uid 0 and the play runs with
`ansible_become: false` / `ansible_become_user: "terra"` (see
[`HomeServer__HomeAssistant_plan.md`](./HomeServer__HomeAssistant_plan.md) §3, assumption 4
and [`adr/0003-Tos6PrivilegeModel.md`](./adr/0003-Tos6PrivilegeModel.md)).
It feeds `ansible_become_password` for the keyless first-contact flow and for a
forced-`become` task, not for ordinary sudo. A key replaces the SSH password,
never the vault entry.

## Prerequisites

1. **Key file on the control node.** The private key exists at
   `deploy_ssh_private_key_file`, and its `.pub` sibling exists next to it
   (`access_ssh_public_key` looks it up; needed if the password upload path ever
   runs).
2. **Key authorized on the target.** The public key is in the target account's
   `~/.ssh/authorized_keys`.
3. **Key usable non-interactively.**
   - If the key is passphrase-protected, it must be loaded in `ssh-agent`, the
     agent must be reachable by the process that runs `ansible-playbook`
     (`SSH_AUTH_SOCK` exported), and it must **not** be added with
     `ssh-add -c` (confirm-on-use) — the role's checks run `ssh -o BatchMode=yes`
     and cannot answer a prompt.
   - An unencrypted key file works without an agent.
4. **Host resolves / is trusted.** The inventory host (`terra-local`) resolves
   on the control node, and the host key is in `known_hosts` (or host-key
   checking is configured).
5. **`sshpass` only if you keep a transport password.** Key-only transport does
   not need it. It is required if `ansible_password` is set, because Ansible
   wraps the `ssh` invocation with `sshpass`.
6. **Vault password set** (`vault_terra_admin_password`) only if you use the
   keyless password path or a forced-`become` task. Routine runs need no sudo:
   `terra` is uid 0 and `ansible_become: false`.

## Checks (bash)

Run these on the control node before a live run. They are read-only.

```bash
# --- edit these three to match your host/key -------------------------------
TARGET_USER="terra"
TARGET_HOST="terra-local"
KEY="$HOME/.ssh/Lent__terra-HomeServer__HomeAssistant-local"
# ---------------------------------------------------------------------------

# 1. Tools present.
command -v ssh ssh-keygen ansible-playbook
command -v sshpass || echo "sshpass missing (only needed if ansible_password is set)"

# 2. Private key + public key exist.
ls -la "$KEY" "$KEY.pub"

# 3. Agent reachable? Key listed, and not added with `ssh-add -c`.
echo "SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-unset}"
ssh-add -l

# 4. Key login works without prompts.
ssh -o BatchMode=yes -i "$KEY" "${TARGET_USER}@${TARGET_HOST}" 'echo OK'

# 5. SSH config for the target (port, User, IdentityFile, IdentitiesOnly).
grep -A5 -E "^Host .*${TARGET_HOST}" "$HOME/.ssh/config"

# 6. The real test: the host Ansible will actually connect to.
#    (fails if ansible_host does not resolve)
ansible -i hosts.ini terra -m ansible.builtin.ping
```

Expected: step 4 prints `OK`; step 6 prints `pong` with no password prompt.
Step 4 only proves *your* shell can log in — step 6 is the one that matches what
the playbook does.

## Variables to change

In `group_vars/terra/vars.yml`:

```yaml
# Reuse an existing key instead of generating one.
deploy_ssh_private_key_file: "~/.ssh/<your-existing-key>"
access_ssh_generate_key: false

# Key-only SSH transport; the vault password is retained only for a forced
# become task (TOS 6 needs no routine sudo; see plan §3, assumption 4).
# Remove/blank ansible_password (if present) and set:
access_ssh_password: ""
```

The connection host is taken from the inventory, so `ansible_host` is **not**
set. Add `ansible_host: "<name>"` only if the inventory name (`terra-local`) does
not resolve from the control node.

`ansible_become_password: "{{ vault_terra_admin_password | default(omit) }}"`
and the `vault_terra_admin_password` entry in `group_vars/terra/vault` are
retained defensively, but are not used for routine runs (`ansible_become: false`).

## Run and verify

```sh
make check                                                        # syntax
ansible -i hosts.ini terra -m ansible.builtin.ping                # reachability
make run TAGS=access                                              # verify key login
make run TAGS=backup                                              # first mutating step
```

When the key check passes, the `access_ssh` upload task reports **skipped** and
a re-run reports no changes — that is the idempotency guarantee.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Permission denied (publickey)` in step 4 | key not in `authorized_keys`, or agent not reachable (`SSH_AUTH_SOCK` unset in this shell) |
| Step 4 hangs, then fails | key added with `ssh-add -c`, or agent locked |
| Step 6 fails while step 4 passes | `ansible_host` points at a name that doesn't resolve, or `~/.ssh/config` isn't read by the Ansible connection |
| Ansible: "install the sshpass program" | `ansible_password` still set but `sshpass` missing — blank the transport password or install `sshpass` |
| `access_ssh` fails, "no access_ssh_password was provided" | key check failed and the password upload path is disabled — fix key access, temporarily set `access_ssh_password`, or re-enable `access_ssh_generate_key` |
| `lookup('file', ...+'.pub')` error | `.pub` is not next to the private key |

## Security notes

- Never commit private keys. `backups/`, `tests/artifacts/` and private keys are
  git-ignored; keep it that way.
- A `.pub` is not secret, but it should not be committed either.
- Prefer key-only transport (no `ansible_password`) and keep the admin password
  in the vault for the keyless first-contact and forced-`become` paths; routine
  runs need no sudo.
