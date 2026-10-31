# Handoff — clean reinstall of Nix on @terra (Option B)

- Task: `NIX-TERRA-001`
- Date: 2026-10-31
- Orchestrator record: Logseq `ai-orc Orchestrator_system/NIX-TERRA-001 orchestration-record`
- Repo: `PersonalLentServers%Russian_dotfiles.bootstrap`
- Target: inventory host `terra-local` (TOS 6 NAS; ssh user `terra`, uid 0)
- Status: **approved, not executed**

## Why

`roles/bootstrap_nix` succeeded on 2026-10-10 and installed Nix 2.34.7 into
`/nix` on the **root filesystem** (`/dev/md9`). On 2026-10-11 `roles/zterra_binds`
created an empty noCoW subvolume `/zterra/local-/nix` and bind-mounted it over
`/nix` (`nix.mount`, `Before=nix-daemon.service`). The real store (77 paths) is
still intact but hidden on `md9`; `/nix` is now an empty btrfs subvolume and
`nix` is gone from `PATH`. `nix-daemon.service` / `.socket` are dangling
symlinks into the hidden store and will not start after the next boot.

The operator chose **Option B**: discard the stale store and reinstall fresh.
There is no meaningful Nix data on the host.

## Scope

Allowed:

1. Stop/kill the stale `nix-daemon` and remove `nix.mount`.
2. Delete the old Nix store on `md9`.
3. Re-create the `/nix` bind via the `binds` tag.
4. Run the `nix` tag to install Nix fresh.
5. Read-only verification.

Not allowed:

- `--tags all`, `backup_tos`, Docker, `zterra_mount`/`zterra_layout` provisioning.
- Rebooting the NAS.
- Repo edits or commits.
- Migrating/keeping the old store (operator chose B).

## Preconditions (control node)

- Repo checked out at the path above; `ansible` and `ansible-playbook` available.
- `ansible-galaxy role list | grep danielrolls.nix` shows the pinned role; if
  not, `make install` (network).
- `.vault_pass.py` present and able to decrypt `group_vars/terra/vault`
  (do not print the file or the vault).
- SSH: `ssh terra@terra-local 'id -u'` prints `0`.
- Host can reach `releases.nixos.org` and `cache.nixos.org` (verified 2026-10-31:
  HTTP 200). Re-check with `curl -sS -o /dev/null -w '%{http_code}\n' URL`.

If any precondition fails, stop and report; do not improvise.

## Phase 0 — teardown (destructive, approved)

Run on the host as `terra` (uid 0; **no sudo** — the separate `root` account is
uid 9999 and unprivileged):

```bash
set -u

# 0.1 stop the stale daemon; its unit file is a dangling symlink, so stop the
#     process explicitly if systemctl cannot.
systemctl stop nix-daemon.service nix-daemon.socket 2>/dev/null || true
pkill -TERM -x nix-daemon 2>/dev/null || true
sleep 1
if pgrep -a nix-daemon; then echo "nix-daemon still alive"; exit 1; fi

# 0.2 unmount /nix and remove the shadowing unit
systemctl disable --now nix.mount
rm -f /etc/systemd/system/nix.mount
systemctl daemon-reload
systemctl reset-failed nix.mount 2>/dev/null || true

# 0.3 the old store is visible again on md9
findmnt -T /nix || echo "not a mountpoint (expected)"
ls /nix/store | wc -l          # expected non-zero (about 76 store paths)
ls /nix/var/nix/profiles/default/bin/nix

# 0.4 delete the stale store
rm -rf /nix/store /nix/var /nix/receipt.json
find /nix -mindepth 1 -maxdepth 1 -exec rm -rf {} +
ls -la /nix                    # expected empty

# 0.5 remove dangling installer unit symlinks
rm -f /etc/systemd/system/nix-daemon.service \
      /etc/systemd/system/nix-daemon.socket \
      /etc/systemd/system/sockets.target.wants/nix-daemon.socket
systemctl daemon-reload
systemctl reset-failed

# 0.6 bind source must be empty
ls -la /zterra/local-/nix      # expected empty
findmnt -T /zterra -o TARGET,SOURCE,FSTYPE
```

If the unmount fails `EBUSY`: `pgrep -a nix-daemon`, kill it, retry. Avoid
`umount -l`; if you must use it, report it.

## Phase 1 — re-bind and install

From the repo root on the control node:

```bash
# 1.1 syntax check
ANSIBLE_CONFIG=ansible.cfg ansible-playbook -i hosts.ini \
  HomeServer__HomeAssistant.yml --syntax-check

# 1.2 recreate nix.mount only (zterra_mount/layout are already converged)
ANSIBLE_CONFIG=ansible.cfg ANSIBLE_ROLES_PATH="$PWD/roles" \
  ansible-playbook -i hosts.ini HomeServer__HomeAssistant.yml --tags binds -v

# 1.3 /nix must now be the zterra subvolume and empty
ssh terra@terra-local 'findmnt -T /nix -o TARGET,SOURCE,FSTYPE; stat -c "%d %n" /nix /zterra/local-/nix'

# 1.4 fresh install through the role under test
make -f Makefile.NixBootstrap run
# equivalent: ansible-playbook -i hosts.ini HomeServer__HomeAssistant.yml --tags nix -v
```

### Known failure mode: capture it, do not hack around it

On 2026-10-10 the first install run died *after* a successful install at
`danielrolls.nix : nix_commands` with `nix: command not found` (rc 127); a
second run passed. The current role injects `bootstrap_nix_env_path` for this.

If the installer completes but the smoke item fails with rc 127:

- do **not** edit the role or the host ad hoc;
- re-run `make -f Makefile.NixBootstrap run` once;
- record both logs and report it as a finding (role defect F4/F5 below).

## Acceptance (all must pass)

```bash
ssh terra@terra-local '
  findmnt -T /nix -o TARGET,SOURCE,FSTYPE
  test "$(stat -c %d /nix)" = "$(stat -c %d /zterra/local-/nix)" && echo SAME_FS
  ls /nix/store | wc -l
  /nix/var/nix/profiles/default/bin/nix --version
  /nix/var/nix/profiles/default/bin/nix flake --help >/dev/null && echo FLAKES_OK
  systemctl is-enabled nix-daemon
  systemctl is-active nix-daemon
  test -e /etc/systemd/system/nix-daemon.service && echo UNIT_RESOLVES
  cat /etc/nix/nix.conf
'
```

Expected: `/nix` on `...nvme-1-part4[/local-/nix]`, `SAME_FS`, store count > 0,
`nix (Nix) 2.x`, `enabled`, `active`, `UNIT_RESOLVES`.

Idempotence (required):

```bash
make -f Makefile.NixBootstrap run     # second run: install skipped, changed=0
make -f Makefile.NixBootstrap verify  # nix/docker/daemon report
```

## Return (result manifest)

- Timestamped log paths under `logs/` for the binds run, both nix runs, verify.
- Recap lines (`failed=`, `changed=`) for each.
- The acceptance command output verbatim.
- Whether the first install run hit the rc 127 smoke-test issue.
- Any deviation from this runbook.

## Follow-ups (do not implement here)

Role hardening, for a builder with tests:

- store-based install gate instead of `command -v nix`
  (`roles/bootstrap_nix/tasks/main.yml:4-9`);
- fail-fast when `/nix` is a mountpoint on an empty source;
- post-install asserts: store non-empty, daemon enabled/active, unit symlink
  resolves;
- assert `/nix` and `{{ zterra_root }}/local-/nix` share a device;
- `zterra_binds`: refuse to bind over a non-empty target (`allow_shadow`,
  default false);
- `zterra-bind.mount.j2`: order `nix-daemon.socket` as well as `.service`;
- `verify-terra.yml`: absolute nix path + store/daemon checks;
- update `tests/unit/test_nix_step.py` and `tests/unit/test_zterra_step.py`.
