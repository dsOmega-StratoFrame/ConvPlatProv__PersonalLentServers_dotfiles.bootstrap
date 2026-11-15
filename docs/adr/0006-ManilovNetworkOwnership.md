# ADR 0006 — `@Manilov` network ownership: image-owned datapath, host-owned transport

- **Status:** Accepted (2026.11.02; amended 2026.11.03 by E1 / operator gate G-E1-1; corrected 2026.11.15 from live `@terra` evidence — D4a table and OQ5; amended 2026.11.15 — D4a table discovery, Revision 5) — operator decisions recorded in §6a
- **Task:** `MANILOV-MVP-001`
- **Target:** `@Manilov` (VM), hosted by `@NikolaiGogol` (NixOS system container)
- **Hosts:** `@terra` (TOS 6, bridge mode), `@salt` (NixOS, Wi-Fi proxyARP mode)
- **Repos in scope:** `PersonalLentServers%Russian_dotfiles.bootstrap`,
  `Unix_dotfiles` (`systems/x86_64-docker/NikolaiGogol`,
  `systems/x86_64-linux/NikolaiGogol_inner`),
  `ConvPlatProv-HomeServer__HomeAssistant/Virt_scripts_bootstrap`
- **Supersedes:** the host-side bridge/dead-man/persist ownership proposed by the
  `MANILOV-MVP-001` MVP plan (see §8). It does not supersede ADR 0001–0005;
  it refines ADR 0001 §2 (per-layer playbooks) at the network boundary.
- **Revision:** 5 (2026.11.15). The permit table is discovered, not pinned; the
  applier accepts `ip` and `inet` filter layouts. D4a now selects the host table
  that owns `FORWARD` (preferring `ip filter`, else `inet filter`), records the
  choice (`table`, `table_family`) in its state file, and never creates a table
  or base chain. No ownership, F1/F3/F4, marker-schema, or exit-code change.
  Revision 4 (2026.11.15) corrected D4a's host table from the assumed
  `inet filter` to the observed `ip filter` (IPv4), resolved OQ5 to "the permit
  jump is the first rule of `ip filter FORWARD`, before `DOCKER-USER` at handle
  86", and restated OQ5a (decision resolved, live observation pending first
  apply) and OQ5b (not verifiable until the first bridge apply).
  Revision 3 (2026.11.03). Encodes operator gate **G-E1-1** — the accepted
  E1 firewall-ownership decision — by splitting the VM-path FORWARD surface into
  a host-owned scoped permit (`MANILOV_FORWARD`, D4a) and image-owned drop-only
  tables (D4). Revision 2 (2026.11.02) standardized the `manilov-network` names,
  recorded the operator's answers to §6, and withdrew the §6 Q3 fallback
  ("the host pre-adds the subnet"). F1 = C′, F3, F4 and D7 are unchanged; D4 is
  rewritten by this revision.
- **Evidence:** `docs/NetworkTopology__@terra__@Manilov.md`,
  `docs/NetworkTopology__@salt__@Manilov.md`,
  Logseq `ai-rsh Researcher_system/MANILOV-MVP-001 @terra network research (2026.11.02)`,
  raw probe `logs/network-research-20261102T164715Z/` (git-ignored).
- **Decision owner:** operator. **Reviewer:** not set (`reviewed-by` is never
  set by the architect).

## 1. Context

`@Manilov` is a Home Assistant OS VM run by libvirt inside the `@NikolaiGogol`
system container. The container runs with `network_mode: host` and
`privileged: true`, so anything the image's NixOS networking configures lands in
the *host* network namespace. That is how `@salt` already works today:
`Unix_dotfiles/systems/x86_64-linux/NikolaiGogol_inner/default.nix` declares
`tap0`, `proxyARP` on `tap0` and `wlan0`, IPv4 forwarding, and FORWARD rules;
`qemu.runAsRoot = true` lets libvirt attach the tap.

On `@terra` the same boundary collides with a pre-existing owner:

- `systemd-networkd` owns L3 on `eth1` via per-MAC
  `/etc/systemd/network/10-eth*.network` (`ClientIdentifier=mac`), and reasserts
  DHCP on every carrier event and reboot.
- The host nftables `FORWARD` policy is `drop`, `br_netfilter` is built in with
  `bridge-nf-call-* = 1`, and Docker owns `DOCKER-*` chains.
- `INPUT_PROTECT` accepts SSH (port 9222) only from the management subnet and
  gateway; anything else is dropped.
- `eth0` has no carrier; `eth1` is the only connected NIC.

The operator resolved the ownership fork:

> "C' — image should own `br0` and all other network configurations that are
> crucial for `@NikolaiGogol` and `@Manilov` operations. Host network is used
> only for global configurations (in case we had, for instance, other docker
> containers like `@NikolaiGogol` or global firewall) and `@terra`–`@salt`
> connection (ssh, for example)."

and the F4 fork:

> "`NikolaiGogol_inner` is about edge rebuild … But it could be easily
> transferred into `NikolaiGogol`. It doesn't change much apart from deployment:
> both represent the same system. Treat inner system like a 'fork' of a former
> system."

So this ADR must make two things true at once: **the image is the single writer
of the `@Manilov` datapath**, and **the host remains the single writer of
everything the image must not break** — the global firewall, SSH, and the
`@terra`–`@salt` transport.

## 2. Decision drivers

1. One datapath writer per surface; no two writers may race on the same link,
   address, MAC, or nftables chain.
2. One host-independent image; no per-host image fork.
3. Fail closed and loudly if the selected mode contradicts the host.
4. Reboot/recreate survivability: the VM path must return without manual `ip` or
   `nft` commands.
5. SSH must survive the L3 move; losing remote access is the worst failure mode.
6. The host must keep a rescue path that does not depend on the image or the
   container being healthy.
7. The strategy schema stays about deployment, not about host topology.

## 3. Decision

### D1 — C′ ownership boundary (F1)

| Surface | Owner | Contract |
|---|---|---|
| Network **mode** declaration | host provisioning (bootstrap), read-only to image | a pinned, hashed marker file; the image never infers the mode from `DEPLOY_HOST`, `/etc/hosts`, hostname, or an env var |
| `br0` creation, uplink enslavement, L3 move, MAC pin | image applier (`bridge` profile) | the image is the only writer after the host relinquishes the uplink |
| `tap0`, `proxyARP`, IPv4 forwarding, tap↔uplink rules | image applier (`proxyarp` profile) | same applier, different immutable profile |
| VM-path forward **permit** | host provisioning (bootstrap), scoped to the declared interface pairs | chain `MANILOV_FORWARD` in the host `ip filter` table (IPv4), jumped from host `FORWARD` before the Docker jumps; idempotent and reasserted; never writes the image tables (D4a) |
| VM-path anti-spoof/isolation **drops** | image applier | dedicated drop-only nftables tables (`table bridge manilov_vm`, `table inet manilov_vm`); no permit rule, no `policy drop`, no `flush ruleset`; never touch `DOCKER-*`, the host `filter` table, or `INPUT_PROTECT` |
| VM tap attachment (libvirt interface element) | image applier, rendered from the selected profile | `type='bridge'` + `source bridge='br0'` for bridge; `type='ethernet'` + `target dev='tap0' managed='no'` for proxyARP |
| Global firewall policy and rules | host (TOS nftables; host NixOS on `@salt`) | the image adds only its own table/chain and must not change the host policy |
| SSH listener and `INPUT_PROTECT` | host | the image must never edit them; the host adds subnets only as an explicit precondition |
| Host uplink **relinquish** | host bootstrap (one-time, idempotent, backed up) | writes `Unmanaged=yes`; it is a hand-off, not a datapath writer |
| Host rescue (timer + static address on `eth0`) | host bootstrap | bounded safety net; no VM-path packets |
| Marker data | host provisioning | provisioned at deploy; bind-mounted read-only; digest pinned in the image |
| Active applier state | image applier | dedicated state dir; host rescue state is separate |

The host has exactly two host-side network writes, and neither is a datapath
write. The first is the relinquish: deliberately negative — it removes the host
from the uplink so the image can own it, and it never creates `br0`, moves L3, or
writes forwarding rules. The second is the scoped VM-path forward permit (D4a): a
positive write that lets the declared VM path traverse the host's `drop` forward
policy. It is bounded to the declared interface pairs, idempotent, reasserted,
and it does not own the datapath or write the image's tables.

### D1.1 — Ownership summary

| Surface | Owner |
|---|---|
| Network mode declaration | host provisioning → pinned, hashed marker (read-only to the image) |
| `br0`, uplink enslavement, L3 move, MAC pin | `@NikolaiGogol` image applier (`bridge` profile) |
| `tap0`, proxyARP, forwarding, tap↔uplink rules | image applier (`proxyarp` profile) |
| VM-path forward **permit** | bootstrap repo (scoped, idempotent, reasserted) — `MANILOV_FORWARD` in the host `filter` table |
| VM-path anti-spoof/isolation **drops** | image applier (dedicated tables only) |
| VM tap attachment | image applier, rendered from the selected profile |
| Global firewall, SSH/`INPUT_PROTECT` | host |
| Host uplink **relinquish** | bootstrap repo (one-time, idempotent, backed up) — `Unmanaged=yes` drop-in on the existing `.network` file that matches the management NIC |
| Host rescue (`eth0` + timer) | bootstrap repo, safety net only |
| Dead-man / rollback | image applier's `rollback`, not a host script |

The host relinquish is the *negative/hand-off* host write: it removes the host
from the uplink and hands the link to the image, and it never creates `br0`,
moves L3, or writes forwarding rules. The scoped VM-path forward permit (D4a) is
the second, *positive* host write: it grants forwarding only for the declared
interface pairs. The bootstrap repo is therefore a writer of host-global objects
(relinquish + permit), but it is still not a datapath writer and must never be
listed as one.

**State directory and file names.** The network unit's own artifacts are
`/run/manilov-network/owner.lock` (per boot) and
`/var/lib/manilov-network/` (`owner.json` plus `state.json`, durable); the
host-provisioned marker stays `/etc/manilov/marker.json`. The short form
`manilov-net` is retired. ADR 0007 D3a carries the full name table.

**Owner-boundary clarifications (2026.11.15).** These restate existing
decisions at the granularity the ownership diagrams need; they change no
decision.

- **Physical NIC hand-off.** The NIC hardware and driver stay with the host.
  Once the image enslaves that NIC into `br0`, L2 membership and the L3 address
  on that path belong to the image; this is a hand-off, never a clean
  side-by-side ownership. D1 assigned `br0`/enslavement/L3/MAC but did not say
  this explicitly.
- **Two writers in `ip filter`, at chain granularity.** `FORWARD` is the
  host's policy chain; `MANILOV_FORWARD` is the bootstrap-owned scoped grant.
  They are disjoint chains, so "one writer per surface" holds at chain
  granularity, not at table granularity.
- **Docker chain ownership.** The `DOCKER-*` chains are host-managed chains
  that Docker populates; the bootstrap and the image never touch them. Docker
  owns its own bridges and the traffic of its services, not the chain objects.
- **Dynamic tap name.** On `@terra` the libvirt tap device name is dynamic, so
  the ownership diagrams say "VM tap" rather than a fixed `tap0`.

The limit on how many `@NikolaiGogol`-like containers may own the datapath on
`@terra` is a separate decision: see ADR 0007
(`docs/adr/0007-ContainerDatapathOwnership.md`).

### D1.2 — ADR label remap (mirror, not canonical)

Logseq records the canonical concrete ADRs as
`docs/adr/0010-manilov-network-ownership.md` and
`docs/adr/0011-container-datapath-ownership.md` in `Unix_dotfiles`; those files
are the source of truth for the concrete rules. This repository's
`docs/adr/0006-ManilovNetworkOwnership.md` and
`docs/adr/0007-ContainerDatapathOwnership.md` are the Ansible/bootstrap-side
**mirror** of those canonical documents. The contract labels remap as
`0006 → 0010` and `0007 → 0011`.

`Unix_dotfiles` already contains unrelated files at its own `0006`/`0007`
numbers. They are unrelated to this contract and must never be touched,
overwritten, or treated as this contract's ADRs. For this repository's ADR work
`Unix_dotfiles` is a black box: cite the remap only, and do not read or edit it.

### D2 — Mode selection by pinned marker

The applier takes exactly one of two immutable profiles, selected by a marker
JSON file (bind-mounted read-only, hashed). The marker's allowed digests are
pinned into the image, so one image serves both hosts and an unknown or edited
marker fails closed. The marker is the *only* selector; `DEPLOY_HOST` remains a
deployment-target variable and must never choose the network mode.

**F3 (confirmed):** "without changing image contents" means one image with no
per-host fork; one rebuild to add the network module is acceptable. This permits
step 5 of §9 (rebuild **one** image and keep the previous content tag for
rollback). It does not permit per-host image forks or runtime injection of the
module.

The applier exposes one verb set: `check`, `apply`, `confirm`, `status`,
`rollback`, `watchdog`.

- `check` validates marker digest, profile, host identity, and preconditions
  (uplink present, no conflicting L3 owner, resulting management path consistent
  with `params.addressing`). It does **not** require the host to pre-authorize a
  subnet in `INPUT_PROTECT`: a wrong subnet is caught by the unconfirmed apply
  and fixed by rollback (§6a.3). It is read-only.
- `apply` is idempotent and writes only the surfaces in the right-hand column
  above.
- `confirm` records operator acknowledgement of an L3 move (`bridge` only). It
  is issued from the resulting management address; without it inside the bounded
  window the apply auto-reverts (D5).
- `status` reports drift and conflicts, including a host reasserting the uplink.
- `rollback` restores the previous active state (for the bridge profile this
  must include handing L3 back to the host, not just deleting `br0`).
- `watchdog` runs `check` and invokes `rollback` with `reason="deadman"` on
  failure; it is the in-image dead-man (D5).

### D3 — Host relinquish of the uplink

On `@terra`, the bootstrap repo (Layer 0) writes a drop-in that sets
`Unmanaged=yes` on the networkd `.network` file that currently matches the
management NIC. The drop-in is attached to the *existing* file discovered by
matching the NIC's permanent MAC, not to a hard-coded `10-eth1.network`.

- **Who:** `PersonalLentServers%Russian_dotfiles.bootstrap` — `@terra` is
  TOS 6 with only Nix home-manager, so there is no NixOS host system layer to
  own this write (see §6a.1).
- **When:** as an explicit, separate step before the first `bridge` apply;
  never inside a normal container deploy.
- **Backup:** copy `/etc/systemd/network` to a timestamped archive and record the
  exact drop-in path plus its hash in the host state file before writing.
- **Restore:** delete the drop-in, `networkctl reload`, and verify the uplink
  regains its address; the archive is the fallback.
- **Idempotent:** re-running the step is a no-op when the recorded drop-in path
  and hash already match; it never writes a second drop-in or a second archive.
- **Guard:** after relinquish, the host must not re-add a default route on the
  uplink. The applier's `status` reports a host reassertion; the host rescue
  remains available but does not repair the datapath.

### D4 — Firewall split: host permit, image drops

The host keeps the global firewall (policy, `INPUT_PROTECT`, Docker chains). The
split is asymmetric:

- **Host permit.** The host owns a scoped forward permit for the declared VM
  path (D4a). It must live inside the host's own forward traversal because that
  is where a final verdict has to be returned.
- **Image drops.** The image owns only dedicated drop-only tables for
  anti-spoof/isolation on the managed interfaces: `table bridge manilov_vm` and
  `table inet manilov_vm`, `hook forward priority -10`, `policy accept`, scoped
  drops only. No permit rule, no `policy drop`, no `flush ruleset`.

**Why the image chain cannot carry the permit.** At one packet-filtering hook
every base chain is traversed. An `accept` in one base chain is *not* final; a
`drop` — including a base-chain policy `drop` — *is* final; and a jump cannot
cross tables. The host `FORWARD` policy is `drop`, and bridged traffic also
traverses the IP forward hook. Therefore an image-owned base chain cannot, by
itself, permit VM forwarding past the host policy: the permit must be a rule
inside the host's own forward traversal, and the image may contribute only
drops. This preserves F1 ("host … global firewall") and keeps Docker and SSH out
of the image's blast radius.

Lifecycle: the permit is host provisioning, the same owner as the uplink
relinquish (D3) — idempotent, backed up, and reasserted after reboot or a
host-manager reassertion. The image verifies it read-only and fails closed
(D4a).

### D4a — Host permit (`MANILOV_FORWARD`)

- **Owner:** bootstrap repo / host provisioning — the same owner as the uplink
  relinquish (D3). The permit implementation lives in this repository, not in
  `Unix_dotfiles`.
- **Table and chain:** the permit lives in **the host table that owns the
  `FORWARD` chain** — `table ip filter` on TOS (`@terra`), `table inet filter`
  where that is the host's layout. The bootstrap **selects** the table
  (preferring `ip filter`, else `inet filter`) and records the choice (`table`,
  `table_family`) in its state file; it never creates a table or a base chain.
  A jump cannot cross tables, so `MANILOV_FORWARD` and its jump must live in the
  same table that owns `FORWARD`.
- **Jump position (resolved from live `@terra`, 2026.11.15):** the permit jump
  must be the **first rule of the host `FORWARD` chain** — inserted before
  `DOCKER-USER` at handle **86**, the first Docker jump. On `@terra` that chain
  lives in `table ip filter`; the live chain is `FORWARD` handle **45**,
  `policy drop`, with `jump DOCKER-USER` (handle 86)
  then `jump DOCKER-FORWARD` (handle 78). `DOCKER-USER` is empty, and
  `DOCKER-FORWARD` returns without a verdict for non-`docker0` traffic
  (`jump DOCKER-CT`, `DOCKER-INTERNAL`, `DOCKER-BRIDGE`, then
  `iifname "docker0" accept`). A permit appended after the Docker jumps is never
  evaluated for the VM path: the rule list ends at the base-chain `policy drop`,
  so it dies exactly as the "no match → policy drop" branch. Every forwarded
  packet — including bridged traffic that also traverses the IP forward hook —
  traverses `FORWARD`, so the permit must be the first rule in the host's own
  traversal.
- **Scope:** only the declared interface pairs from the pinned marker (for
  example `br0`↔tap and uplink↔bridge). The permit must never be broader than
  the declared interface pairs and must not match unrelated forwarded traffic.
- **IPv6:** `ip6 filter FORWARD` is `policy accept`, but
  `net.ipv6.conf.all.forwarding = 0`, so v1 needs **no** IPv6 permit. Do not add
  one "for symmetry": it would widen the grant for no path that exists.
- **Lifecycle:** idempotent; the pre-state is backed up before the write; a
  timer/reconciler reasserts the jump and chain after host reboot and after a
  host-manager (systemd-networkd, Docker, or TOS) reassertion. Re-running is a
  no-op when the chain and jump already match the declaration.
- **Applier contract (image side):** the applier's `host-permit` verb is
  **read-only** and **table-agnostic**. It inspects the live ruleset with
  `nft -j list ruleset`, locates the `MANILOV_FORWARD` chain and its jump from
  `FORWARD` wherever that chain lives (`ip` or `inet` filter), and if neither
  exists fails closed with exit code **7**, reason `host-permit-missing`. It
  **never self-heals** and never edits host rules; repair is a host-provisioning
  action.

**Jump sequence.** The diagram below shows the two traversals separately,
because conflating them is what makes OQ5 look mysterious: **base chains at a
hook** are all walked in priority order, while **rules inside one base chain**
are a single ordered list. At a hook an `accept` is not final and a `drop` is;
inside a base chain a terminal `accept` or `drop` ends that chain's rule list,
and a jump cannot cross tables.

```text
D4a — sequence of table/chain jumps, VM path, bridge profile (@terra)

TWO TRAVERSALS, kept apart:
  (1) base chains at a hook    -> all of them, by PRIORITY
  (2) rules inside one chain   -> one ordered list, by HANDLE
  at a hook: accept is NOT final, drop IS final; a jump cannot cross tables

VM -> LAN  (br_netfilter active, so the bridged frame also takes the IP hook)

  [tap PORT] frame in
      |
      |  bridge/PREROUTING: br_nf_pre_routing (NF_BR_PRI_FIRST = INT_MIN)
      |                     -> IP prerouting = conntrack only, no verdict
      v
  (1) inet/forward hook   <-- runs FIRST: br_nf_forward_ip is also at
      |                       NF_BR_FORWARD but at NF_BR_PRI_FIRST (INT_MIN),
      |                       ahead of any bridge-family priority incl. -10
      +-- prio -10  table inet manilov_vm       IMAGE, drops only, policy accept
      |             no drop matches -> accept (NOT final: next chain still runs)
      +-- prio   0  table ip filter FORWARD     HOST -> (2)
      |
      |  (2) rules of FORWARD, in handle order (live @terra 2026.11.15):
      |      #1  jump MANILOV_FORWARD    CONTRACT: inserted before handle 86
      |            |-- iif <tap-port> oif <uplink-port> accept
      |            '-- verdict returns to FORWARD and ENDS its rule list, so
      |                FORWARD's policy drop is never reached for this packet
      |      handle 86  jump DOCKER-USER      (empty, returns)
      |      handle 78  jump DOCKER-FORWARD   (returns for non-docker0)
      |      (end of rule list -> policy drop)
      v
  (1) bridge/forward hook, by priority:
      +-- prio -10  table bridge manilov_vm     IMAGE, drops only, policy accept
      |             a drop HERE is final even though the IP hook accepted
      '-- other bridge-family chains
      |
      |  bridge/POSTROUTING -> IP postrouting
      v
  [uplink PORT] frame out

LAN -> VM (mirror, same two traversals):
  [uplink PORT] -> inet/forward (image -10; host FORWARD -> jump
  MANILOV_FORWARD #1 -> accept) -> bridge/forward (image -10, drops only)
  -> [tap PORT] -> @Manilov virtio.

FAILURE: permit jump placed AFTER a Docker jump — three distinct outcomes
  ... #1 jump DOCKER-USER ... #2 jump DOCKER-FORWARD ...
      #3 jump MANILOV_FORWARD            <- never reached
  (a) a Docker chain returns drop   -> final; the frame dies inside the IP
                                      hook; the bridge-family image drops
                                      never run. VM unreachable.
  (b) no rule matches, list ends    -> base-chain policy drop; the frame dies
                                      inside br_nf_forward_ip. VM unreachable.
  (c) a Docker rule happens to accept -> connectivity works BY ACCIDENT; the
                                      permit is never evaluated, so its
                                      interface-pair scoping is bypassed.

NEITHER SIDE SUBSTITUTES FOR THE OTHER
  image: drop-only at prio -10 in both families — can kill a packet at any
         point, can never let one through, never reasserted by the host.
  host : MANILOV_FORWARD, regular chain, accept-only, jumped from FORWARD
         before the first Docker jump — the only object that carries a packet
         past the host drop policy, and the only one the host reasserts.
  no permit -> VM unreachable; no image drops -> forwarding works, anti-spoof
  and isolation are lost.
```

#### Plain-language version

For a reader who does not work with the packet filter, the same walk is two
checkpoints in a building. A visitor (one packet) passes an **inner door** that
can only lock — it can say "stop" and never "come in". The visitor then reaches a
**front desk** whose default answer is "no visitors"; the only way through is a
**visitor pass** (the "let this through" slip), and it must be shown at the front
desk *before* the guard's "no appointment → leave" step, because that step ends
the queue.

| In the building | On the packet path |
|---|---|
| Visitor | one packet |
| Inner door (locks only) | VM-side check: can only say "stop" |
| Front desk (default: no visitors) | host-side check: default is "stop" |
| Visitor pass | the "let this through" slip |
| Guard: "no appointment → leave" | any guard step that can end the queue |
| Waved through | packet continues |
| Gone, no error | packet stopped silently |

In the good order the pass is read at the front desk and the visitor goes
through. In the bad order the guard's step runs first, the queue ends, and the
pass is never read; the visitor simply disappears, and nothing reports an error.
The companion diagram is
[`Manilov__ForwardJumpSequence__ELI5`](../_diagrams/Manilov__ForwardJumpSequence__ELI5.puml)
(PNG and SVG sit next to it); the technical sequence above and this plain view
describe the same two checkpoints.

The walk makes the failure case explicit rather than rhetorical: once a Docker
jump terminates the `FORWARD` rule list, the permit jump is never evaluated, and
the outcome is decided either by that Docker verdict or by the base-chain
`policy drop`. It also fixes an ordering detail that is easy to get backwards —
the IP forward hook runs *before* the bridge-family forward chains, because
`br_nf_forward_ip` sits at `NF_BR_FORWARD` with `NF_BR_PRI_FIRST` (`INT_MIN`),
ahead of the image tables' `-10`. The decision fixes exactly one relative
position, and everything else about the Docker order is live state:

> OQ5 is resolved by live evidence: on `@terra` the permit jump must be the
> first rule of `ip filter FORWARD`, before `DOCKER-USER` at handle 86.
> `DOCKER-USER` is empty and `DOCKER-FORWARD` (handle 78) returns for
> non-`docker0` traffic. The identity of any later Docker-managed rule remains
> live state read from `nft -a list chain ip filter FORWARD`, never assumed.

The remedy is mechanical: the permit writer inserts the jump immediately before
the first `jump|goto DOCKER-*` handle it observes and verifies that position
afterwards, so a Docker upgrade that reorders its chains surfaces as
`jump-misplaced` drift (exit **7**) instead of silently disabling the VM path.
A rendered version of this walk is
`docs/_diagrams/Manilov__ForwardJumpSequence.puml`.

### D4b — Extensibility: adding services later

The operator asked whether the narrow VM-path allow hinders other services on
`@terra` (a planned NAS, and at most a few more services via VMs/containers).
It does not. The permit is additive and per-path; extensibility comes from
adding scoped entries, never from widening the grant or lowering the host
policy. Keeping the host forward policy at `drop` is what protects the other
services — a broad accept is the change that would hurt them.

| New service | Path it needs | Does the permit change? |
|---|---|---|
| NAS share (SMB/NFS) | host-local or Docker-published | no |
| another container with a published port | Docker chains + `INPUT_PROTECT` | no |
| another VM on the owner's bridge | one more declared pair under the same owner | add a pair; never widen |
| a service that must forward traffic | its own scoped pair | add a pair; never policy accept |
| a second datapath owner | refused by the invariant | needs a new decision (VLAN / macvtap / second uplink) |

Adding a pair is a declaration change (the marker's declared pairs), made by
the same bootstrap owner as the existing permit; it is still an added scoped
entry, not a widened grant. The NAS and the extra published-port container
never touch the permit at all: their paths are host-local, Docker-published, or
host input traffic, already covered by the host firewall and Docker chains.

### D5 — Dead-man and host rescue

The host rescue is a safety net, not a datapath owner: a timer plus a static
address on the unconnected `eth0`, so an operator can regain a foothold if the
image, the container, or the bridge is broken. It belongs to the bootstrap repo,
because it must survive the image and cannot live inside the system it guards.
It must never add routes or addresses on the management uplink, never touch the
VM path, and never fight the applier.

The dead-man behaviour (revert on failed apply) belongs to the image applier's
`rollback`, not to a host script.

**Dead-man mechanics (2026.11.02).** The operator chose the simplest variant: no
host-side pre-authorization of a subnet, and the applier's `rollback` is the
dead-man.

- A `bridge` apply that moves L3 leaves the unit in `unconfirmed` until a
  `confirm` is recorded from the resulting management address. If no `confirm`
  arrives inside the bounded window, `rollback` runs with `reason="deadman"`.
- Confirmation can only arrive when the operator can reach the new address, so a
  subnet that `INPUT_PROTECT` does not cover produces exactly the intended
  outcome: no confirmation, automatic revert.
- Rollback records `phase="rolled-back"` and `handoff.to="host"`. The bootstrap
  rescue timer then restores the relinquished `.network` file (the reverse of
  D3's restore), so `systemd-networkd` reclaims the uplink without an operator
  touching the machine. That restore is bounded: it acts only when the state
  says `rolled-back` and the applier no longer owns the datapath.
- `proxyarp` needs no confirmation window: it moves no L3 and removes no host
  address.

### D6 — F4: durable system vs edge fork

`NikolaiGogol` (`systems/x86_64-docker/NikolaiGogol`) is the durable image
system. `NikolaiGogol_inner` (`systems/x86_64-linux/NikolaiGogol_inner`) is an
edge-rebuild fork of the same system, used only for the fast loop. The network
module moves out of `_inner` into a shared module imported by both; `_inner`
keeps importing it, so the edge loop is preserved without owning the contract.

Parity is a build-time check (both configurations evaluate to the same network
module output for the same marker fixture) plus a runtime `check` on each host.

### D7 — No `network` strategy field

The deployment strategy schema keeps exactly `name`, `executor`, `workspace`,
`env`, `compose`, `privilege`, `artifact`, `identity`, `paths`, `ownership`,
`pins`. Network mode is an L0 domain concern and lives in the marker, not in the
strategy. Verbs must not read a `network` field, and no strategy value may select
a profile.

## Flow ownership (progressive)

Three rendered diagrams show the same ownership contract as a progressive walk,
one per flow: L0 intent, L1 logical, L2 segments and hand-offs, L3 checkpoints.
Colour identifies the owner, and all three share one legend
(`docs/_diagrams/_shared/ManilovFlowOwnershipCommon.puml`). They are ownership
pictures, not rule diagrams: no packet-filter syntax appears in them, and the
host permit is named once, in L3, as an object label only.

| Flow | Diagram |
|---|---|
| F1 `@Manilov` → house router → internet | [`Manilov__FlowOwnership__ManilovToInternet`](../_diagrams/Manilov__FlowOwnership__ManilovToInternet.puml) |
| F2 LAN device → `@Manilov` | [`Manilov__FlowOwnership__LanToManilov`](../_diagrams/Manilov__FlowOwnership__LanToManilov.puml) |
| F3 `@Manilov` → another LAN device | [`Manilov__FlowOwnership__ManilovToLan`](../_diagrams/Manilov__FlowOwnership__ManilovToLan.puml) |

L2 and L3 stay in the rendered diagrams. The compact L0 and L1 text follows.

### F1 — `@Manilov` → house router → internet

```text
L0 (intent)   @Manilov ──────────────────────────────────────► internet
              one arrow: the VM has no uplink of its own, so it rides the host's.

L1 (logical)  [@Manilov VM] → [NixOS in @NikolaiGogol] → [TOS on @terra] → [house LAN / router]
              «@Manilov»      «NixOS image»             «TOS on @terra»   «house LAN»
```

### F2 — LAN device → `@Manilov`

```text
L0 (intent)   a LAN device ──────────────────────────────────► @Manilov
              one arrow: the LAN reaches the VM only through the host's uplink.

L1 (logical)  [LAN device] → [TOS on @terra] → [NixOS in @NikolaiGogol] → [@Manilov VM]
              «house LAN»    «TOS on @terra»   «NixOS image»             «@Manilov»
```

### F3 — `@Manilov` → another LAN device

```text
L0 (intent)   @Manilov ──────────────────────────────────────► another LAN device
              one arrow: the peer is on-link; the host's bridge is the only wire.

L1 (logical)  [@Manilov VM] → [NixOS in @NikolaiGogol] → [TOS on @terra] → [LAN peer]
              «@Manilov»      «NixOS image»             «TOS on @terra»   «house LAN»
```

## 4. Topology and event order

```text
@terra (bridge)                                   @salt (proxyARP)
────────────────────────────────                  ─────────────────────────────
LAN ── eth1 ══ br0 (L3, MAC = uplink perm MAC)     Wi-Fi AP ── wlan0 (L3, host MAC)
                    │                                             │ proxyARP + forward
                    └── libvirt tap ── @Manilov virtio            └── tap0 ── @Manilov virtio
```

```text
apply order (bridge):  marker check → uplink unmanaged + host permit (host, preconditions)
                       → create br0 → enslave uplink → move L3/MAC
                       → attach VM tap → image drop-only tables → verify host permit
                       → state=unconfirmed → confirm | dead-man rollback
apply order (proxyARP): marker check → tap0 → proxyARP/forwarding
                       → attach VM tap → image drops → verify host permit → record state
rollback:               reverse the recorded state; bridge rollback hands L3 back
```

## 5. Consequences

- One image, two profiles, one applier; no per-host image fork and no
  `DEPLOY_HOST`-based mode selection.
- A host-side relinquish becomes an explicit, auditable, reversible step; a
  failed bridge apply is recoverable without reinstalling TOS.
- The image cannot break Docker or SSH by construction: it has no write path to
  their tables or to `INPUT_PROTECT`.
- The host rescue survives a broken container; conversely it cannot repair the
  VM path, so a broken apply must be fixed through the applier.
- The strategy schema stays deployment-only.
- Two writers remain, but on disjoint surfaces: host transport, global firewall
  and the scoped permit vs image datapath. The `status` verb is the tripwire if
  that separation regresses.
- A wrong `INPUT_PROTECT` subnet no longer needs a host pre-write: the
  unconfirmed apply auto-reverts and the rescue restores host ownership.
- `_inner` remains a supported edge fork; the durable system becomes the source
  of the network contract.

## 6. Open questions (recommendation + alternative consequence)

All four are resolved by the operator on 2026.11.02; the verbatim answers are in
§6a. The recommendations below are kept for context, except where marked
withdrawn.

1. **Who writes the `Unmanaged` drop-in?** Recommended: the bootstrap repo
   (TOS 6 has no NixOS host layer). Alternative — host NixOS config — is not
   applicable on `@terra` and would create a second host-config owner.
   **Resolved (see §6a.1).**
2. **Global firewall vs VM-path FORWARD rules.** Recommended: split as D4.
   Alternative — image owns all firewall — violates single-writer and risks
   Docker/SSH lockout. **Resolved (see §6a.2).**
3. **`INPUT_PROTECT` if `br0` lands in a different subnet.** **Resolved — see
   §6a.3.** Pinning the uplink MAC keeps the host's DHCP client identity, which
   normally returns the same lease in place; the earlier fallback ("the *host*
   pre-adds the new subnet/gateway to `INPUT_PROTECT` before the apply") is
   **withdrawn**. The operator chose the dead-man variant: a wrong subnet is a
   rollback-and-fix (D5), and the host rescue is the recovery lever. The
   alternative — image edits `INPUT_PROTECT` — remains rejected: it violates D1
   and can lock out SSH.
4. **Same marker path on `@salt`?** Recommended: same path and schema, different
   content (`proxyarp`). Alternative — per-host path — forks the contract and
   invites inference from hostname. **Resolved (see §6a.4).**

## 6a. Resolved open questions (operator, 2026.11.02)

The operator's decisions are quoted verbatim; the surrounding text records only
their architectural consequences.

**0. Naming.** "Prefer manilov-network". Service units, the binary, the module,
the runtime directory and the state directory all use the full name; the short
form `manilov-net` is retired (D1.1, ADR 0007 D3a).

**1. Who writes the `Unmanaged` drop-in?**

> "bootstrap repo because terra host has only Nix home-manager."

Confirmed reason: `@terra` is TOS 6 with only Nix home-manager — there is no
NixOS host system layer, so "host NixOS config" is not an available owner on
that host. The drop-in writer therefore lives in the bootstrap repo (one-time,
idempotent, backed up). This remains a **negative/hand-off write**: it removes
the host from the uplink and hands the link to the image. It is not a datapath
writer and never creates `br0`, moves L3, or writes forwarding rules (D1.1, D3).

**2. Global firewall vs VM-path FORWARD rules.**

> "accept"

D4 stands unchanged: the host keeps the global policy, `INPUT_PROTECT` and the
`DOCKER-*` chains; the image owns one dedicated VM-path table/chain.

**3. `INPUT_PROTECT` if `br0` lands in a different subnet.**

> "I'm not sure about that. I would take simplest variant with dead-man
> rollback. What is `uplink MAC` in this context? If it's mac of a terra's device
> - ok. If it's MAC os salt's device - then no, @terra would be transported to
> another house with another router. Hence why all the fuss with arp vs bridge."

Answer to the question: **`uplink MAC` is the permanent MAC of the local host's
own physical NIC that carries the uplink** — on `@terra` that is `@terra`'s own
Ethernet NIC; on `@salt` it is `@salt`'s own Wi-Fi device. It is never the MAC
of the router, the gateway, a peer host, or the `@salt` device when the applier
runs on `@terra`. It is discovered at deploy time from the interface that
currently carries the management address (`systemd-networkd` / sysfs), never
hardcoded, and it is recorded in the marker only as an observed value and a
digest input — never as a selector.

Consequences:

- **The MAC pin is local, not upstream.** Pinning the uplink MAC keeps the
  host's DHCP client identity (`ClientIdentifier=mac`) and its L2 identity. It
  does not encode, and must not encode, which router or DHCP server answers.
- **Withdrawn:** the earlier fallback "the *host* pre-adds the new
  subnet/gateway to `INPUT_PROTECT` before the apply". The operator chose the
  simplest variant with a dead-man rollback: no host-side pre-authorization of a
  subnet.
- **A wrong subnet is a rollback-and-fix**, not a host pre-authorization. The
  bridge apply stays `unconfirmed` until the operator confirms it from the
  resulting management address. If that address is not reachable — because
  `INPUT_PROTECT` does not cover the new subnet — no confirmation arrives, the
  bounded timer fires, the applier's `rollback` runs, the state becomes
  `rolled-back`, and the bootstrap rescue restores the host `.network` file
  (D5). The recovery lever is the host rescue path (timer plus a static address
  on the unconnected `eth0`), not a firewall pre-write.
- **Moving `@terra` to another house with another router must not change
  `selectorDigest`, must not require an image rebuild, and must not require a new
  marker schema.** Only `params` and the upstream L2/DHCP environment change.
  That is exactly why `bridge` is the right profile on `@terra` (`br0` is
  L2-local and reaches whatever router sits on the uplink) and why `proxyarp`
  exists only for `@salt`, where the uplink is Wi-Fi and cannot be bridged.

**4. Same marker path on `@salt`?**

> "accept"

Same marker path and schema on both hosts, different content: `proxyarp` on
`@salt`, `bridge` on `@terra`. A per-host path is rejected — it forks the
contract and invites inference from hostname.

## 6b. E1 residual open points (2026.11.03)

1. **OQ5 — exact jump position — RESOLVED (live `@terra`, 2026.11.15).** The
   permit jump must be the **first rule of `ip filter FORWARD`**, inserted before
   `DOCKER-USER` at handle 86 — the first Docker jump (`FORWARD` is handle 45,
   `policy drop`). `DOCKER-USER` is empty; `DOCKER-FORWARD` returns for
   non-`docker0` traffic, so an ill-placed permit falls through to the base-chain
   `policy drop`. The implementation inserts before the first observed
   `jump|goto DOCKER-*` handle and verifies the position afterwards; a reorder by
   a Docker upgrade surfaces as `jump-misplaced` drift (exit 7).

2. **OQ5a — image table set and priority — decision RESOLVED, live observation
   pending first apply.** D4 mandates **two** drop-only tables,
   `table bridge manilov_vm` and `table inet manilov_vm`, both at
   `hook forward priority -10`. The `MANILOV-MVP-001` nix-plan handoff still
   describes **one** table (`inet manilov_vm`) at `priority 0`; D4 is the
   contract and the handoff is drift (the handoff is not edited here). The
   priority difference is substantive: at `0` the image chain's order against the
   host `FORWARD` chain is registration order, so the image drops are no longer
   guaranteed to run before the host permit. The *decision* is settled; the
   live observation is pending the first apply — no `manilov_vm` tables exist on
   `@terra` yet because the container is not running. Record the observed table
   set and priorities at that first apply.
3. **OQ5b — the interface pair as the hook sees it — cannot be verified yet.**
   At the IP forward hook a bridged frame presents the bridge **ports** as
   `iif`/`oif`, not the bridge device: `br_nf_forward_ip` calls the IP hook with
   the physical in/out ports. D4a's `br0`↔tap example names the L3 device, which
   is not a matchable name for north-south bridged traffic. It cannot be pinned
   now: on `@terra` `bridge link` is empty and there is no `br0`/tap because the
   container is not running. `bridge-nf-call-iptables=1` confirms bridged frames
   do traverse `ip filter`. Read the pair from `bridge link` plus
   `nft -a list chain ip filter FORWARD` at the first bridge apply. This remains
   an implementation risk for the permit's interface pairs, not a contract change.

## 7. Alternatives considered

1. **Host-side `scripts/manilov/bridge-*.sh` owns the datapath** (the MVP plan's
   current shape). Rejected by F1: it is a second datapath writer, it does not
   survive image changes cleanly, and it duplicates the `@salt` logic that
   already lives in the image.
2. **Per-host image fork.** Rejected: breaks content-addressed identity (ADR
   0002) and doubles the verification surface.
3. **`DEPLOY_HOST`/hostname/env selects the mode.** Rejected: the same host can
   be reached by different names, and the mode is a property of the host, not of
   the deploy invocation.
4. **Image owns the whole firewall.** Rejected: collides with Docker and
   `INPUT_PROTECT`; a bad rule can cut SSH.
5. **No host rescue.** Rejected: a failed bridge apply could leave no remote
   path.

## 8. Supersession (MVP plan sections that must change)

The MVP plan lives in the restricted Orchestrator namespace; section titles are
cited from the task brief, line numbers are unavailable to this role.

- **Host-side `scripts/manilov/bridge-*.sh` — bridge ownership:** removed as a
  datapath writer; retained only if needed as a thin wrapper that calls the
  image applier's verbs.
- **Host-side `scripts/manilov/bridge-*.sh` — dead-man:** superseded by the
  applier `rollback`; no host dead-man script.
- **Host-side `scripts/manilov/bridge-*.sh` — persist:** superseded by the
  applier's boot-time `apply`/`status`; no host persistence script.
- **Mode selector:** superseded by the pinned, hashed marker; the plan's
  selector (including any `DEPLOY_HOST`-based branch) is withdrawn.
- **`DEPLOY_HOST`-based selection:** withdrawn everywhere; `DEPLOY_HOST` remains
  a deployment target only (consistent with `docs/StratoFrame__DeploymentPractices.md` §2).

No other plan section is superseded; image sync, container deploy, dependency
pins, and dirty-target protection are unaffected.

## 9. Migration sequence (contract level)

1. Extract the network + libvirt blocks from
   `systems/x86_64-linux/NikolaiGogol_inner/default.nix` into a shared module
   with two profiles.
2. Import the shared module from `systems/x86_64-docker/NikolaiGogol` (durable)
   and from `NikolaiGogol_inner` (edge fork); remove the duplicated blocks.
3. Add the marker contract (path, schema, allowed digests) and the
   `check`/`apply`/`confirm`/`status`/`rollback`/`watchdog` verbs.
4. Add the parity check: both configurations evaluate to identical module output
   for the same marker fixture.
5. Rebuild **one** image from the durable system; keep the previous content tag
   for rollback.
6. Verify `proxyarp` first (no host relinquish, lowest risk), then perform the
   `@terra` relinquish and verify `bridge`; run `status` after a container
   recreate and after a reboot.
7. Only then remove the old host-side bridge scripts from the plan/repo.

## 10. Validation gates

- `check` fails closed on unknown marker digest, wrong host identity, missing
  uplink, or a conflicting L3 owner.
- After `bridge` apply: `br0` owns the address and default route, MAC equals the
  uplink permanent MAC, the VM tap is enslaved, and `arping` from the LAN gets
  the bridge MAC.
- SSH on 9222 still works from the management subnet after the L3 move.
- `nft list ruleset` shows the image table/chain and an unchanged host policy,
  `INPUT_PROTECT`, and `DOCKER-*` chains.
- `status` is clean after container recreate and after reboot.
- Host rescue: the timer fires and the `eth0` address is reachable without
  touching the uplink.
- `proxyarp` and `bridge` both pass from the same image content tag.
- An unconfirmed `bridge` apply auto-reverts inside the window and leaves
  `phase=rolled-back` and `handoff.to="host"`; the rescue then restores the host
  `.network` file and the management address returns.
- The unit's state lives at `/run/manilov-network/owner.lock` and
  `/var/lib/manilov-network/{owner.json,state.json}`; no `manilov-net` path
  exists anywhere.
- `nft list ruleset` shows `MANILOV_FORWARD` in the host table that owns
  `FORWARD` (`ip filter` or `inet filter`, as recorded by the bootstrap), jumped
  from `FORWARD` before the Docker jumps, and scoped only to the declared
  interface pairs; the image tables contain only drops and no permit rule.
- With the permit absent, the applier's read-only `host-permit` verb exits **7**
  with reason `host-permit-missing` and leaves the host ruleset unchanged.

## 11. Rollback

- Image: re-run the previous content tag (ADR 0002) and `rollback` the applier.
- Bridge: `rollback` removes the VM-path rules and the tap attachment, deletes
  `br0`, and hands L3 back to the host; then remove the `Unmanaged` drop-in and
  `networkctl reload`.
- Host permit: remove the `MANILOV_FORWARD` jump, then the chain, or restore
  the backed-up pre-state; the reconciler must not re-add it while rollback is
  in effect. The image never removes it on its own — it fails closed instead.
- Host: restore the `/etc/systemd/network` archive if the drop-in restore fails.
- The host rescue remains the last resort and is independent of all of the
  above.

## 12. Prohibited changes

- The image must not flush or rewrite the host `filter` table, `DOCKER-*`
  chains, or `INPUT_PROTECT`.
- The image must not infer the mode from `DEPLOY_HOST`, hostname, `/etc/hosts`,
  or an environment variable.
- The host bootstrap must not create `br0`, move L3, or write VM-path *drops*;
  its only VM-path write is the scoped permit (D4a).
- No per-host image fork; no `network` field in the strategy schema.
- The host rescue must not touch the management uplink or the VM path.
- The marker must never select on the upstream router, gateway, or DHCP server
  identity: no router MAC, no DHCP server address, and no house-specific subnet
  in `selectorDigest`.
- The host must not pre-add a predicted subnet to `INPUT_PROTECT` as a
  precondition of the bridge apply; a wrong subnet is a rollback-and-fix (§6a.3).

**E1 / G-E1-1 prohibited (quoted from the accepted firewall-ownership
principle):**

> Prohibited: an image write into the host filter table; a permit broader than
> the declared interface pairs; host forward policy accept; disabling bridge
> netfilter callbacks to make forwarding work; a datapath change without a new
> ADR.

## 13. References

- `docs/NetworkTopology__@terra__@Manilov.md`
- `docs/NetworkTopology__@salt__@Manilov.md`
- `docs/adr/0001-HomeServer__HomeAssistant.md` (layered model)
- `docs/adr/0002-ContentAddressableImageTag.md` (one image identity)
- `docs/adr/0007-ContainerDatapathOwnership.md` (one datapath owner per host)
- `docs/StratoFrame__DeploymentPractices.md` §1–§2 (surfaces, `DEPLOY_HOST`)
- `Unix_dotfiles/systems/x86_64-linux/NikolaiGogol_inner/default.nix`
- `Unix_dotfiles/systems/x86_64-docker/NikolaiGogol/default.nix`
- `ConvPlatProv-HomeServer__HomeAssistant/Virt_scripts_bootstrap/vmDefinition.xml`
- Canonical copies (`Unix_dotfiles`, black box):
  `docs/adr/0010-manilov-network-ownership.md`,
  `docs/adr/0011-container-datapath-ownership.md` — mirrored here as
  `0006`/`0007` (D1.2).
