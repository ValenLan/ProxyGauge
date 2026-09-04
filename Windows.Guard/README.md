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
- Loopback, LAN destinations, the explicitly selected proxy executable, and recognized TUN
  interface LUIDs are permitted before the direct-connect block. LAN includes IPv4 private and
  link-local addresses, local multicast/broadcast, and IPv6 ULA/link-local/link-local multicast.
- `ENABLE_AUTO` resolves an exact known Clash/Mihomo, iKuuu, sing-box, Xray or V2Ray core.
  The enabled system HTTPS proxy's verified local listener takes precedence. Otherwise, an active
  TUN route can select its known core even when the old client remains running. For Clash/Mihomo,
  Guard verifies the local controller pipe's server PID/path, reads the live enabled TUN device, and
  requires that device to be up and carry a representative public route. The fixed iKuuu driver
  identity similarly requires an active public route and one exact running iKuuuVPNCore path.
  With no verified active TUN, a unique running core remains the fallback. Unknown or conflicting
  tunnel identities require a choice. The service reconciles every second while protection stays on.
  Controller reads have a bounded response and deadline, allow no LocalSystem impersonation, and
  do not read credentials or subscription data. A saved TUN preference is not an active interface.
  Ambiguity keeps the previous trusted core and exposes a selection flag; the UI can replace the
  current core without disabling Guard. `ENABLE_APP` remains an explicitly pinned local executable.
- Each permit matches an executable path, not a PID or file signature. Reconciliation never
  grants an unrelated process permission merely because it takes over a local listening port.
  All instances launched from that path are trusted, including subsequent restarts.
- Filter replacement is one WFP transaction, so an adapter refresh or core handover does not first remove blocking.
- Corrupt or unreadable enabled state is fail-closed: existing filters are preserved and status is
  reported as faulty.
- Only an authenticated owner (or an elevated administrator) can disable Guard through the pipe.
- The authenticated `APPLICATIONS` command only lists bounded local paths of running proxy-related
  processes, including SYSTEM cores hidden from ordinary desktop tokens. It neither installs a
  permit nor changes selection; `ENABLE_APP` still requires an explicit choice and revalidates it.
- `--emergency-off` is independent of the UI: it first stops the Guard service through SCM, then
  removes the provider's filters transactionally so reconciliation cannot re-enable them.
- MSI uninstall stops the service first and refuses to finish if emergency cleanup fails.

Guard trusts the selected proxy executable: its WFP app-ID permit also permits `DIRECT` traffic
created by that executable. ProxyGauge intentionally does not infer server IPs from transient
connections or private subscription data, so endpoint-only egress is not enabled until Mihomo can
provide a complete, verifiable transport endpoint set that can be replaced atomically. Selecting
an application is a trust decision, not proof that its proxy switch is on. System services and
other users remain outside this legacy per-user protection boundary. This experimental build
does not claim whole-machine or universally zero-leak protection.

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
