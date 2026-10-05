# Analyst handoff — Logseq journal entry for 2026-09-27

> Scratch handoff. This is **not** repository documentation. It exists so a
> **directly-invoked** `@analyst` (top-level session, where the `logseq-analyst*`
> MCP tools bind) can publish the note to Logseq. Safe to delete after publishing.

## Task for the analyst

Publish the content below to Logseq, following the normal analyst → `analyst-kbn`
journaling workflow:

- **Dedicated page:** `ai-anl Analyst_system/SSH key, xz, and jammy considerations — PersonalLentServers bootstrap`
- **Journal entry:** `ai-anl Analyst_system/_journals/2026-09-27` → `Updated [[ai-anl Analyst_system/SSH key, xz, and jammy considerations — PersonalLentServers bootstrap]]` + simplified copy
- **Optional planner publish:** `ai-pln Planner_system/SSH key, xz, and jammy considerations — PersonalLentServers bootstrap`

Do **not** modify the code repository. A previous Task-nested analyst session
could not bind the Logseq MCP tools; this handoff is the workaround.

---

## Content to publish

**Title:** SSH key, xz, and jammy considerations — PersonalLentServers bootstrap

- Layer-0 Ansible bootstrap for TerraMaster NAS `@terra` (TOS 6, Ubuntu-22.04-compatible rootfs).
  - Repo: `PersonalLentServers%Russian_dotfiles.bootstrap`
  - Path: `/usr/local/darkGreen-/tangerineDream/shared-Projects/ChronoIndex/2026/PersonalLentServers%Russian_dotfiles.bootstrap`
  - Roles: `backup_tos → access_ssh → bootstrap_base → bootstrap_nix → bootstrap_docker`
  - Playbook `HomeServer__HomeAssistant.yml`; inventory `hosts.ini` (host `terra-local`, group `terra`)
  - Captured from a review + build on 2026-09-27

### SSH key considerations
- Three distinct authentication planes (commonly confused):
  1. interactive SSH — operator's personal key / ssh-agent;
  2. Ansible transport — `ansible_ssh_private_key_file` ← `deploy_ssh_private_key_file`, falling back to `ansible_password`;
  3. sudo — `ansible_become_password` ← `vault_terra_admin_password`, **independent of SSH keys**.
- Already-deployed-key path (`group_vars/terra/vars.yml`):
  - `deploy_ssh_private_key_file: "~/.ssh/Lent__terra-HomeServer__HomeAssistant-local"`
  - `access_ssh_generate_key: false`
  - `access_ssh_password: ""`
  - remove/blank `ansible_password` → key-only transport, avoids the `sshpass` dependency
  - **keep** `ansible_become_password` — sudo still needs the admin password
- `ansible_host: "terra"` was **removed** so the connection host comes from the inventory (`terra-local`).
  - `ansible_host` overrides the inventory hostname. The trap: manual `ssh terra@terra-local` worked, but the play would have connected to `terra`.
- Control-node `~/.ssh/config` maps both `Host terra` and `Host terra-local` → Port 9222, with no `IdentitiesOnly`/`IdentityFile` overrides (agent keys usable).
- A passphrase-protected key works if it is loaded in `ssh-agent`, `SSH_AUTH_SOCK` is reachable by the `ansible-playbook` process, and it is **not** added with `ssh-add -c` (role checks use `ssh -o BatchMode=yes`, which cannot answer a prompt).
- `access_ssh_public_key` does `lookup('file', <key> + '.pub')` → the `.pub` must exist beside the private key.
- `sshpass` is required only if `ansible_password` is set; Ansible wraps `ssh` with `sshpass` whenever a transport password is present, even if the agent key would work.
- New guide `docs/AccessSsh_ExistingKey.md`: prerequisites; checks (`command -v sshpass`, `ssh-add -l`, `SSH_AUTH_SOCK`, `ssh -o BatchMode=yes -i <key> terra@terra-local 'echo OK'`, `grep -A5 '^Host ' ~/.ssh/config`, `ansible -i hosts.ini terra -m ansible.builtin.ping`); variables to change; troubleshooting.
  - `ansible -i hosts.ini terra -m ansible.builtin.ping` is the only check that matches what the playbook actually does.

### xz considerations (CVE-2024-3094)
- `roles/bootstrap_base` requires the `xz` command and installs `xz-utils` (Debian-family) / `xz` (fallback) — needed because the Nix installer extracts a `.tar.xz`.
- CVE-2024-3094 ("xz backdoor") shipped in upstream xz **5.6.0 and 5.6.1**.
  - Ubuntu 22.04 / TOS 6 (jammy) ships **5.2.5** → not affected.
  - Distro rebuilds report the reverted runtime version (Debian `5.6.1+really5.4.5` runs as `5.4.5`).
- Fail-closed guard added:
  - `bootstrap_base_xz_blocked_versions: ["5.6.0", "5.6.1"]` in `roles/bootstrap_base/defaults/main.yml`
  - `roles/bootstrap_base/tasks/dependencies.yml` runs `xz --version` and fails on a blocked version; also reports the version in use.
- Design rationale: gate on the **runtime** `xz --version` string, **not** the apt candidate version — the candidate can read `5.6.1+really5.4.5-1` (a safe rebuild) and would false-positive.
- Unit test `tests/unit/test_base_step.py` renders the exact `when:` expression (5.2.5/5.4.5 pass; 5.6.0/5.6.1 fail).

### jammy apt registry considerations
- `bootstrap_docker_apt_suite: "jammy"` is the Docker CE apt repository suite used **on the host `@terra`** (TOS 6 = Ubuntu-22.04-compatible), and only in the fallback install path when Docker is missing (`bootstrap_docker_install_method: detect|apt`; `manual` fails with App Center guidance instead).
- It is **independent of the NixOS system-container workload image**: that image is built in the `Unix_dotfiles` repo, exported as a tar, `docker load`-ed onto the NAS and run privileged with systemd (`command: /init`) — it does not come from apt and does not use `jammy`.
- Two-OS distinction to remember:
  - NAS host `@terra` = TOS 6, apt-based; managed by this repo.
  - Workload = prebuilt NixOS image (layer 1, roadmap; cf. `@tangerineDream` + `docker-image.yaml` flow).
- Decision recorded 2026-09-27: **keep `detect` + apt fallback** — Docker on `terra` may also run other images; the fallback is inert when TOS App Center Docker is present, so it costs nothing.
  - Rejected for now: verify-only `manual` mode; dropping the Nix-on-host layer; adding a Layer-1 prebuilt-image deploy role.
- Docs: the README role list was updated to clarify the `jammy` path is host-side and independent of the NixOS image.

### Open questions / to verify
- Verify `ansible -i hosts.ini terra -m ansible.builtin.ping` against the **real control node** (only check matching actual playbook behavior; not validatable from the container).
- Run `make unit` to exercise `tests/unit/test_base_step.py` and the repo structure tests.
- Confirm `~/.ssh/Lent__terra-HomeServer__HomeAssistant-local.pub` exists and the passphrase key is in `ssh-agent` without `ssh-add -c`, on the actual operator machine.
- Whether a Layer-1 prebuilt NixOS image deploy role should be added (deferred 2026-09-27).
