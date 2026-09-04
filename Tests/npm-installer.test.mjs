import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

import {
  detectedArchitecture,
  installCommand,
  nativeInstallerEnvironment,
  packageVersion,
  projectRoot,
  resolveHardwareArchitecture,
  resolveWindowsRuntime,
  shouldRunPostinstall
} from "../Scripts/proxygauge-npm-lib.mjs";
import {
  downloadCommand,
  elevatedBootstrapCommand,
  elevatedWorkerCommand,
  elevationLauncherCommand,
  encodeElevatedWorker,
  exactAsset,
  expectedChecksum,
  materializeElevatedBootstrap,
  materializeElevatedWorker,
  nativeArchitectureCommand,
  noProxyMatches,
  proxySettingsFor,
  runtimeForNativeMachine,
  sanitizedCmdArguments,
  systemCmdPath,
  systemPowerShellPath,
  temporaryBaseCandidate,
  temporaryDirectoryValidationCommand
} from "../Scripts/install-release-windows.mjs";

const packageMetadata = JSON.parse(
  readFileSync(resolve(projectRoot, "package.json"), "utf8")
);

test("npm manifest publishes only the formal-channel installers and package entry", () => {
  assert.deepEqual(packageMetadata.os, ["darwin", "win32"]);
  assert.deepEqual(packageMetadata.cpu, ["arm64", "x64", "ia32"]);
  assert.deepEqual(packageMetadata.files, [
    "LICENSE",
    "README.md",
    "THIRD-PARTY-NOTICES.md",
    "Scripts/install-release-macos.sh",
    "Scripts/install-release-windows.mjs",
    "Scripts/install-release-windows.ps1",
    "Scripts/proxygauge-npm-lib.mjs",
    "Scripts/proxygauge-npm.mjs"
  ]);
  assert.deepEqual(packageMetadata.bin, {
    proxygauge: "Scripts/proxygauge-npm.mjs"
  });
  assert.deepEqual(packageMetadata.publishConfig, {
    access: "public",
    registry: "https://registry.npmjs.org/"
  });
});

test("Windows installer carries a UTF-8 BOM for Windows PowerShell 5.1", () => {
  const installer = readFileSync(
    resolve(projectRoot, "Scripts/install-release-windows.ps1")
  );
  assert.deepEqual([...installer.subarray(0, 3)], [0xef, 0xbb, 0xbf]);
});

test("shell and PowerShell variables are delimited before non-ASCII prose", () => {
  const scripts = [
    "Scripts/install-release-macos.sh",
    "Scripts/install-release-windows.ps1",
    "Scripts/proxygauge-check.sh",
    "Scripts/proxygauge-killswitch"
  ];
  const unsafeInterpolation = /\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]/gu;
  for (const script of scripts) {
    const source = readFileSync(resolve(projectRoot, script), "utf8");
    assert.doesNotMatch(source, unsafeInterpolation, script);
  }
});

test("standalone Windows installer crosses UAC with a protected hash-checked worker", () => {
  const installer = readFileSync(
    resolve(projectRoot, "Scripts/install-release-windows.ps1"),
    "utf8"
  );
  assert.match(installer, /SpecialFolder\]::ProgramFiles/);
  assert.match(installer, /\[Environment\]::SystemDirectory/);
  assert.match(installer, /SHA256\]::Create\(\)/);
  assert.match(installer, /IsWow64Process2/);
  assert.match(installer, /ScriptBlock\]::Create\(\$ElevatedWorker\)/);
  assert.match(installer, /ScriptBlock\]::Create\(\$ElevatedBootstrap\)/);
  assert.match(installer, /__PROXYGAUGE_WORKER_SHA256_UTF8__/);
  assert.match(installer, /\$SanitizedWorkerArguments\.Length -gt 8000/);
  assert.match(installer, /\[Uri\]::TryCreate\(\$ProxyText/);
  assert.match(installer, /DriveType -ne \[IO\.DriveType\]::Fixed/);
  assert.match(installer, /IO\.FileAttributes\]::ReparsePoint/);
  assert.match(installer, /Assert-LocalFixedDirectory \(\[IO\.Path\]::GetTempPath\(\)\)/);
  assert.match(installer, /__PROXYGAUGE_EXPECTED_SHA256_UTF8__/);
  assert.match(installer, /\[IO\.File\]::Copy\(\$SourceMsi, \$SecureMsi/);
  assert.match(installer, /\$StartInfo\.FileName = \$CmdPath/);
  assert.match(installer, /DOTNET_STARTUP_HOOKS/);
  assert.match(installer, /\[UInt16\]\$NativeMachine/);
  assert.match(installer, /\[Net\.ServicePointManager\]::SecurityProtocol = \$PreviousSecurityProtocol/);
  assert.doesNotMatch(installer, /GetCurrentProcess\(\)\.MainModule\.FileName/);
  assert.doesNotMatch(installer, /WriteAllText\(\$ResultPath/);
  assert.doesNotMatch(installer, /-FilePath "msiexec\.exe"|Get-FileHash|Invoke-WebRequest/);

  // Exercise the workflow's actual extraction expression, including the indented
  // worker definition. Parsing the outer file alone does not parse here-string code.
  const workflow = readFileSync(resolve(projectRoot, ".github/workflows/build.yml"), "utf8");
  const quotedExpression = workflow.match(/^\s*'(\(\?ms\).+)'\r?$/m)?.[1];
  assert.ok(quotedExpression, "workflow must expose its embedded-script extraction check");
  const expression = quotedExpression.replaceAll("''", "'").replace(/^\(\?ms\)/, "");
  for (const newline of ["\n", "\r\n"]) {
    const source = installer.replace(/\r?\n/g, newline);
    const embedded = [...source.matchAll(new RegExp(expression, "gms"))];
    assert.deepEqual(embedded.map(match => match[1]), [
      "ArchitectureCommand", "ElevatedWorker", "ElevatedBootstrap"
    ]);
    assert.ok(embedded.every(match => match[2].trim().length > 0));
  }
});

test("npm package version matches both native applications", () => {
  const plist = readFileSync(resolve(projectRoot, "Info.plist"), "utf8");
  const macVersion = plist.match(
    /<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/
  )?.[1];
  const macBuild = plist.match(
    /<key>CFBundleVersion<\/key>\s*<string>([^<]+)<\/string>/
  )?.[1];
  const windowsProject = readFileSync(
    resolve(projectRoot, "Windows/ProxyGauge.Windows.csproj"),
    "utf8"
  );
  const windowsVersion = windowsProject.match(/<Version>([^<]+)<\/Version>/)?.[1];

  assert.equal(packageVersion(), packageMetadata.version);
  assert.equal(macVersion, packageMetadata.version);
  assert.equal(macBuild, "56");
  assert.equal(windowsVersion, packageMetadata.version);
});

test("installer selection is explicit for every supported target", () => {
  assert.equal(installCommand("darwin", "arm64").executable, "/bin/bash");
  assert.equal(installCommand("darwin", "arm64").arguments[0], "-p");
  assert.match(
    installCommand("darwin", "arm64").arguments.at(-1),
    /install-release-macos\.sh$/
  );
  assert.equal(installCommand("win32", "x64").executable, process.execPath);
  assert.equal(installCommand("win32", "arm64").executable, process.execPath);
  assert.match(installCommand("win32", "x64").arguments.at(-1), /install-release-windows\.mjs$/);
  assert.throws(() => installCommand("darwin", "x64"), /不支持当前平台/);
  assert.throws(() => installCommand("linux", "x64"), /不支持当前平台/);
});

test("native installer children receive only the environment required by the formal channel", () => {
  const hostile = {
    HOME: "/Users/example",
    TMPDIR: "/private/tmp/example/",
    TEMP: "C:\\Users\\example\\Temp",
    TMP: "C:\\Users\\example\\Temp",
    SystemRoot: "C:\\Windows",
    WINDIR: "C:\\Windows",
    HTTPS_PROXY: "http://proxy.example:8080",
    NO_PROXY: "github.com",
    ALL_PROXY: "socks5://proxy.example:1080",
    NODE_OPTIONS: "--require=C:\\attacker.js",
    NODE_PATH: "C:\\attacker-modules",
    BASH_ENV: "/tmp/attacker.sh",
    ENV: "/tmp/attacker.sh",
    CURL_HOME: "/tmp/attacker-curl",
    CURL_CA_BUNDLE: "/tmp/attacker-ca.pem",
    SSL_CERT_FILE: "/tmp/attacker-ca.pem",
    DYLD_INSERT_LIBRARIES: "/tmp/attacker.dylib",
    PROXYGAUGE_VERSION: "0.0.1"
  };

  const windows = nativeInstallerEnvironment("win32", hostile, "1.6.3");
  assert.equal(windows.PROXYGAUGE_VERSION, "1.6.3");
  assert.equal(windows.SystemRoot, "C:\\Windows");
  assert.equal(windows.TEMP, "C:\\Users\\example\\Temp");
  assert.equal(windows.HTTPS_PROXY, "http://proxy.example:8080");
  assert.equal(windows.NO_PROXY, "github.com");
  assert.equal(windows.NODE_OPTIONS, undefined);
  assert.equal(windows.NODE_PATH, undefined);
  assert.equal(windows.ALL_PROXY, undefined);

  const mac = nativeInstallerEnvironment("darwin", hostile, "1.6.3");
  assert.equal(mac.PROXYGAUGE_VERSION, "1.6.3");
  assert.equal(mac.HOME, "/Users/example");
  assert.equal(mac.TMPDIR, "/private/tmp/example/");
  assert.equal(mac.ALL_PROXY, "socks5://proxy.example:1080");
  assert.equal(mac.HTTPS_PROXY, "http://proxy.example:8080");
  for (const name of [
    "NODE_OPTIONS",
    "NODE_PATH",
    "BASH_ENV",
    "ENV",
    "CURL_HOME",
    "CURL_CA_BUNDLE",
    "SSL_CERT_FILE",
    "DYLD_INSERT_LIBRARIES"
  ]) {
    assert.equal(mac[name], undefined, `${name} must not cross into the native installer`);
  }
});

test("Rosetta Node resolves the underlying Apple Silicon architecture", () => {
  assert.equal(resolveHardwareArchitecture("darwin", "x64", "1\n"), "arm64");
  assert.equal(resolveHardwareArchitecture("darwin", "x64", "0\n"), "x64");
  assert.equal(resolveHardwareArchitecture("win32", "x64", "1\n"), "x64");
});

test("Windows installer selects the native architecture under emulation", () => {
  assert.equal(resolveWindowsRuntime({ PROCESSOR_ARCHITECTURE: "AMD64" }, "x64"), "win-x64");
  assert.equal(resolveWindowsRuntime({ PROCESSOR_ARCHITECTURE: "AMD64" }, "ia32"), "win-x64");
  assert.equal(resolveWindowsRuntime({ PROCESSOR_ARCHITEW6432: "ARM64" }, "x64"), "win-arm64");
  assert.equal(resolveWindowsRuntime({}, "arm64"), "win-arm64");
  assert.throws(() => resolveWindowsRuntime({}, "ia32"), /不支持的 Windows 架构/);
  assert.equal(
    detectedArchitecture("win32", "ia32", { PROCESSOR_ARCHITECTURE: "AMD64" }),
    "x64"
  );
  assert.ok(packageMetadata.cpu.includes("ia32"));
  assert.match(systemPowerShellPath({ SystemRoot: "C:\\Windows" }), /^C:\\Windows\\/u);
  assert.throws(
    () => systemPowerShellPath({ SystemRoot: "D:\\UserControlled" }),
    /系统目录不是受支持的/
  );
});

test("Windows npm staging accepts only a verified local fixed non-reparse temp path", () => {
  assert.equal(
    temporaryBaseCandidate({ TEMP: "C:\\Primary", TMP: "D:\\Secondary" }, "E:\\Fallback"),
    "C:\\Primary"
  );
  assert.equal(
    temporaryBaseCandidate({ TEMP: "", tmp: "D:\\Secondary" }, "E:\\Fallback"),
    "D:\\Secondary"
  );
  assert.equal(temporaryBaseCandidate({}, "E:\\Fallback"), "E:\\Fallback");
  assert.match(temporaryDirectoryValidationCommand, /DriveType\]::Fixed/u);
  assert.match(temporaryDirectoryValidationCommand, /FileAttributes\]::ReparsePoint/u);
  assert.match(temporaryDirectoryValidationCommand, /GetFullPath/u);
  assert.match(temporaryDirectoryValidationCommand, /ToBase64String/u);

  const installer = readFileSync(
    resolve(projectRoot, "Scripts/install-release-windows.mjs"),
    "utf8"
  );
  assert.match(installer, /const temporaryBase = validatedTemporaryBase\(process\.env\)/u);
  assert.match(installer, /resolveNativeWindowsRuntimeAtBase\(process\.env, temporaryBase\)/u);
  assert.doesNotMatch(installer, /mkdtempSync\(join\(tmpdir\(\), "proxygauge-release-"\)\)/u);
});

test("Windows npm transport uses the system proxy path without script-policy bypasses", () => {
  const installer = readFileSync(
    resolve(projectRoot, "Scripts/install-release-windows.mjs"),
    "utf8"
  );
  assert.match(installer, /\[Net\.HttpWebRequest\]::Create/);
  assert.match(installer, /"-Command", downloadCommand/);
  assert.match(installer, /ReadWriteTimeout = \$remainingMilliseconds/);
  assert.match(installer, /PROXYGAUGE_DOWNLOAD_MAXIMUM_BYTES/);
  assert.match(installer, /PROXYGAUGE_DOWNLOAD_NO_PROXY/);
  assert.match(installer, /Net\.NetworkCredential\]::new/);
  assert.match(installer, /\$credentialDomain/);
  assert.match(installer, /npm_config_https_proxy/);
  assert.match(installer, /\$startInfo\.Verb = 'RunAs'/);
  assert.match(installer, /\[Environment\]::SystemDirectory/);
  assert.match(installer, /SHA256\]::Create\(\)/);
  assert.match(installer, /\$PSModuleAutoLoadingPreference = 'None'/);
  assert.match(installer, /SpecialFolder\]::ProgramFiles/);
  assert.match(installer, /\[0, 1641, 3010\]/);
  assert.match(installer, /IsWow64Process2/);
  assert.match(installer, /\.\.\.selectedWindowsEnvironment\(environment\),\s+PROXYGAUGE_SYSTEM_CMD/s);
  assert.match(installer, /PROXYGAUGE_DOWNLOAD_RETURN_BASE64/);
  assert.match(installer, /materializeElevatedWorker/);
  assert.match(installer, /Decode-Payload/);
  assert.doesNotMatch(installer, /PROXYGAUGE_VERSION: version|PROXYGAUGE_RUNTIME: runtime/);
  assert.doesNotMatch(installer, /env:PROXYGAUGE_(?:MSI_PATH|EXPECTED_SHA256)/);
  assert.doesNotMatch(
    installer,
    /env:\s*\{\s*\.\.\.environment,\s*PROXYGAUGE_SYSTEM_POWERSHELL/s
  );
  assert.doesNotMatch(
    installer,
    /ExecutionPolicy|Set-MpPreference|https\.get|DefaultNetworkCredentials|UseDefaultCredentials|"-File"|spawnSync\(\s*["']powershell\.exe|FilePath 'msiexec\.exe'/s
  );
});

test("Windows protected staging reports cleanup failures instead of silently succeeding", () => {
  assert.match(elevatedWorkerCommand, /\$cleanupFailed = \$false/u);
  assert.match(elevatedWorkerCommand, /catch \{ \$cleanupFailed = \$true \}/u);
  assert.match(elevatedWorkerCommand, /if \(\$cleanupFailed\) \{ return 1 \}/u);
  assert.match(elevatedBootstrapCommand, /\$cleanupFailed = \$false/u);
  assert.match(elevatedBootstrapCommand, /catch \{ \$cleanupFailed = \$true \}/u);
  assert.match(elevatedBootstrapCommand, /if \(\$cleanupFailed\) \{ \$exitCode = 1 \}/u);
  assert.match(elevatedWorkerCommand, /WaitForExit\(1800000\)/u);
  assert.doesNotMatch(elevatedWorkerCommand, /\$installer\.WaitForExit\(\)/u);
  assert.match(elevatedWorkerCommand, /File\]::Delete\(\$secureMsi\)/u);
  assert.match(elevatedBootstrapCommand, /File\]::Delete\(\$secureWorker\)/u);
  assert.doesNotMatch(
    `${elevatedWorkerCommand}\n${elevatedBootstrapCommand}`,
    /Directory\]::Delete\([^\n]+, \$true\)/u
  );

  const installer = readFileSync(
    resolve(projectRoot, "Scripts/install-release-windows.mjs"),
    "utf8"
  );
  assert.match(installer, /function removeKnownTemporaryDirectory/u);
  assert.match(installer, /lstatSync\(directory\)/u);
  assert.match(installer, /readdirSync\(directory\)\.length !== 0/u);
  assert.match(installer, /rmdirSync\(directory\)/u);
  assert.doesNotMatch(installer, /rmSync|recursive:\s*true/u);
  assert.match(installer, /if \(installationError\)[\s\S]+throw installationError/u);
});

test("Windows elevated worker is copied and hash-checked across UAC", () => {
  const worker = materializeElevatedWorker({
    sourceMsi: "C:\\Temp\\ProxyGauge package.msi",
    expectedSha256: "a".repeat(64)
  });
  assert.doesNotMatch(worker, /__PROXYGAUGE_[A-Z0-9_]+__/u);
  assert.match(worker, /Decode-Payload '[A-Za-z0-9+/=]+'/u);
  assert.match(worker, /\[IO\.File\]::Copy\(\$sourceMsi, \$secureMsi/);
  assert.doesNotMatch(worker, /PROXYGAUGE_DOWNLOAD_PROXY|HttpWebRequest|NetworkCredential/);
  const bootstrap = materializeElevatedBootstrap(
    `C:\\Temp\\${"长".repeat(70)}\\elevated-worker.ps1`,
    "b".repeat(64)
  );
  assert.doesNotMatch(bootstrap, /__PROXYGAUGE_[A-Z0-9_]+__/u);
  const encoded = encodeElevatedWorker(bootstrap);
  const sanitized = sanitizedCmdArguments(encoded);
  assert.ok(sanitized.length <= 8_000);
  assert.match(sanitized, /^\/d \/c set "COR_ENABLE_PROFILING="/u);
  assert.match(sanitized, /DOTNET_STARTUP_HOOKS=/u);
  assert.match(sanitized, /C:\\Windows\\System32\\WindowsPowerShell/u);
  assert.match(elevatedBootstrapCommand, /__PROXYGAUGE_WORKER_SHA256_UTF8__/u);
  assert.match(elevatedBootstrapCommand, /\[IO\.File\]::Copy\(\$sourceWorker, \$secureWorker/u);
  assert.match(elevatedBootstrapCommand, /ScriptBlock\]::Create/u);
  assert.throws(
    () => sanitizedCmdArguments(encodeElevatedWorker("x".repeat(8_000))),
    /cmd\.exe/
  );
});

test("Windows installer accepts one exact checksum entry", () => {
  const asset = "ProxyGauge-1.6.3-win-x64.msi";
  const hash = "a".repeat(64);
  assert.equal(expectedChecksum(`${hash}  ${asset}\n`, asset), hash);
  assert.equal(expectedChecksum(`${hash.toUpperCase()} *${asset}\r\n`, asset), hash);
  assert.throws(
    () => expectedChecksum(`${hash}  ${asset}\n${hash} *${asset}\n`, asset),
    /重复/
  );
  assert.throws(() => expectedChecksum(`${hash}  another.msi\n`, asset), /缺少/);
});

test("Windows installer accepts only exact assets from the requested GitHub release", () => {
  const version = "1.6.3";
  const name = `ProxyGauge-${version}-win-x64.msi`;
  const release = {
    assets: [{
      name,
      browser_download_url: `https://github.com/ValenLan/ProxyGauge/releases/download/v${version}/${name}`
    }]
  };
  assert.equal(exactAsset(release, name, version).hostname, "github.com");
  assert.throws(
    () => exactAsset({ assets: [{
      name,
      browser_download_url: `https://github.com/ValenLan/ProxyGauge/releases/download/v1.6.2/${name}`
    }] }, name, version),
    /不属于指定的 GitHub Release/
  );
  assert.throws(
    () => exactAsset({ assets: [release.assets[0], release.assets[0]] }, name, version),
    /缺少唯一/
  );
});

test("Windows npm transport honors authenticated proxies and exact NO_PROXY ports", () => {
  const downloadUrl = new URL("https://github.com/ValenLan/ProxyGauge/releases/download/v1.6.3/test.msi");
  assert.equal(noProxyMatches(downloadUrl, "github.com:443"), true);
  assert.equal(noProxyMatches(downloadUrl, "github.com:80"), false);
  assert.equal(noProxyMatches(downloadUrl, ".example.com, *.github.com"), true);

  const authenticated = proxySettingsFor(downloadUrl, {
    npm_config_https_proxy: "http://domain%5Cuser:p%40ss@proxy.example:8080"
  });
  assert.deepEqual(authenticated, {
    direct: false,
    forceDirect: false,
    url: "http://proxy.example:8080/",
    username: "domain\\user",
    password: "p@ss",
    noProxy: ""
  });
  const initiallyBypassed = proxySettingsFor(downloadUrl, {
    HTTPS_PROXY: "http://proxy.example:8080",
    NO_PROXY: "github.com:443"
  });
  assert.equal(initiallyBypassed.direct, true);
  assert.equal(initiallyBypassed.forceDirect, false);
  assert.equal(initiallyBypassed.url, "http://proxy.example:8080/");
  assert.equal(proxySettingsFor(downloadUrl, {
    HTTPS_PROXY: "http://proxy.example:8080",
    npm_config_noproxy: "",
    NO_PROXY: "github.com:443"
  }).direct, true);
  assert.throws(
    () => proxySettingsFor(downloadUrl, { HTTPS_PROXY: "https://proxy.example:443" }),
    /仅支持 HTTP 代理地址/
  );
  assert.throws(
    () => proxySettingsFor(downloadUrl, { HTTPS_PROXY: "http://proxy.example:8080/config" }),
    /只含主机、端口/
  );
  assert.throws(
    () => proxySettingsFor(downloadUrl, { HTTPS_PROXY: "http://proxy.example:8080/?mode=unsafe" }),
    /只含主机、端口/
  );
  assert.throws(
    () => proxySettingsFor(downloadUrl, { HTTPS_PROXY: "http://proxy.example:8080/#fragment" }),
    /只含主机、端口/
  );
  assert.equal(proxySettingsFor(downloadUrl, {
    npm_config_https_proxy: "",
    HTTPS_PROXY: "http://proxy.example:8080"
  }).url, "http://proxy.example:8080/");
  assert.equal(proxySettingsFor(downloadUrl, {
    npm_config_https_proxy: "false",
    HTTPS_PROXY: "http://proxy.example:8080"
  }).forceDirect, true);
  assert.equal(proxySettingsFor(downloadUrl, {
    HTTPS_PROXY: "http://domain%5Cuser@proxy.example:8080"
  }).password, "");
});

test("embedded Windows PowerShell commands parse on Windows PowerShell 5.1", {
  skip: process.platform !== "win32"
}, () => {
  const parserCommand = [
    "$tokens = $null",
    "$errors = $null",
    "$source = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($env:PROXYGAUGE_TEST_SCRIPT))",
    "[Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors) | Out-Null",
    "if ($errors.Count -ne 0) { $errors | ForEach-Object { [Console]::Error.WriteLine($_) }; exit 1 }"
  ].join("\n");
  const materializedWorker = materializeElevatedWorker({
    sourceMsi: "C:\\Temp\\ProxyGauge.msi",
    expectedSha256: "a".repeat(64),
    cancelPath: "C:\\Temp\\cancel"
  });
  for (const command of [
    downloadCommand,
    elevatedWorkerCommand,
    elevatedBootstrapCommand,
    materializedWorker,
    elevationLauncherCommand,
    nativeArchitectureCommand,
    temporaryDirectoryValidationCommand
  ]) {
    const result = spawnSync(
      systemPowerShellPath(process.env),
      ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", parserCommand],
      {
        encoding: "utf8",
        env: {
          ...process.env,
          PROXYGAUGE_TEST_SCRIPT: Buffer.from(command, "utf16le").toString("base64")
        }
      }
    );
    assert.equal(result.status, 0, result.stderr);
  }
  assert.match(systemCmdPath(process.env), /\\System32\\cmd\.exe$/u);
  assert.equal(runtimeForNativeMachine("8664", "WinNT"), "win-x64");
  assert.equal(runtimeForNativeMachine("aa64", "WinNT"), "win-arm64");
  assert.throws(
    () => runtimeForNativeMachine("8664", "ServerNT"),
    /不支持 Windows Server/
  );
  assert.throws(
    () => runtimeForNativeMachine("014c", "WinNT"),
    /不支持的 Windows 原生架构/
  );
});

test("postinstall runs globally but not for a local dependency", () => {
  assert.equal(shouldRunPostinstall({ npm_config_global: "true" }), true);
  assert.equal(shouldRunPostinstall({ npm_config_global: "false" }), false);
  assert.equal(shouldRunPostinstall({}), false);
  assert.equal(
    shouldRunPostinstall({
      npm_config_global: "false",
      PROXYGAUGE_FORCE_INSTALL: "1"
    }),
    true
  );
});

test("CLI reports its version and supports a side-effect-free installer check", () => {
  const cli = resolve(projectRoot, "Scripts/proxygauge-npm.mjs");
  const versionResult = spawnSync(process.execPath, [cli, "--version"], {
    encoding: "utf8"
  });
  assert.equal(versionResult.status, 0, versionResult.stderr);
  assert.equal(versionResult.stdout.trim(), packageMetadata.version);

  const dryRunResult = spawnSync(process.execPath, [cli, "install"], {
    encoding: "utf8",
    env: {
      ...process.env,
      PROXYGAUGE_INSTALL_DRY_RUN: "1"
    }
  });
  assert.equal(dryRunResult.status, 0, dryRunResult.stderr);
  assert.match(dryRunResult.stdout, new RegExp(`v${packageMetadata.version}\\b`));
});

test("CLI fails closed for unknown, mixed, or forged postinstall arguments", () => {
  const cli = resolve(projectRoot, "Scripts/proxygauge-npm.mjs");
  const invoke = (argumentsList, environment = {}) => spawnSync(
    process.execPath,
    [cli, ...argumentsList],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        PROXYGAUGE_INSTALL_DRY_RUN: "1",
        ...environment
      }
    }
  );

  const implicitInstall = invoke([]);
  assert.equal(implicitInstall.status, 0, implicitInstall.stderr);
  assert.match(implicitInstall.stdout, /安装器检查通过/u);

  for (const argumentsList of [
    ["--unknown"],
    ["install", "--unknown"],
    ["install", "extra"],
    ["install", "install"],
    ["--version", "install"],
    ["help", "install"],
    ["--postinstall"]
  ]) {
    const result = invoke(argumentsList);
    assert.notEqual(result.status, 0, `${argumentsList.join(" ")} unexpectedly succeeded`);
    assert.doesNotMatch(result.stdout, /安装器检查通过/u);
  }

  const forgedPostinstall = invoke(["install", "--postinstall"], {
    npm_config_global: "true",
    npm_lifecycle_event: "install"
  });
  assert.notEqual(forgedPostinstall.status, 0);
  assert.match(forgedPostinstall.stderr, /只能由 npm postinstall 生命周期调用/u);
  assert.doesNotMatch(forgedPostinstall.stdout, /安装器检查通过/u);

  const localPostinstall = invoke(["install", "--postinstall"], {
    npm_config_global: "false",
    npm_lifecycle_event: "postinstall"
  });
  assert.equal(localPostinstall.status, 0, localPostinstall.stderr);
  assert.match(localPostinstall.stdout, /只在全局安装时自动安装/u);
  assert.doesNotMatch(localPostinstall.stdout, /安装器检查通过/u);

  const globalPostinstall = invoke(["install", "--postinstall"], {
    npm_config_global: "true",
    npm_lifecycle_event: "postinstall"
  });
  assert.equal(globalPostinstall.status, 0, globalPostinstall.stderr);
  assert.match(globalPostinstall.stdout, /安装器检查通过/u);
});
