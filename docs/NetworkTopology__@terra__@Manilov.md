# Network topology — `@terra` / `@Manilov`

**Status:** evidence snapshot, 2026-11-02. **No design decision is made here.**

This document describes the observed network shape of `@terra` (TOS 6) and the
placement of the `@Manilov` VM / `@NikolaiGogol` container boundary. It uses
**variables only**: it contains no concrete IP addresses, gateways, or DNS
servers. The values behind the variables live in the Logseq research note, not
in this repository.

- Evidence note: `ai-rsh Researcher_system/MANILOV-MVP-001 @terra network research (2026.11.02)`
- Raw probe output: `logs/network-research-20261102T164715Z/` (git-ignored)
- Diagram: [`docs/_diagrams/NetworkTopology__@terra__@Manilov.puml`](_diagrams/NetworkTopology__@terra__@Manilov.puml)

## Observed facts (2026-11-02)

- Two physical Ethernet slots, both Aquantia `1d6a:14c0`:
  - `${TERRA_NIC_1}` — PCI `02:00.0`, permanent MAC `${TERRA_NIC_1_MAC}`,
    admin-UP but **no carrier**; no address.
  - `${TERRA_NIC_2}` — PCI `03:00.0`, permanent MAC `${TERRA_MGMT_MAC}`,
    **connected** at 2.5 Gb/s.
- Neither slot is wireless. `wwan0`/`wwan1` are WWAN modem pseudo-interfaces
  and are down; there is no `wlan0`.
- L3 is owned by `systemd-networkd`, **DHCP** on `${TERRA_MGMT_NIC}`
  (`${TERRA_MGMT_IP}`, prefix `${TERRA_LAN_PREFIX}`, gateway
  `${TERRA_GW}`, DNS `${TERRA_DNS}`). NetworkManager is not installed.
- There is **no `${BRIDGE_NAME}`**, no `tap0`, and no `virbr*` on the host
  today. The only bridge device is Docker's `docker0`.
- `libvirtd` is inactive on the host and `/var/lib/libvirt` is absent: libvirt
  is expected to run inside the `@NikolaiGogol` container, which does not exist
  yet.
- `br_netfilter` is built into the kernel and
  `net.bridge.bridge-nf-call-* = 1`; the nft `FORWARD` chain policy is `drop`.
- `rp_filter = 2` (loose) on all interfaces.
- `sshd` listens on port `9222` on all IPv4 and IPv6 interfaces (not 22).
- DHCP client-id policy is `ClientIdentifier=mac`; the lease client-id is the
  `eth1` MAC.

## When to use this approach

Use the bridge approach when:

- the host has an **Ethernet** uplink that can be enslaved to a Linux bridge;
- the VM must be a full L2 peer on the LAN (ARP, broadcast, multicast, mDNS,
  SSDP);
- host ↔ VM traffic must work without routing or proxy ARP.

Do **not** use it when the only uplink is Wi-Fi in station mode; 802.11 cannot
be a bridge port. Use the `@salt` approach instead:
[`docs/NetworkTopology__@salt__@Manilov.md`](NetworkTopology__@salt__@Manilov.md).

## Topology

The diagram shows the observed state and the intended placement:

1. the two PCI slots and the connected management NIC;
2. the target `${BRIDGE_NAME}` with the libvirt-managed tap and the `@Manilov`
   virtio NIC, inside the `@NikolaiGogol` container boundary
   (`network_mode: host`).

Elements drawn as *not present* are explicitly marked in the diagram.

## Debug ladder (bridge)

Run these in order; stop at the first failure.

1. **Link.** `ip -br link show ${TERRA_MGMT_NIC}` — admin-UP, carrier 1.
2. **L3 before the move.** `ip -br addr show ${TERRA_MGMT_NIC}`,
   `ip route show default`, `ping -c3 ${TERRA_GW}`.
3. **Bridge exists.** `ip -br link show type bridge`; `bridge link` — the
   uplink must be a port of `${BRIDGE_NAME}`, and `${BRIDGE_NAME}` must own the
   address and the default route.
4. **L2 identity.** `ip -br link show ${BRIDGE_NAME}` — the MAC must equal the
   uplink's permanent MAC (`ethtool -P ${TERRA_MGMT_NIC}`).
5. **ARP.** From another LAN host: `arping ${TERRA_MGMT_IP}` — the reply must
   come from the bridge MAC.
6. **SSH.** From the control node: `ssh terra@terra-local` (port 9222). If the
   management subnet changed, `INPUT_PROTECT` will drop it; this is the first
   thing to check.
7. **Netfilter.** `sysctl net.bridge.bridge-nf-call-*`; `nft list ruleset` (or
   `iptables-save`) — the VM's traffic needs explicit FORWARD rules.
8. **VM port.** `virsh -c ${LIBVIRT_URI} domiflist ${MANILOV_VM_NAME}` — the
   interface must be `type='bridge'` with `source bridge='${BRIDGE_NAME}'`.
9. **VM L3.** From the VM: `ip addr`, `ping ${TERRA_GW}`, DNS.
10. **Survives reboot/recreate.** Recreate the container, then repeat 3–8; the
    bridge and the VM attachment must return without manual `ip` commands.

## Variable → where the value lives

| Variable | Meaning | Where the value lives |
|---|---|---|
| `${TERRA_NIC_1}` | First physical slot (`02:00.0`), unconnected | Logseq note, Cell 2 / Variable map |
| `${TERRA_NIC_2}` | Second physical slot (`03:00.0`) | Logseq note, Cell 2 / Variable map |
| `${TERRA_NIC_1_MAC}` | Permanent MAC of `${TERRA_NIC_1}` | Logseq note, Cell 2 / Variable map |
| `${TERRA_MGMT_NIC}` | NIC carrying the management address | Logseq note, Cells 2–3 / Variable map |
| `${TERRA_MGMT_MAC}` | Permanent MAC of `${TERRA_MGMT_NIC}` | Logseq note, Cell 2 / Variable map |
| `${TERRA_LAN_PREFIX}` | Management L2/L3 prefix | Logseq note, Cell 3 / Variable map |
| `${TERRA_GW}` | Default gateway / DHCP server | Logseq note, Cell 3 / Variable map |
| `${TERRA_DNS}` | DNS servers pushed by DHCP | Logseq note, Cell 3 / Variable map |
| `${TERRA_MGMT_IP}` | Management address of `@terra` | Logseq note, Cell 3 / Variable map |
| `${TERRA_RESCUE_IP}` | Candidate rescue address (unassigned) | Logseq note, Finding 11 / Variable map |
| `${BRIDGE_NAME}` | Target bridge name (proposed) | Logseq note, Cell 5 / Variable map |
| `${MANILOV_MAC}` | `@Manilov` virtio NIC MAC (from RFC-0001 intent) | Logseq note, Variable map |
| `${MANILOV_IP}` | `@Manilov` address (unreserved) | Logseq note, Cell 8 / Variable map |
| `${DOCKER_BRIDGE_IP}` | Docker default bridge address | Logseq note, Cell 3 / Variable map |

## Ownership and reassertion

| Surface | Owner | Can reassert the NIC? |
|---|---|---|
| L3 addressing | `systemd-networkd` + per-MAC `/etc/systemd/network/10-eth*.network` | Yes, on reboot and on `networkctl reconfigure` |
| TOS UI | `TOSDaemon` (+ `/etc/tos/scripts/setgateway`) | Plausible via default-gateway/route rewrite; no evidence it rewrites the `.network` files |
| Link bring-up | `netplug` / `networkd-dispatcher` | Auxiliary; not the L3 owner |
| Containers | Docker (`cgroup` v2, `overlayfs`) | No containers currently defined |
| VMs | libvirt inside `@NikolaiGogol` | Container absent; `virsh` absent on host |

## What is not established

- Whether `${TERRA_NIC_1}` can hold `${TERRA_RESCUE_IP}`: capability only, not
  tested (assigning it would be a mutation).
- Whether the DHCP server reserves `${TERRA_MGMT_IP}` or `${MANILOV_IP}` by MAC.
- How a TOS update rewrites `/etc/systemd/network`.
- Any concrete `@Manilov` address; the DHCP lease is not reserved today.

## Related

- `docs/_references/@Manilov__NetworkDecision.md` — the bridge decision note.
- `docs/_references/NetworkDecision__BridgeToConnectManilovToInternet.md` —
  upstream NixOS bridge example (assumes `eno1`; `@terra` is TOS 6).
- `docs/rfc/RFC-0001-edge-iteration-workflow.md` — `tap0` / `--network none`
  discrepancy for `@Manilov`.
- [`docs/NetworkTopology__@salt__@Manilov.md`](NetworkTopology__@salt__@Manilov.md)
  — the Wi-Fi proxyARP approach used on `@salt`.
