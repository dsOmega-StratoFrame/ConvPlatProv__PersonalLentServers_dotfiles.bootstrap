# Network Bridge to connect @Manilov to Internet
[Source][@/MymenoNixOSHeadless]|[Zotero][z@/MymenoNixOSHeadless]

## NixOS configuration
The NixOS configuration exposes options to define bridge interfaces. The following snippet from configuration.nix defines a bridge interface br0 and binds a static IP to it. This bridge device should be connected to the physical interface (e.g. eno1) through networking.bridges:

# /etc/nixos/configuration.nix
networking.defaultGateway = "10.0.0.1";
networking.bridges.br0.interfaces = ["eno1"];
networking.interfaces.br0 = {
  useDHCP = false;
  ipv4.addresses = [{
    "address" = "10.0.0.5";
    "prefixLength" = 24;
  }];
};
Once the configuration is applied ip addr show would list something similar to the following:

❯ ip a
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
2: eno1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel master br0 state UP group default qlen 1000
    link/ether 1c:69:7a:ab:e7:ae brd ff:ff:ff:ff:ff:ff
3: br0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    link/ether 1c:69:7a:ab:e7:ae brd ff:ff:ff:ff:ff:ff
    inet 10.0.0.5/24 scope global br0
       valid_lft forever preferred_lft forever
There we see both the physical eno1 interface and the br0 bridge.

## References
[@/MymenoNixOSHeadless]: <https://myme.no/posts/2021-11-25-nixos-home-assistant.html> 'Myme.No - NixOS: Headless Home Assistant VM'
[z@/MymenoNixOSHeadless]: <zotero://select/items/@/MymenoNixOSHeadless> 'Select in Zotero: Myme.No - NixOS: Headless Home Assistant VM'
