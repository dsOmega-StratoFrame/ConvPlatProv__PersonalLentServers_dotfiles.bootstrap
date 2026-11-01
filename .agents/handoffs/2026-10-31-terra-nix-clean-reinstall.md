# Handoff — clean reinstall of Nix on @terra (Option B)

- Task: `NIX-TERRA-001`
- Date: 2026-10-31
- Orchestrator record: Logseq `ai-orc Orchestrator_system/NIX-TERRA-001 orchestration-record`
- Repo: `PersonalLentServers%Russian_dotfiles.bootstrap`
- Target: inventory host `terra-local` (TOS 6 NAS; ssh user `terra`, uid 0)
- Status: **Phase 0 executed 2026-10-31; Phase 1 hit the TOS uid trap; host repaired manually; Phase 1b (role repair via Ansible) pending**

> **EXECUTED 2026-10-31 19:26 MSK.** Phase 0 ran via
> `make run-log LOG_LABEL=teardown CMD='ssh terra@terra-local bash -s'`.
> Log: `logs/20261031T192652-teardown.log` (exit 0).
>
> The earlier WAN outage was transient: reachability was re-verified 3×200 to
> `releases.nixos.org` (plus `cache.nixos.org` 200) immediately before the
> teardown and 200 again after it.
>
> State after Phase 0 (verified): `/nix` is no longer a mountpoint and is empty
> on `/dev/md9`; `/zterra/local-/nix` is empty; no `nix-daemon` process;
> `nix.mount` and the dangling `nix-daemon` unit symlinks are gone.
>
> **Phase 1 may run** (`--tags binds`, then `make -f Makefile.NixBootstrap run`).
> Re-check `curl -4 -sS -o /dev/null -w '%{http_code}\n' https://releases.nixos.org/`
> immediately before the nix run. Use `-4`: the NAS has no global IPv6 route,
> so an unqualified `curl` can pick a dead AAAA path.

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
- Do **not** set `ANSIBLE_ROLES_PATH` for the repo playbooks. It replaces
  Ansible's built-in search path (`~/.ansible/roles`, `/usr/share/ansible/roles`,
  `/etc/ansible/roles`) instead of extending it, which hides the
  `danielrolls.nix` installed by `make install`. The Makefiles forward it only
  when you set it; the repo's own roles resolve from `./roles` next to the
  playbook.
- SSH: `ssh terra@terra-local 'id -u'` prints `0`.
- Host can reach `releases.nixos.org` and `cache.nixos.org`. Re-check **on the
  host**, immediately before Phase 0:
  `curl -sS -o /dev/null -w '%{http_code}\n' https://releases.nixos.org/`.
  At 2026-10-31 this check failed (no WAN egress); see the block above.

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

# 1.2 recreate nix.mount only (zterra_mount/layout are already converged).
# STEP_TAGS must be given: Makefile.Zterra defaults it to `zterra`, which would
# also run zterra_mount, zterra_layout and zterra_docker_data (out of scope).
make -f Makefile.Zterra run STEP_TAGS=binds INVENTORY=hosts.ini

# 1.3 /nix must now be the zterra subvolume and empty
ssh terra@terra-local 'findmnt -T /nix -o TARGET,SOURCE,FSTYPE; stat -c "%d %n" /nix /zterra/local-/nix'

# 1.4 fresh install through the role under test
make -f Makefile.NixBootstrap run
# equivalent: ansible-playbook -i hosts.ini HomeServer__HomeAssistant.yml --tags nix -v
```

> **Working tree carries the hardening (2026-10-31).** The checkout now includes
> F1–F7 (uncommitted): the store-based gate, the empty-mount fail-fast, the
> post-install asserts, the bind shadow guard and the post-bind identity check.
> They are compatible with this runbook *in order*: `binds` first (target empty,
> so the shadow guard passes), then `nix` (mount source is
> `{{ zterra_root }}/local-/nix`, so the empty-store guard passes).
> Running the tags in the wrong order would now fail safely instead of silently
> shadowing the store — that failure is the guard working, not a regression.

### Known failure mode: capture it, do not hack around it

On 2026-10-10 the first install run died *after* a successful install at
`danielrolls.nix : nix_commands` with `nix: command not found` (rc 127); a
second run passed. The current role injects `bootstrap_nix_env_path` for this.

If the installer completes but the smoke item fails with rc 127:

- do **not** edit the role or the host ad hoc;
- re-run `make -f Makefile.NixBootstrap run` once;
- record both logs and report it as a finding (role defect F4/F5 below).

## Phase 1b — TOS ownership trap (2026-11-01 run)

The first `make -f Makefile.NixBootstrap run` reached the installer and failed at
its last step (`logs/20261101T154156-nix.log`, `fatal` at `Run the installer`,
rc 1). The store and profile were installed; the systemd units were not.

Root cause — TOS 6's `root` account is uid 9999, while uid 0 is `terra`:

```
getent passwd 0 9999
  terra:x:0:0:...
  root:x:9999:9999:...
stat -c '%u %U %g %G %n' /nix /nix/var /nix/store
  9999 root 30000 nixbld /nix
     0 terra    0 terra  /nix/var
     0 terra 30000 nixbld /nix/store
```

`install-multi-user:699` runs `chown -R root:nixbld /nix`; the **name** `root`
resolves to uid 9999, so `/nix` becomes owned by the unprivileged account.
Directories created afterwards by `install` (run as uid 0 `terra`) stay 0-owned.
The installer's `systemd-tmpfiles --create --prefix=/nix/var/nix` then refuses
the 9999 → 0 transition (`uid_unsafe_transition`: only a transition *from* uid 0
is safe) and aborts before `systemctl link/enable/start`
(`install-systemd-multi-user.sh:100-124`).

Consequence: on any fresh TOS install the role leaves Nix **installed but
unmanaged** — no `nix-daemon.service`/`.socket`, no daemon after reboot.

### Current state (manual repair applied 2026-11-01)

Nix 2.34.7 is installed and working: `/nix` and `/zterra/local-/nix` chowned to
`0:30000` numerically, `systemd-tmpfiles` run, units linked/enabled/started,
`nix --version` and `nix flake --help` pass. This manual repair is **not** the
deliverable; the role must do it.

### Task for the Ansible agent

1. Re-run `make -f Makefile.NixBootstrap run`. With the store populated, the
   store-based gate must skip the installer and the post-install asserts must
   pass; capture `changed=`/`failed=`. This proves the idempotent path.
2. Make a fresh TOS install survive the trap. In
   `roles/bootstrap_nix/tasks/main.yml`, wrap the `danielrolls.nix` include so a
   failure at the tmpfiles step is recoverable, then repair and finish:
   - verify `/nix/var/nix/profiles/default/bin/nix` exists; if not, fail and
     surface the installer output (a real install failure);
   - `chown -R 0:30000 /nix` — numeric uid/gid; never the name `root`, and never
     `sudo` (on TOS `sudo` targets uid 9999);
   - `systemd-tmpfiles --create --prefix=/nix/var/nix`;
   - ensure the units:
     `systemctl link <profile>/lib/systemd/system/nix-daemon.service`,
     `systemctl enable <profile>/lib/systemd/system/nix-daemon.socket`,
     `systemctl daemon-reload`, `systemctl enable --now nix-daemon.socket`,
     `systemctl restart nix-daemon.service`;
   - assert `nix store ping`, `nix --version`, daemon `active`/`enabled`, store
     non-empty, and `/nix` on the same device as
     `{{ zterra_root }}/local-/nix`.
   - Keep every task idempotent (`changed_when`, `creates`, or state checks);
     derive the gid with `getent group nixbld` instead of hardcoding 30000.
3. Add unit tests in `tests/unit/test_nix_step.py` for the rescue/repair block
   and the numeric-ownership rule: assert the chown task does not use the string
   `root` and does not rely on `become`/sudo.
4. Report: log paths, recaps, whether the repair block fired on the already-fixed
   host (it should be a no-op), and the acceptance output.

## Phase 1c — nix-daemon assertion fix (2026-11-01, verified)

The re-run failed at `roles/bootstrap_nix/tasks/main.yml:222`:

```
bootstrap_nix_daemon_enabled.stdout | trim == 'enabled'
# enabled=linked, active=active, unit-resolves=True
```

Verdict (verifier): **assertion bug; the host is healthy.** `systemctl link`
(what the Nix installer uses for the service) never yields `enabled`; it yields
`linked` with rc=1. The durable activation path is the **enabled socket**
(`install-systemd-multi-user.sh:110-124`).

Fix in the role:

```yaml
# accept the service state as the installer produces it
- bootstrap_nix_daemon_enabled.stdout | trim in ['enabled', 'linked']
```

Add a socket probe and require it:

```yaml
- name: Read the nix-daemon socket enabled state  # noqa: command-instead-of-module
  ansible.builtin.command: "systemctl is-enabled nix-daemon.socket"
  register: bootstrap_nix_daemon_socket_enabled
  changed_when: false
  failed_when: false

# in the assert:
- bootstrap_nix_daemon_socket_enabled.stdout | trim == 'enabled'
```

Update `tests/unit/test_nix_step.py:250-258` to assert the predicate contents
(accept `linked`, require socket `enabled`), not just task presence.

Do **not** "fix" the host with `systemctl enable` on the service: it would only
mask the assertion bug and diverge from the installer.

Open risk: the linked unit target lives under the `/nix` bind mount
(`nix.mount`). Reboot resolvability is unverified; after the next reboot check
`is-enabled`/`is-active`, and if `not-found`, move `/nix` earlier
(`local-fs.target`/fstab) or copy the unit files instead of symlinking.

## Acceptance (all must pass)

```bash
ssh terra@terra-local '
  findmnt -T /nix -o TARGET,SOURCE,FSTYPE
  test "$(stat -c %d /nix)" = "$(stat -c %d /zterra/local-/nix)" && echo SAME_FS
  ls /nix/store | wc -l
  /nix/var/nix/profiles/default/bin/nix --version
  /nix/var/nix/profiles/default/bin/nix flake --help >/dev/null && echo FLAKES_OK
  systemctl is-enabled nix-daemon.service
  systemctl is-enabled nix-daemon.socket
  systemctl is-active nix-daemon.service nix-daemon.socket
  test -e /etc/systemd/system/nix-daemon.service && echo UNIT_RESOLVES
  cat /etc/nix/nix.conf
'
```

Expected: `/nix` on `...nvme-1-part4[/local-/nix]`, `SAME_FS`, store count > 0,
`nix (Nix) 2.x`, service `linked`, socket `enabled`, both `active`,
`UNIT_RESOLVES`.

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

## Follow-ups — implemented 2026-10-31 in the working tree (uncommitted)

Role hardening, for a builder with tests (all of the below is now in the tree;
see the Logseq `NIX-TERRA-001` record for file:line evidence):

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
