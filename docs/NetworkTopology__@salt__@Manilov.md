# Network topology — `@salt` / `@Manilov` (Wi-Fi proxyARP)

**Status:** conceptual topology, 2026-11-02. This is **not** an evidence
snapshot: the `@salt` connection details are not verified from this repository.
The document exists to show *when* the Wi-Fi proxyARP approach is the right one
and *how to debug it step by step*. It uses **variables only** — no concrete IP
addresses, gateways, or DNS servers. The real values are decided during
deployment and belong to the host configuration and the operator's environment.

- Companion (Ethernet bridge): [`docs/NetworkTopology__@terra__@Manilov.md`](NetworkTopology__@terra__@Manilov.md)
- Diagram: [`docs/_diagrams/NetworkTopology__@salt__@Manilov.puml`](_diagrams/NetworkTopology__@salt__@Manilov.puml)
- Existing declaration: `Unix_dotfiles/systems/x86_64-linux/NikolaiGogol_inner/default.nix`

## When to use this approach

Use Wi-Fi proxyARP when:

- the host has **only a Wi-Fi uplink**, and the interface is a station
  (`802.11`), not an AP or a 4-address/WDS link;
- the VM needs L3 reachability from the LAN, but not full L2 adjacency;
- the LAN does not require the VM to answer broadcast or multicast traffic
  (mDNS, SSDP, ARP for other hosts);
- the host can enable IPv4 forwarding and proxy ARP, and can carry the VM's
  traffic as a router.

Do **not** use it when:

- an Ethernet uplink is available that can be enslaved to a bridge — use
  [`docs/NetworkTopology__@terra__@Manilov.md`](NetworkTopology__@terra__@Manilov.md);
- the VM must be a full L2 peer (broadcast, multicast, mDNS/SSDP discovery);
- host policy forbids forwarding, proxy ARP, or firewall changes.

The reason is L2: a Wi-Fi station interface cannot be a bridge port without
4-address/WDS support. Proxy ARP is the workaround — the host answers ARP on
behalf of the VM and routes the traffic to a tap device.

## Concept

```
@Manilov VM ── virtio NIC ── ${SALT_TAP_NAME} ── host proxyARP + IPv4 forward ── ${SALT_WLAN_IF} ── Wi-Fi AP ── LAN
```

- `@NikolaiGogol` runs with `network_mode: host`, so the tap and the proxy ARP
  settings act in the `@salt` host network namespace.
- `${SALT_WLAN_IF}` keeps the host's L3 configuration. The host does **not**
  lose its address and does **not** become a bridge.
- `${SALT_TAP_NAME}` is a virtual L2 port with its own address
  (${SALT_TAP_ADDRESS}/${SALT_TAP_PREFIX}). The VM is attached to it with
  libvirt `type='ethernet'`, `target dev='${SALT_TAP_NAME}'`, `managed='no'`.
- `proxy_arp=1` on both `${SALT_WLAN_IF}` and `${SALT_TAP_NAME}`; the host
  answers ARP for `${MANILOV_IP}` on the Wi-Fi link.
- `net.ipv4.ip_forward=1` plus FORWARD rules for
  `${SALT_TAP_NAME} ↔ ${SALT_WLAN_IF}` carry the packets.

The LAN sees the host's MAC (${SALT_WLAN_MAC}), not the VM's
(${MANILOV_MAC}). The VM is one routed hop behind the host, even though it
shares the subnet.

## Topology

The diagram shows the conceptual path:

1. the Wi-Fi AP / LAN segment and the L3 gateway;
2. `@salt` with the Wi-Fi uplink and the tap;
3. the `@NikolaiGogol` container boundary (`network_mode: host`) with libvirt;
4. the `@Manilov` virtio NIC.

## Variable → where the value lives

| Variable | Meaning | Where the value lives |
|---|---|---|
| `${SALT_HOST}` | The `@salt` host | `Unix_dotfiles` host profile |
| `${SALT_WLAN_IF}` | Wi-Fi station interface (currently `wlan0`) | `Unix_dotfiles` host profile |
| `${SALT_WLAN_MAC}` | MAC the LAN sees for the host / proxy ARP | Host configuration |
| `${SALT_WLAN_IP}` | Host L3 address on the Wi-Fi link | Host configuration |
| `${SALT_LAN_PREFIX}` | LAN prefix shared by host and VM | Host configuration |
| `${SALT_GW}` | Default gateway / DHCP server | Host configuration |
| `${SALT_DNS}` | DNS servers | Host configuration |
| `${SALT_TAP_NAME}` | Tap device (currently `tap0`) | `Unix_dotfiles` declaration |
| `${SALT_TAP_ADDRESS}` | Tap address used for proxy ARP | `Unix_dotfiles` declaration |
| `${SALT_TAP_PREFIX}` | Tap prefix length (typically `/32`) | `Unix_dotfiles` declaration |
| `${MANILOV_VM_NAME}` | libvirt domain name (currently `hass_qemu16`) | `Virt_scripts_bootstrap/vmDefinition.xml` |
| `${MANILOV_MAC}` | `@Manilov` virtio NIC MAC | `Virt_scripts_bootstrap/vmDefinition.xml` |
| `${MANILOV_IP}` | `@Manilov` address in `${SALT_LAN_PREFIX}` | DHCP / host configuration |
| `${NIKOLAIGOGOL_CONTAINER}` | Container name | `group_vars/nikolaigogol/vars.yml` |
| `${LIBVIRT_URI}` | libvirt connection URI | Container image / `Virt_scripts_bootstrap` |

The values are **not asserted here**. They are decided in the deployment
process; this document only fixes the variable names and the shape.

## Limitations

- Proxy ARP answers ARP only. Broadcast and multicast are not transparent:
  mDNS and SSDP discovery from the LAN will usually fail. Plan for unicast
  configuration or a reflector if discovery is required.
- The VM must use an address inside `${SALT_LAN_PREFIX}`; the host proxies ARP
  for it. A different subnet needs routing, not proxy ARP.
- The host becomes a router for the VM: forwarding and firewall rules are part
  of the approach, not an afterthought.
- Wi-Fi roaming, power saving, and reassociation can drop the tap path; the
  proxy ARP/forwarding state must be reasserted after reconnect.
- The VM's MAC is not visible on the Wi-Fi L2; the host's MAC is.

## Debug ladder (proxyARP)

Run these in order; stop at the first failure.

1. **Wi-Fi link.** `ip -br link show ${SALT_WLAN_IF}` — UP. `iw dev ${SALT_WLAN_IF} link` — associated, with a signal.
2. **Host L3.** `ip -br addr show ${SALT_WLAN_IF}`, `ip route show default`, `ping -c3 ${SALT_GW}`, DNS resolution.
3. **Tap.** `ip -br link show ${SALT_TAP_NAME}` — exists and UP. `ip -br addr show ${SALT_TAP_NAME}` — has `${SALT_TAP_ADDRESS}/${SALT_TAP_PREFIX}`.
4. **Proxy ARP.** `sysctl net.ipv4.conf.${SALT_WLAN_IF}.proxy_arp` and `net.ipv4.conf.${SALT_TAP_NAME}.proxy_arp` — both `1`.
5. **Forwarding.** `sysctl net.ipv4.ip_forward` — `1`. `nft list ruleset` or `iptables-save` — FORWARD rules for `${SALT_TAP_NAME} ↔ ${SALT_WLAN_IF}`. Check `rp_filter`.
6. **libvirt attachment.** `virsh -c ${LIBVIRT_URI} domiflist ${MANILOV_VM_NAME}` — interface `type='ethernet'`, `target dev='${SALT_TAP_NAME}'`, `managed='no'`.
7. **ARP from the LAN.** From another LAN host: `arping ${MANILOV_IP}` — the reply must come from `${SALT_WLAN_MAC}` (the host), not from `${MANILOV_MAC}`.
8. **VM.** `virsh -c ${LIBVIRT_URI} console ${MANILOV_VM_NAME}` or `domifaddr`; inside the VM `ip addr`, `ping ${SALT_GW}`, DNS.
9. **Discovery.** If mDNS/SSDP fails, that is expected for this approach. Confirm unicast reachability first; then decide whether a reflector is needed.

## Related

- [`docs/NetworkTopology__@terra__@Manilov.md`](NetworkTopology__@terra__@Manilov.md) — the Ethernet bridge approach used on `@terra`.
- `docs/_references/@Manilov__NetworkDecision.md` — the bridge decision note.
- `Unix_dotfiles/systems/x86_64-linux/NikolaiGogol_inner/default.nix` — the existing `tap0` / `proxyARP` / `wlan0` declaration.
