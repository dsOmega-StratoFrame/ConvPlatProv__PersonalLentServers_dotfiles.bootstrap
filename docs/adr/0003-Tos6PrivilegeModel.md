# ADR 0003 — TOS 6 privilege model: the SSH account is already uid 0

- **Status:** Accepted
- **Relation to ADR 0001:** extracts and refines Decision 8 of
  [`0001-HomeServer__HomeAssistant.md`](./0001-HomeServer__HomeAssistant.md)
  (the Ansible-side layered model). ADR 0001 §8 now points here.
- **Sibling platform ADRs:**
  [`0004-Tos6OsDetection.md`](./0004-Tos6OsDetection.md) (OS detection) and
  [`0005-AptMirrorRepoint.md`](./0005-AptMirrorRepoint.md) (apt mirror).
- **Enforced by:** `tasks/preflight_privilege_model.yml`, imported from
  `pre_tasks` (`tags: [always]`) in `HomeServer__HomeAssistant.yml` and
  `deploy-nikolaigogol.yml`; `group_vars/terra/vars.yml`.
- **Scope:** the Ansible side only — Layer 0 (`@terra`) and the privileged
  Layer-1 tasks that run on `@terra`.

## Context

`@terra` is a TerraMaster NAS running **TOS 6**, an Ubuntu-22.04-compatible,
systemd-based rootfs. On TOS 6 the first/admin account (`terra`, the SSH user /
`ansible_user`) is **uid 0 and root-equivalent**, while the separate `root`
account is **uid 9999 and unprivileged** with an empty capability set.

Confirmed on the live device via the verbose run log
(`logs/20261006T212942-access_ssh.log`): after Ansible's
`sudo -H -S ... -u root ... BECOME-SUCCESS`, the facts report
`ansible_user_uid=9999`, `ansible_system_capabilities=[""]`, `SUDO_UID=0`,
`SUDO_USER=terra`.

Ansible's default `become_user: root` therefore runs `sudo -u root` and *drops*
privileges (uid 0 → 9999), surfacing as confusing failures — apt cannot create
`/var/lib/apt/lists/partial`, tar cannot read the root-only cron spool.

## Decision

**Never assume `become_user: root` on TOS 6.**

- `group_vars/terra/vars.yml` pins `ansible_become: false` and
  `ansible_become_user: "terra"`.
- Privileged Layer-1 tasks (`nixos_image_load`, `nixos_container` + handler,
  `nixos_edge_sync`, `verify-nikolaigogol`) set
  `become_user: "{{ ansible_become_user | default('root') }}"` explicitly, so any
  forced escalation targets the uid-0 account and not TOS's unprivileged `root`.

## Consequences

- Any forced escalation targets the configured uid-0 admin account, never TOS's
  uid-9999 `root` (defaulting to `root` drops privileges).
- Escalation is opt-in per task; routine runs do not sudo-escalate at all.
- **Enforcement:** the shared read-only preflight
  `tasks/preflight_privilege_model.yml` asserts `ansible_facts['user_uid'] == 0`
  and is imported from `pre_tasks` with `tags: [always]` in both
  `HomeServer__HomeAssistant.yml` and `deploy-nikolaigogol.yml`. It fails fast
  with guidance rather than surfacing later as apt/tar errors.
- A read-only preflight cannot repair a broken model; if TOS changes its account
  mapping, the play stops with guidance instead of mutating the NAS.

## Alternatives considered

1. **Use Ansible's default `become_user: root`.** Rejected: on TOS 6 it runs
   `sudo -u root` and drops privileges from uid 0 to uid 9999, breaking apt
   (`/var/lib/apt/lists/partial`) and tar (`/var/spool/cron/crontabs`).
2. **Escalate to `root` explicitly (`become_user: root`).** Rejected: same
   failure as (1); TOS's `root` is not the privileged account.
3. **Rely on conventional privilege detection instead of a preflight.** Rejected:
   the failure surfaces late and obscurely as apt/tar errors; the preflight makes
   it fail fast and legibly.

## References

- [`0001-HomeServer__HomeAssistant.md`](./0001-HomeServer__HomeAssistant.md) — Ansible-side architecture baseline; §8 points here.
- [`0004-Tos6OsDetection.md`](./0004-Tos6OsDetection.md) — sibling: OS detection on TOS 6.
- [`0005-AptMirrorRepoint.md`](./0005-AptMirrorRepoint.md) — sibling: apt mirror repoint.
- [`../HomeServer__HomeAssistant_plan.md`](../HomeServer__HomeAssistant_plan.md) §3 assumption 4 — live-device evidence and enforcement summary.
