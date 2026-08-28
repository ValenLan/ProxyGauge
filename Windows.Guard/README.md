# ProxyGauge Guard

`ProxyGauge.Guard.exe` is a native Windows 11 service. It has no .NET runtime dependency and
runs as LocalSystem, while the WPF UI remains an ordinary user process.

## Safety contract

- Closing, crashing, or killing `ProxyGauge.exe` never sends `DISABLE`.
- If the proxy core exits, its permit path becomes unusable while the direct-connect block remains;
  traffic fails closed instead of falling back to the physical network.
- Stopping or crashing the service does not delete filters. WFP filters, the provider, and the
  sublayer are persistent objects.
- Rules match only the SID that enabled Guard. LocalSystem and other users are not part of the
  block rule.
- Loopback, the executable that owns the configured mixed-port listener, and recognized TUN
  interface LUIDs are permitted before the direct-connect block.
- Filter replacement is one WFP transaction, so an adapter refresh does not create an allow gap.
- Corrupt or unreadable enabled state is fail-closed: existing filters are preserved and status is
  reported as faulty.
- Only an authenticated owner (or an elevated administrator) can disable Guard through the pipe.
- `--emergency-off` is independent of the UI: it first stops the Guard service through SCM, then
  removes the provider's filters transactionally so reconciliation cannot re-enable them.
- MSI uninstall stops the service first and refuses to finish if emergency cleanup fails.

Guard trusts the configured proxy executable: its WFP app-ID permit also permits `DIRECT` traffic
created by that executable. ProxyGauge intentionally does not infer server IPs from transient
connections or private subscription data, so endpoint-only egress is not enabled until Mihomo can
provide a complete, verifiable transport endpoint set that can be replaced atomically.

## Required Windows 11 release tests

Run on clean x64 and ARM64 Windows 11 VMs with IPv4 and IPv6 enabled:

1. MSI install and Windows 10 / Server launch-condition rejection.
2. System-proxy mode and TUN mode with TCP, UDP, DNS, QUIC, IPv4, and IPv6 traffic.
3. Proxy core termination: all public-IP probes must fail closed.
4. UI close, Task Manager UI kill, UI crash, and user sign-out: protection must remain enabled.
5. Guard service crash: existing connections may close, but no direct public-IP probe may succeed.
6. Reboot before user sign-in, then sign in while the proxy core is still stopped: direct probes
   must remain blocked.
7. Sleep/resume, Wi-Fi/Ethernet switch, and TUN adapter recreation: service must atomically repair
   LUID permits without a direct-connect interval.
8. Explicit UI disable, elevated `--emergency-off`, uninstall, and the documented disabled-service
   reboot recovery path must each restore networking.
9. Upgrade an enabled installation: Guard must remain enabled and no MSI action may reset state.

An MSI is not release-ready merely because it compiles. All leak tests above must pass on real
Windows 11 VMs before a tagged release.
