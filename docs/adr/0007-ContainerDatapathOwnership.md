# ADR 0007 — One datapath owner per host; containers are consumers

- **Status:** Accepted (2026.11.02) — naming follows the operator's `manilov-network` decision (D3a)
- **Task:** `MANILOV-MVP-001`
- **Target:** `@Manilov` (VM), hosted by `@NikolaiGogol` (NixOS system container)
- **Host:** `@terra` (TOS 6, `bridge` profile); the rule also applies to `@salt`
- **Related:** extends ADR 0006 D1/D2 (ownership boundary and marker selection);
  refines ADR 0002 (one content-addressed image identity)
- **Revision:** 2 (2026.11.02). Standardizes the `manilov-network` names and
  records the uplink-MAC rule (D3a). The invariant (D1), designation (D2) and
  enforcement (D3) are unchanged.
- **Decision owner:** operator. **Reviewer:** not set (`reviewed-by` is never set
  by the architect).
- **Evidence:** `docs/NetworkTopology__@terra__@Manilov.md`,
  Logseq `ai-arc Architect_system/MANILOV-MVP-001 network ownership contract (2026.11.02)`,
  ADR 0006 `@terra` context (§1).

## 1. Context

The operator asked whether C′ ("the image owns the `@Manilov` datapath") limits
`@terra` to a single `@NikolaiGogol`-like container. The facts that decide it:

- `@NikolaiGogol` runs with `network_mode: host` and `privileged: true`. Every
  such container therefore shares the `@terra` host network namespace: links,
  addresses, routes, bridges and nftables are *global*, not container-private.
- The image applier owns `br0`, the uplink enslavement, the L3 move, the MAC
  pin, the VM-path rules, and the VM tap attachment.
- The marker is host-provisioned but currently carries no owner identity.
- The host relinquishes `eth1` once; the host rescue (`eth0` + timer) is global.
- `@terra` has one connected NIC (`eth1`) and one unconnected slot (`eth0`).

Two `@NikolaiGogol`-like containers running the applier with the same host
marker would race on the same `br0` and `eth1`: both would try to enslave the
uplink, create the bridge, move L3, and pin the MAC. The result is at best one
apply failing unpredictably and at worst a half-applied datapath, flapping DHCP,
a duplicated MAC pin, and conflicting nft rules. Rollback from one owner would
delete the other's bridge.

## 2. Decision

### D1 — Invariant

**Exactly one datapath owner per host; any number of containers may be
consumers.** The owner is the single writer of `br0`, the uplink enslavement, L3,
the MAC pin, the VM-path rules, and the tap attachments. Consumers never run a
mutating verb and never touch those surfaces.

C′ therefore does **not** limit the number of containers; it limits the number of
*owners* to one. On `@terra` you may run N `@NikolaiGogol`-like containers; exactly
one of them may hold the datapath. Additional independent datapaths require
additional uplinks/VLANs (see D5), not additional owner containers.

### D2 — Ownership designation

The pinned, hashed marker gains an explicit role and owner identity:

```json
{
  "role": "owner",
  "owner": {
    "id": "manilov-datapath-terra",
    "container": "NikolaiGogol",
    "image": "@sha256:..."
  }
}
```

- `role` is `owner` or `consumer`; no other value is accepted.
- `owner.id` is a stable logical identity, not a hostname and not a container
  name by itself.
- `owner.container` and `owner.image` bind the designation to the container and
  to the content-addressed image tag/digest (ADR 0002).
- The marker is host-provisioned, bind-mounted read-only, and its allowed digests
  are pinned in the image. A container cannot promote itself: changing `role`,
  `owner.id`, or `owner.image` is a host action followed by a new pinned digest.

Only `role: owner` may run `apply` and `rollback`. `role: consumer` may run only
read-only `check` and `status` (consumer mode).

### D3 — Enforcement

Designation is not enough; the applier must *refuse* a second owner, not race it.

- **Serialization lock.** `apply`, `confirm`, and `rollback` take an exclusive
  `flock` (and an atomic `O_EXCL` creation) on a lock file in a host state
  directory bind-mounted into the container. Because the container shares the
  host netns, that path is the same object for every container.
  - Per-boot lock: `/run/manilov-network/owner.lock` (tmpfs; cleared at
    reboot).
  - Durable ownership record: `/var/lib/manilov-network/owner.json`.
  - Both live in the bind-mounted state directory the applier already uses for
    its own state, `/var/lib/manilov-network/` (`owner.json` + `state.json`).
- **State record.** `owner.json` stores `owner.id`, `owner.container`,
  `owner.image`, host boot id, container start id, and timestamp.
- **Owner-mode `check`/`apply`.** Before any write: verify marker `role: owner`,
  verify the lock is free or held by this same `owner.id`, verify no conflicting
  L3 owner (no foreign `br0`; `eth1` unenslaved or enslaved to this owner's
  `br0`), then acquire the lock and re-verify. Any mismatch fails closed.
- **Consumer-mode `check`/`status`.** Read-only. Report the current owner from
  `owner.json` and `status`; never take the lock and never mutate.
- **Stale locks.** Compare host boot id and container start id. A lock left by a
  previous boot or a recreated container may be reclaimed only by the *same*
  `owner.id`, never by an arbitrary container. A different `owner.id` or a
  different image digest is refused even if the lock looks stale.
- **`status`** reports the lock holder, the marker role, drift, and any host
  reassertion of the uplink.

### D3a — Decision record: naming and uplink MAC

Operator decision (2026.11.02), verbatim: "Prefer manilov-network".

**One name for the network unit's own artifacts.** The service units, the
binary, the module directory, the runtime directory and the state directory all
use the full name `manilov-network`. The short form `manilov-net` is retired and
must not reappear in a unit, a path, or a plan.

| Artifact | Name |
|---|---|
| Systemd units | `manilov-network.service`, `manilov-network-watchdog.service`, `manilov-network-watchdog.timer` |
| Binary | `manilov-network` |
| Module directory | `modules/nixos/services/manilov-network/` |
| Runtime directory (per boot) | `/run/manilov-network/` — holds `owner.lock` and the read-only `host-networkd/` view |
| State directory (durable) | `/var/lib/manilov-network/` — holds `owner.json` and `state.json` |
| Marker (host-provisioned input) | `/etc/manilov/marker.json` — unchanged; it is not a unit artifact |

`/run/manilov/` and `/var/lib/manilov-net/` are drift: a plan that emits either
is wrong. The runtime directory must be created as `manilov-network` so that the
lock path and the runtime directory share one name.

**The uplink MAC is local and observed, never a selector.** The uplink MAC the
marker carries is the permanent MAC of the *local host's own* physical NIC that
carries the uplink — `@terra`'s own Ethernet NIC, `@salt`'s own Wi-Fi device. It
is never the MAC of a router, a gateway, a peer host, or the other host's
device. It is discovered at deploy time from the interface that currently
carries the management address, never hardcoded, and it never enters
`selectorDigest`. Ownership identity lives in `owner.id` and is never derived
from a MAC.

### D4 — Multiple VMs on the owner's bridge

Multiple VMs may share the owner's bridge. They do not need to be owners: the
bridge is a shared L2 segment, and each VM gets its own tap and MAC on it. The
owner applier renders *all* tap attachments from the selected profile (or is
extended with additional VM-path entries); taps do not race with each other, they
race only with the single writer.

A consumer container that runs a VM must have its taps rendered by the owner
applier — not by a second applier. Additional VMs are therefore "VM path
entries" of the owner, not additional owners.

### D5 — What multiple owners would require

A second independent datapath on `@terra` would need one of:

1. a second physical uplink/NIC;
2. 802.1q VLANs on `eth1` (the switch must carry tagged VLANs; one entity still
   programs the tagging and enslavement — the owner);
3. macvtap on `eth1` (per-VM L2 path; cannot coexist with `eth1` enslaved to
   `br0`, and has host↔guest and multicast limitations);
4. SR-IOV virtual functions, if the NIC supports them.

With one connected NIC (`eth1`), one bridge is the practical limit: a second
bridge would have no uplink and no LAN L2 connectivity. `eth0` is unconnected,
so it cannot serve as a second uplink. That is why multiple owner containers are
not an option on `@terra` as it stands.

## 3. Consequences

- C′ means **one datapath owner, N consumers** — not one container. Container
  count is unconstrained; independent datapath count is not.
- A second `@NikolaiGogol`-like container may run and bind host ports, but its
  `apply`/`rollback` is refused unless it is the single owner; its `check`/
  `status` are read-only.
- A second owner is refused deterministically instead of corrupting the datapath
  under a race.
- Rollback is unambiguous: only the lock holder may roll back.
- Operational cost: the marker gains `role`/`owner`, and the host must provide the
  bind-mounted state directory; the host relinquish and rescue stay global and
  one-time.

## 4. Alternatives considered

1. **No owner field; rely on "only one container runs it".** Rejected: there is
   no enforcement; a container recreate or a second deploy can race.
2. **Multiple owner containers, each with its own bridge.** Rejected on `@terra`:
   one connected uplink gives no second L2 path; a second bridge is useless.
3. **macvtap per VM instead of a bridge.** Rejected as the default: it loses the
   host↔VM path, complicates proxyARP/UDP, and still leaves exactly one writer on
   `eth1`.
4. **Consumers run the applier against the owner's `br0`.** Rejected: two writers
   on the same bridge/L3 — the failure this ADR exists to prevent.
5. **Per-container private network namespaces.** Rejected: the container is
   `network_mode: host` by design; changing that would move the datapath out of
   the host namespace and invalidate the ADR 0006 model.

## 5. Validation gates

- Two containers with `role: owner` and different `owner.id`: the second
  `check`/`apply` fails closed and the first datapath is unchanged.
- A consumer container's `check`/`status` is read-only and reports the owner
  identity.
- After a container recreate, the same `owner.id` may reclaim a stale lock after
  the boot-id/container-start check; a different `owner.id` or image digest may
  not.
- Two VMs attached to `br0` both reach the LAN; both taps are managed only by the
  owner applier.
- Unknown `role` or a missing `owner` block fails closed.
- `@terra` still passes the ADR 0006 gates with the owner/consumer rules in
  place.

## 6. Prohibited changes

- A consumer must never run `apply`/`rollback` or write `br0`, `eth1`, routes,
  the MAC pin, or nftables.
- No container may promote itself to owner; `role`/`owner` changes are host
  actions followed by a newly pinned digest.
- No second bridge on the single uplink `eth1` without an approved uplink/VLAN
  change.
- The lock/state directory must be host-shared (bind-mounted), never
  container-private, or the enforcement is void.
- No short-form `manilov-net` unit, path, or directory may be introduced; the
  name is `manilov-network` (D3a).

## 7. References

- `docs/adr/0006-ManilovNetworkOwnership.md`
- `docs/adr/0002-ContentAddressableImageTag.md`
- `docs/NetworkTopology__@terra__@Manilov.md`
- Logseq `ai-arc Architect_system/MANILOV-MVP-001 network ownership contract (2026.11.02)`
