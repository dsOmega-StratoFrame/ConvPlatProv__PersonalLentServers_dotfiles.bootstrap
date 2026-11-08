# Network Decision

- on @salt we have to continue using wlan0 (it's the only available ntework
interface)
- on @terra I choose a bridge approach. It's well documented in NixOs wiki, see
[related parts](./NetworkDecision__Bridge.md).
- during our mvp, on terra directly via ssh apply ... After that I expect
a repo of ConvPlatProv__HomeAssistant + @NikolaiGogol host in Nix refactored to
conditionally work for both cases (without changing image contents)
