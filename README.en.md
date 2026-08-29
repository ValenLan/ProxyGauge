# ProxyGauge

<p align="center">
  <a href="README.md">简体中文</a> · <strong>English</strong>
</p>

<p align="center">
  <img src="Resources/ProxyGauge.png" width="144" alt="ProxyGauge icon">
</p>

ProxyGauge is an open-source, native proxy health, route-verification, and leak-protection dashboard
for the latest stable releases of macOS and Windows 11. It detects the Mihomo / Clash Verge Rev core,
mixed proxy entry, system proxy, and TUN state; cross-checks the real proxy egress; and can prevent
direct-connection fallback with an optional macOS PF or Windows WFP Kill Switch. ProxyGauge ships no
proxy subscriptions or nodes and collects no telemetry.

## Features

- Native SwiftUI on macOS and native WPF on Windows
- Automatic light/dark appearance on both platforms, with High Contrast taking priority on Windows
- macOS and Windows icons generated from the same 1024 px `ProxyGauge-source.png` master asset
- Detection of the Mihomo core, mixed port, system proxy, and TUN route
- First-run discovery of the Clash Verge Rev / Mihomo local entry and traffic mode; a manual loopback
  port is requested only when discovery fails
- A traffic-entry card that reflects the real state: green for system proxy or TUN alone, orange when
  both are enabled, and gray when neither is active
- Proxy-egress cross-checking through three independent public-IP sources to detect egress drift,
  split routing, and transparent-proxy interference
- Fake-IP DNS verification (`198.18.x.x`) when TUN is active, exposing missing domain-routing rules
- A focused route test covering the core, entry, DNS, egress, and split-routing path without mixing
  third-party IP-reputation scores into the result
- A separate, opt-in IP reputation review on both platforms: four auto-detection pages plus two direct
  result pages opened only after the current proxy egress IP has been obtained
- An explainable 0–100 route score with linear progress during the test
- A topology-neutral default mode, with optional secondary egress, policy-group, and domain-rule checks
- An editable Google / Gemini / Claude chained-egress template
- Deep review in the user's default browser and real browser network path; ProxyGauge neither pins the
  browser to a node nor changes the system proxy
- A shareable Clash Verge Rev / Mihomo rule pack containing no subscription or node data
- An optional, isolated PF anchor Kill Switch on macOS
- Persistent, per-user WFP leak-protection rules maintained by a dedicated LocalSystem service on Windows
- Route-test, Kill Switch, and privileged-helper scripts embedded in the macOS App Bundle

## Platform support

| Platform | Status dashboard | Route test | Kill Switch | Artifact |
|---|---:|---:|---:|---|
| macOS 26 (Apple Silicon) | ✓ | ✓ | Optional PF anchor | `ProxyGauge.app` |
| Windows 11 x64 | ✓ | ✓ | Persistent WFP rules | Self-contained MSI |
| Windows 11 ARM64 | ✓ | ✓ | Persistent WFP rules | Self-contained MSI |

All officially released Windows 11 versions are supported. Windows 10 is explicitly rejected and does
not receive a compatibility branch.

## Install a release

Developers can install ProxyGauge globally through npm. Node.js 18 or newer is required. The package
selects the correct platform and architecture, installs the GitHub release matching the npm package
version, and verifies the installer against `SHA256SUMS.txt` from the same release:

```bash
npm install -g proxygauge
```

If npm is configured to skip lifecycle scripts, run `proxygauge install` after the global install.
Without npm, use one of the platform installers below. They install the **Latest Release**, do not build
from source, and do not install a proxy client, subscription, or node.

Apple Silicon Mac:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ValenLan/ProxyGauge/main/Scripts/install-release-macos.sh)"
```

Windows 11 (PowerShell; x64 or ARM64 is selected automatically, and MSI installation requests
administrator approval):

```powershell
irm https://raw.githubusercontent.com/ValenLan/ProxyGauge/main/Scripts/install-release-windows.ps1 | iex
```

These entry points execute the npm package or an installer script from this repository. Before running
them, consider inspecting the npm package or opening the script URL and confirming that the repository
owner is `ValenLan`. Current releases are not signed with commercial platform certificates: the macOS
app uses ad-hoc signing and is not notarized, while the Windows MSI is unsigned. Gatekeeper, SmartScreen,
and administrator-consent checks remain intact; the installers do not disable or bypass them.

## Rule pack and subscriptions

ProxyGauge deliberately keeps these separate:

- **Subscriptions** remain under the user's proxy client. ProxyGauge does not read, store, or distribute
  subscription URLs, nodes, or credentials.
- The **rule pack** lives at [`Rules/ProxyGauge-Merge.yaml`](Rules/ProxyGauge-Merge.yaml), is bundled with
  both the macOS app and Windows MSI, and can be previewed, copied, or exported from Rule Management.

The rule pack uses Clash Verge Rev `prepend-rules`, placing AI and development-site rules before a
subscription's own `GEOIP` / `MATCH` rules. It also includes the Fake-IP DNS configuration needed for
TUN. The default policy-group name is `PROXY`; replace the final column before importing when a
subscription uses a different name. Export the file, create and enable a `Merge` profile in Clash Verge
Rev, and refresh the active subscription. This makes the rules shareable while every user retains
control of their own subscription.

## macOS

### Requirements

- Latest stable macOS 26 on Apple Silicon
- A proxy client using the Mihomo core (default process name: `verge-mihomo`)
- Default mixed entry: `127.0.0.1:7890`

### Build

Building requires Xcode Command Line Tools. They are not required to run a prebuilt release.

```bash
chmod +x Scripts/*.sh
Scripts/build.sh
Scripts/package-macos.sh
open "build/ProxyGauge.app"
```

Run `Scripts/generate-icons.mjs` only after modifying the icon master; it requires Node.js and rebuilds
all icon sizes for both platforms.

The app is produced at `build/ProxyGauge.app`, and the distributable archive at
`dist/ProxyGauge-<version>-macOS-arm64.zip`. The app is ad-hoc signed and currently has neither a
Developer ID signature nor Apple notarization.

### Share a prebuilt release

Share the GitHub Release artifacts rather than the source tree, unpacked app, or `Scripts/` directory:

- `ProxyGauge-<version>-macOS-arm64.zip`
- `ProxyGauge-<version>-win-x64.msi`
- `ProxyGauge-<version>-win-arm64.msi`

Users should download the artifact for their platform together with `SHA256SUMS.txt` and verify it
before running. A Mac user can unzip the archive and move `ProxyGauge.app` to Applications; the app
already contains the route checks, rule pack, and privileged helper needed for normal GUI use.

Because the current macOS build is not notarized, Gatekeeper may block the first launch. Only after
confirming the download source and checksum should the user choose **Open Anyway** in **System Settings →
Privacy & Security**. Developer ID signing and notarization are required before broad public distribution.

On first launch, ProxyGauge tries the Mihomo local control socket, macOS system-proxy state, and Clash
Verge Rev root settings to identify the current mixed port. It then presents the detected client, local
entry, and traffic mode for one-time confirmation. Discovery extracts only the port and traffic mode;
it does not read or store subscription URLs, nodes, UUIDs, passwords, or keys. The confirmed entry is
stored in ProxyGauge's own preferences and can be rediscovered from Connection Settings.

The release contains no proxy client, subscription, node, server address, or personal configuration.
The PF Kill Switch scripts and default rules are included, but they are installed and activated only
after the user explicitly enables the switch and approves administrator access.

### Local installation

```bash
Scripts/install.sh
```

The default app location is `~/Applications/ProxyGauge.app`. Command-line and compatibility helpers are
installed at:

- `~/.local/bin/proxygauge-check`
- `~/.local/bin/proxygauge-ip-risk.jxa`
- `~/.local/bin/proxygauge-chain-check.jxa`
- `~/.local/bin/proxygauge-killswitch`
- `~/.local/share/proxygauge/`

The GUI prefers the copies embedded in its App Bundle, so moving `ProxyGauge.app` by itself does not
remove route-test or privileged-helper functionality.

### Configuration

Normal macOS GUI users do not need a configuration file. The first-run local entry is passed directly
to the scripts embedded in the app. The following file is for developer CLI usage and advanced chained
egress, and is created by the local installation script:

```text
~/.config/proxygauge/config
```

Key settings:

```bash
PROXYGAUGE_MIXED="127.0.0.1:7890"
PROXYGAUGE_EXPECT_IP=""  # Optional: verify an exact proxy egress IP
PROXYGAUGE_SECONDARY_ENABLED="0"  # Keep disabled for an ordinary single-egress setup
PROXYGAUGE_SECONDARY_LABEL="Google / Gemini / Claude"  # Editable template label
PROXYGAUGE_SECONDARY_GROUP="Google-Chain"
PROXYGAUGE_DEFAULT_GROUP="PROXY"
PROXYGAUGE_SECONDARY_MIXED="127.0.0.1:7891"
PROXYGAUGE_SECONDARY_DOMAINS="gemini.google.com,generativelanguage.googleapis.com,www.google.com,claude.ai,api.anthropic.com,platform.claude.com,bridge.claudeusercontent.com"
PROXYGAUGE_EXPECT_SECONDARY_IP=""  # Optional: verify the secondary-egress baseline
PROXYGAUGE_ACTIVE_AI_PROBES="0"  # Disabled by default: do not request any AI platform
```

Installation and runtime identifiers are limited to `com.valenlan.proxygauge`, `ProxyGauge`,
`proxygauge`, and `PROXYGAUGE_*`. The repository contains no real server address or personal
configuration.

For an enabled secondary chained egress, checking only the policy group and rule match is insufficient.
The template merges the `listeners` configuration from
[`Rules/ProxyGauge-Google-Chain-Probe.yaml`](Rules/ProxyGauge-Google-Chain-Probe.yaml) into the active
Mihomo configuration. ProxyGauge then queries the real egress through a dedicated mixed entry bound
only to `127.0.0.1:7891` and displays it beside the default egress. The example entry is fixed to
`Google-Chain`, never switches a policy group temporarily, and is not exposed to the LAN. Users can
replace its group, port, and domains under **Route Test → Profile**.

### Optional PF Kill Switch

The home-screen Kill Switch is a persistent on/off control and does not collect server IPs, interface
names, or other rule parameters. The first time it is enabled, ProxyGauge uses its embedded template to
detect the physical interface and confirm that the Mihomo core is running as a system service. In one
administrator-approved operation, it validates the anchor and a temporary main configuration, backs up
`/etc/pf.conf`, installs the rules, and enables protection. A failure at any stage leaves protection off
and rolls back that installation attempt.

Normal app launch and status refresh never request administrator access and never modify PF.

When protection is enabled, the helper installs a root-owned recovery executable at
`/Library/PrivilegedHelperTools/com.valenlan.proxygauge.killswitch` and registers
`/Library/LaunchDaemons/com.valenlan.proxygauge.killswitch.plist`. A root-only intent marker is stored at
`/var/db/proxygauge/enabled`. At boot and every 15 seconds, the LaunchDaemon validates the anchor,
physical interface, and PF enable reference. Explicitly disabling protection removes the marker, so
both enabled and disabled intent survive app exits and reboots. The UI reads the root-owned runtime
state at `/var/run/proxygauge-killswitch.state` and verifies the current boot's PF reference instead of
reusing a stale green state.

Because PF affects the entire Mac, automatic installation permits only the root-owned proxy core and
other root system services to use the physical interface. Ordinary apps must use the local proxy or
TUN, and user processes receive no separate direct port-53 exception. Enabling protection also clears
existing PF states on the physical interface so old connections are re-evaluated. CLI users can install
the same parameter-free configuration with:

```bash
Scripts/install-pf.sh
```

The script:

1. Generates `/etc/pf.anchors/proxygauge`.
2. Registers `anchor "proxygauge"` in the current `/etc/pf.conf`.
3. Validates both the anchor and system PF configuration before installation.
4. Backs up `/etc/pf.conf` to `/etc/pf.conf.proxygauge.bak` on the first run.

The CLI installer detects the interface automatically, writes only the bundled rules, and leaves
protection disabled until the user enables it in ProxyGauge. Only the `proxygauge` anchor is supported;
systems with another legacy anchor must clean it up or migrate it separately.

The Kill Switch trusts the proxy core itself. macOS PF must allow root-owned Mihomo and system services
to send traffic; Windows WFP must allow the executable that owns the mixed-port listener. Protection
therefore prevents ordinary applications from falling back to direct connections when the proxy stops,
but it cannot prevent the proxy core from choosing `DIRECT`. ProxyGauge neither reads subscriptions and
nodes nor guesses endpoint IPs from transient connections. A stricter endpoint-only mode will be added
only if the complete endpoint set can be obtained, verified, and replaced atomically.

## Windows

The Windows implementation lives in [`Windows/`](Windows/) and uses .NET 10 WPF without a third-party
UI framework.

### Use a prebuilt release

1. Download `ProxyGauge-<version>-win-x64.msi` from GitHub Releases, or
   `ProxyGauge-<version>-win-arm64.msi` on Windows ARM, and verify it with `SHA256SUMS.txt`.
2. Run the MSI and approve administrator access once to install the auto-starting Guard Service.
3. Launch ProxyGauge from the Start menu, confirm the mixed address and port, and explicitly enable
   **System Protection**.

The UI and service in the MSI are self-contained; users do not need to install .NET. SmartScreen may
warn on the first launch of the current unsigned personal build.

### Local build

Building requires the .NET 10 SDK, CMake, MSVC, and Windows 11:

```powershell
dotnet publish Windows/ProxyGauge.Windows.csproj `
  --configuration Release `
  --runtime win-x64 `
  --self-contained true
```

Windows configuration is stored at:

```text
%APPDATA%\ProxyGauge\config.json
```

Windows Guard uses the built-in Windows Filtering Platform and installs no kernel driver. When enabled,
the service creates rules only for the user who enabled protection: loopback proxy traffic, the actual
owner of the mixed-port listener, and recognized TUN interfaces are allowed, while all other direct
IPv4 and IPv6 connections are blocked. The rules are persistent WFP objects independent of the WPF UI;
closing or crashing the UI, signing out, or rebooting does not remove protection.

Only an explicit **Disable** action in the UI or the administrator recovery command permanently removes
the rules. If the UI is unavailable, run this in an elevated terminal:

```powershell
& "C:\Program Files\ProxyGauge\ProxyGauge.Guard.exe" --emergency-off
```

If that file is also damaged, run `sc.exe config ProxyGaugeGuard start= disabled` as administrator and
reboot. BFE will not load persistent rules belonging to a disabled provider service. This is a final
recovery path, not an everyday switch.

The uninstaller first stops the service and performs the same cleanup. If it cannot remove every
persistent rule, uninstallation fails instead of leaving an unrecoverable partial state.

## Releases

Every push and pull request builds and tests macOS, Windows x64, and Windows ARM64. Only a
`v<version>` tag exactly matching the app version causes the workflow to stage one macOS ZIP and two
Windows MSIs as Actions artifacts, create a GitHub Release, and upload those installers together with
`SHA256SUMS.txt`. Temporary artifacts are retained for one day; Release artifacts are retained by
GitHub. For the current version, the expected release tag is `v1.5.6`.

A tag creates a production release and must be pushed explicitly by a maintainer only after all local
tests and ordinary push CI have passed. Build scripts never create the tag. Releases are neither drafts
nor prereleases and are marked Latest; the one-line installers select only the Latest production release.

## Contributing and security reports

- See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the development environment, test requirements, and pull
  request checklist.
- Report vulnerabilities privately as described in [`SECURITY.md`](SECURITY.md). Do not include
  vulnerability details, real subscriptions, nodes, egress IPs, or personal configuration in a public issue.
- See [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) for third-party build and distribution notices.

## License

ProxyGauge is open source under the [`MIT License`](LICENSE). It permits use, copying, modification,
merging, publication, and distribution provided that copies or substantial portions retain the copyright
and license notice. The software is provided as-is, without warranty. The license itself does not replace
verification of the authorization and provenance of code, icons, copy, and third-party dependencies.

## Privacy and security

- Route tests access public IP-query and test services through the configured local proxy.
- Default route tests do not request Claude, ChatGPT, or Gemini pages or APIs. With the secondary-routing
  template enabled, rule hits are read from the local Mihomo runtime, neutral 204 URLs are used for
  latency, and the real egress is confirmed through the dedicated local entry and public IP services.
  Only macOS users who explicitly set `PROXYGAUGE_ACTIVE_AI_PROBES=1` enable active requests to the three
  AI APIs; account pages are never opened automatically.
- Egress consistency is checked through `api.ipify.org`, `ifconfig.me`, and `ip.sb`. At least two sources
  must agree. The same sources are used for an optional secondary-egress probe.
- Normal route tests do not submit the egress IP to reputation services or produce an IP-reputation score.
- IPPure, IPCheck.ing, BrowserLeaks, IPQS, Scamalytics, and AbuseIPDB are opened only after the user clicks
  the separate review action and confirms it. Some services may require a CAPTCHA. Their databases,
  definitions, and update cycles differ, so results should be read independently rather than combined
  into a false-precision score.
- After confirmation, ProxyGauge obtains the current egress IP through the configured mixed entry solely
  to build direct `scamalytics.com/ip/<IP>` and `abuseipdb.com/check/<IP>` result URLs. If the lookup fails,
  those two parameterized pages are not opened. The remaining four pages detect the visitor IP themselves.
- ProxyGauge does not read Claude, ChatGPT, or other website cookies or account data. Account status is
  never inserted into the route report.
- The route score covers the active test profile. In general mode it normalizes the core, port, entry,
  and egress stages; policy, rule, and secondary-egress weights are included only when secondary routing
  is enabled. A warning loses half the relevant weight, a failure loses all of it, and a critical entry
  failure caps the score at 49. This is not a speed, reputation, anonymity, or account-security score.
- The macOS IP reputation review uses the default browser, existing browser profile, and real browser
  network path. It neither creates a temporary profile nor changes the system proxy.
- ProxyGauge uploads no configuration, collects no telemetry, and stores no browsing history.
- macOS administrator access is limited to ProxyGauge's PF anchor and the root-owned recovery helper,
  LaunchDaemon, and enable marker described above.
- The Windows UI does not run as administrator. The MSI requests elevation only to install or remove the
  LocalSystem Guard Service, which manages its own WFP provider and sublayer without changing the
  Windows Firewall default policy.
- Never commit `~/.config/proxygauge/config`.

## Project status

ProxyGauge is a focused utility for the maintainer's current macOS and Windows 11 environments. Other
proxy clients, ports, and PF network interfaces may require configuration changes. Older operating
systems are outside the tested and maintained scope.
