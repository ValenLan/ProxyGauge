import {
  createReadStream,
  lstatSync,
  mkdtempSync,
  readdirSync,
  rmdirSync,
  statSync,
  unlinkSync,
  writeFileSync
} from "node:fs";
import { createHash } from "node:crypto";
import { release as operatingSystemRelease, tmpdir } from "node:os";
import { join, resolve, win32 as windowsPath } from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repository = "ValenLan/ProxyGauge";
const apiHosts = new Set(["api.github.com"]);
const assetHosts = new Set([
  "github.com",
  "objects.githubusercontent.com",
  "release-assets.githubusercontent.com"
]);
const downloadFunctionLines = [
  "$ErrorActionPreference = 'Stop'",
  "$ProgressPreference = 'SilentlyContinue'",
  "$PSModuleAutoLoadingPreference = 'None'",
  "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12",
  "function Assert-DownloadActive {",
  "  if (-not [string]::IsNullOrWhiteSpace($env:PROXYGAUGE_CANCEL_PATH) -and [IO.File]::Exists($env:PROXYGAUGE_CANCEL_PATH)) { throw '下载已取消。' }",
  "  if ([DateTime]::UtcNow -ge $script:downloadDeadline) { throw '下载超过总时限。' }",
  "}",
  "function Test-ProxyBypass([Uri]$Uri, [string]$Rules) {",
  "  if ([string]::IsNullOrWhiteSpace($Rules)) { return $false }",
  "  $hostName = $Uri.Host.ToLowerInvariant()",
  "  $targetPort = if ($Uri.IsDefaultPort) { if ($Uri.Scheme -eq 'https') { '443' } else { '80' } } else { $Uri.Port.ToString([Globalization.CultureInfo]::InvariantCulture) }",
  "  foreach ($rawEntry in $Rules.Split(',')) {",
  "    $entry = $rawEntry.Trim().ToLowerInvariant()",
  "    if ($entry -eq '*') { return $true }",
  "    if ([string]::IsNullOrWhiteSpace($entry)) { continue }",
  "    $domain = $entry",
  "    $port = ''",
  "    if ($entry -match '^\\[([^\\]]+)\\](?::(\\d+))?$') {",
  "      $domain = $Matches[1]",
  "      $port = $Matches[2]",
  "    } elseif ($entry -match '^([^:]+):(\\d+)$') {",
  "      $domain = $Matches[1]",
  "      $port = $Matches[2]",
  "    }",
  "    if ($port -and $port -ne $targetPort) { continue }",
  "    if ($domain.StartsWith('*.')) { $domain = $domain.Substring(2) } elseif ($domain.StartsWith('.')) { $domain = $domain.Substring(1) }",
  "    if ($hostName -eq $domain -or $hostName.EndsWith('.' + $domain)) { return $true }",
  "  }",
  "  return $false",
  "}",
  "$timeoutMilliseconds = [int]$env:PROXYGAUGE_DOWNLOAD_TIMEOUT * 1000",
  "$maximumBytes = [long]$env:PROXYGAUGE_DOWNLOAD_MAXIMUM_BYTES",
  "$returnBase64 = $env:PROXYGAUGE_DOWNLOAD_RETURN_BASE64 -eq '1'",
  "$script:downloadDeadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMilliseconds)",
  "$allowedHosts = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)",
  "foreach ($allowedHost in $env:PROXYGAUGE_DOWNLOAD_ALLOWED_HOSTS.Split(',')) { if (-not [string]::IsNullOrWhiteSpace($allowedHost)) { $null = $allowedHosts.Add($allowedHost.Trim()) } }",
  "$explicitProxy = $null",
  "if (-not [string]::IsNullOrWhiteSpace($env:PROXYGAUGE_DOWNLOAD_PROXY)) {",
  "  $explicitProxy = [Net.WebProxy]::new([Uri]$env:PROXYGAUGE_DOWNLOAD_PROXY, $false)",
  "  if (-not [string]::IsNullOrWhiteSpace($env:PROXYGAUGE_DOWNLOAD_PROXY_USERNAME)) {",
  "    $credentialUser = $env:PROXYGAUGE_DOWNLOAD_PROXY_USERNAME",
  "    $credentialPassword = $env:PROXYGAUGE_DOWNLOAD_PROXY_PASSWORD",
  "    $domainSeparator = $credentialUser.IndexOf('\\')",
  "    if ($domainSeparator -gt 0 -and $domainSeparator -lt ($credentialUser.Length - 1)) {",
  "      $credentialDomain = $credentialUser.Substring(0, $domainSeparator)",
  "      $credentialUser = $credentialUser.Substring($domainSeparator + 1)",
  "      $explicitProxy.Credentials = [Net.NetworkCredential]::new($credentialUser, $credentialPassword, $credentialDomain)",
  "    } else {",
  "      $explicitProxy.Credentials = [Net.NetworkCredential]::new($credentialUser, $credentialPassword)",
  "    }",
  "  }",
  "}",
  "$systemProxy = [Net.WebRequest]::DefaultWebProxy",
  "$currentUri = [Uri]$env:PROXYGAUGE_DOWNLOAD_URL",
  "$completed = $false",
  "for ($redirectCount = 0; $redirectCount -le 5; $redirectCount++) {",
  "  Assert-DownloadActive",
  "  if ($currentUri.Scheme -ne 'https' -or -not $allowedHosts.Contains($currentUri.Host.ToLowerInvariant())) { throw '下载重定向到不受信任的地址。' }",
  "  $request = [Net.HttpWebRequest]::Create($currentUri)",
  "  $request.Method = 'GET'",
  "  $request.Accept = 'application/vnd.github+json, application/octet-stream;q=0.9, text/plain;q=0.8'",
  "  $request.UserAgent = 'ProxyGauge-Release-Installer'",
  "  $request.Headers['X-GitHub-Api-Version'] = '2022-11-28'",
  "  $request.AllowAutoRedirect = $false",
  "  $remainingMilliseconds = [Math]::Max(1, [Math]::Min([int]::MaxValue, [int]($script:downloadDeadline - [DateTime]::UtcNow).TotalMilliseconds))",
  "  $request.Timeout = $remainingMilliseconds",
  "  $request.ReadWriteTimeout = $remainingMilliseconds",
  "  if ($env:PROXYGAUGE_DOWNLOAD_FORCE_DIRECT -eq '1' -or (Test-ProxyBypass $currentUri $env:PROXYGAUGE_DOWNLOAD_NO_PROXY)) {",
  "    $request.Proxy = [Net.GlobalProxySelection]::GetEmptyWebProxy()",
  "  } elseif ($null -ne $explicitProxy) {",
  "    $request.Proxy = $explicitProxy",
  "  } else {",
  "    $request.Proxy = $systemProxy",
  "  }",
  "  $response = $null",
  "  $inputStream = $null",
  "  $outputStream = $null",
  "  try {",
  "    $response = [Net.HttpWebResponse]$request.GetResponse()",
  "    $statusCode = [int]$response.StatusCode",
  "    if ($statusCode -ge 300 -and $statusCode -le 399) {",
  "      if ($redirectCount -ge 5) { throw '正式版下载重定向次数过多。' }",
  "      $location = $response.Headers['Location']",
  "      if ([string]::IsNullOrWhiteSpace($location)) { throw ('HTTP ' + $statusCode + ' 缺少重定向地址。') }",
  "      $currentUri = [Uri]::new($currentUri, $location)",
  "      continue",
  "    }",
  "    if ($statusCode -lt 200 -or $statusCode -gt 299) { throw ('HTTP ' + $statusCode) }",
  "    if ($response.ContentLength -gt $maximumBytes) { throw '正式版响应超过安全大小限制。' }",
  "    $inputStream = $response.GetResponseStream()",
  "    if ($returnBase64) {",
  "      $outputStream = [IO.MemoryStream]::new()",
  "    } else {",
  "      $outputStream = [IO.FileStream]::new($env:PROXYGAUGE_DOWNLOAD_PATH, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)",
  "    }",
  "    $buffer = [byte[]]::new(8192)",
  "    $total = [long]0",
  "    while ($true) {",
  "      $remainingReadMilliseconds = [int]($script:downloadDeadline - [DateTime]::UtcNow).TotalMilliseconds",
  "      if ($remainingReadMilliseconds -le 0) { throw '下载超过总时限。' }",
  "      if (-not $inputStream.CanTimeout) { throw '下载流不支持总时限。' }",
  "      $inputStream.ReadTimeout = [Math]::Max(1, $remainingReadMilliseconds)",
  "      $read = $inputStream.Read($buffer, 0, $buffer.Length)",
  "      if ($read -le 0) { break }",
  "      Assert-DownloadActive",
  "      $total += $read",
  "      if ($total -gt $maximumBytes) { throw '正式版响应超过安全大小限制。' }",
  "      $outputStream.Write($buffer, 0, $read)",
  "    }",
  "    if ($total -le 0) { throw '正式版响应为空。' }",
  "    if ($returnBase64) { $resultBase64 = [Convert]::ToBase64String($outputStream.ToArray()) }",
  "    $completed = $true",
  "    break",
  "  } finally {",
  "    if ($null -ne $outputStream) { $outputStream.Dispose() }",
  "    if ($null -ne $inputStream) { $inputStream.Dispose() }",
  "    if ($null -ne $response) { $response.Dispose() }",
  "  }",
  "}",
  "if (-not $completed) { throw '正式版下载未完成。' }",
  "if ($returnBase64) { [Console]::Out.WriteLine($resultBase64) }"
];
const downloadFunctionCommand = [
  "function Invoke-ProxyGaugeDownload {",
  ...downloadFunctionLines.map(line => `  ${line}`),
  "}"
].join("\n");
const downloadCommand = `${downloadFunctionCommand}\nInvoke-ProxyGaugeDownload`;
const elevatedWorkerCommand = [
  "$ErrorActionPreference = 'Stop'",
  "$PSModuleAutoLoadingPreference = 'None'",
  "function Decode-Payload([string]$Value) { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value)) }",
  "$sourceMsi = Decode-Payload '__PROXYGAUGE_SOURCE_MSI_UTF8__'",
  "$expected = Decode-Payload '__PROXYGAUGE_EXPECTED_SHA256_UTF8__'",
  "$exitCode = 1",
  "$cleanupFailed = $false",
  "if ($expected -notmatch '^[0-9a-f]{64}$' -or -not [IO.File]::Exists($sourceMsi)) { throw '提权安装参数无效。' }",
  "$sourceLength = [IO.FileInfo]::new($sourceMsi).Length",
  "if ($sourceLength -le 0 -or $sourceLength -gt 536870912) { throw '安装包大小无效。' }",
  "$programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)",
  "if ([string]::IsNullOrWhiteSpace($programFiles)) { throw '无法定位受保护的 Program Files。' }",
  "$secureDirectory = [IO.Path]::Combine($programFiles, ('ProxyGauge Installer ' + [Guid]::NewGuid().ToString('N')))",
  "$secureMsi = [IO.Path]::Combine($secureDirectory, 'ProxyGauge.msi')",
  "try {",
  "  $null = [IO.Directory]::CreateDirectory($secureDirectory)",
  "  [IO.File]::Copy($sourceMsi, $secureMsi, $false)",
  "  $stream = [IO.File]::OpenRead($secureMsi)",
  "  $sha256 = [Security.Cryptography.SHA256]::Create()",
  "  try { $actual = ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() } finally { $sha256.Dispose(); $stream.Dispose() }",
  "  if ($actual -ne $expected) { throw '提权后的 SHA-256 复核失败，安装已停止。' }",
  "  $msiexec = [IO.Path]::Combine([Environment]::SystemDirectory, 'msiexec.exe')",
  "  $startInfo = [Diagnostics.ProcessStartInfo]::new()",
  "  $startInfo.FileName = $msiexec",
  "  $startInfo.Arguments = '/i \"' + $secureMsi + '\" /passive /norestart'",
  "  $startInfo.UseShellExecute = $false",
  "  $startInfo.CreateNoWindow = $true",
  "  $installer = [Diagnostics.Process]::Start($startInfo)",
  "  if (-not $installer.WaitForExit(1800000)) {",
  "    try { $installer.Kill() } catch {}",
  "    throw 'Windows Installer 超过 30 分钟仍未结束，安装已停止等待。'",
  "  }",
  "  $exitCode = $installer.ExitCode",
  "} finally {",
  "  try { if ([IO.File]::Exists($secureMsi)) { [IO.File]::Delete($secureMsi) } } catch { $cleanupFailed = $true }",
  "  try { if ([IO.Directory]::Exists($secureDirectory)) { [IO.Directory]::Delete($secureDirectory, $false) } } catch { $cleanupFailed = $true }",
  "}",
  "if ($cleanupFailed) { return 1 }",
  "return $exitCode"
].join("\n");
const elevatedBootstrapCommand = [
  "$ErrorActionPreference = 'Stop'",
  "$PSModuleAutoLoadingPreference = 'None'",
  "function Decode-Payload([string]$Value) { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value)) }",
  "$sourceWorker = Decode-Payload '__PROXYGAUGE_WORKER_PATH_UTF8__'",
  "$expectedWorker = Decode-Payload '__PROXYGAUGE_WORKER_SHA256_UTF8__'",
  "$secureDirectory = $null",
  "$secureWorker = $null",
  "$exitCode = 1",
  "$cleanupFailed = $false",
  "try {",
  "  if ($expectedWorker -notmatch '^[0-9a-f]{64}$' -or -not [IO.File]::Exists($sourceWorker)) { throw '提权工作文件参数无效。' }",
  "  $sourceLength = [IO.FileInfo]::new($sourceWorker).Length",
  "  if ($sourceLength -le 0 -or $sourceLength -gt 131072) { throw '提权工作文件大小无效。' }",
  "  $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)",
  "  if ([string]::IsNullOrWhiteSpace($programFiles)) { throw '无法定位受保护的 Program Files。' }",
  "  $secureDirectory = [IO.Path]::Combine($programFiles, ('ProxyGauge Bootstrap ' + [Guid]::NewGuid().ToString('N')))",
  "  $null = [IO.Directory]::CreateDirectory($secureDirectory)",
  "  $secureWorker = [IO.Path]::Combine($secureDirectory, 'worker.ps1')",
  "  [IO.File]::Copy($sourceWorker, $secureWorker, $false)",
  "  $stream = [IO.File]::OpenRead($secureWorker)",
  "  $sha256 = [Security.Cryptography.SHA256]::Create()",
  "  try { $actualWorker = ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() } finally { $sha256.Dispose(); $stream.Dispose() }",
  "  if ($actualWorker -ne $expectedWorker) { throw '提权工作文件 SHA-256 复核失败。' }",
  "  $workerScript = [ScriptBlock]::Create([IO.File]::ReadAllText($secureWorker))",
  "  $workerOutput = @(& $workerScript)",
  "  if ($workerOutput.Count -ne 1 -or -not [int]::TryParse([string]$workerOutput[0], [ref]$exitCode)) { throw '提权工作文件没有返回有效退出代码。' }",
  "} catch {",
  "  $exitCode = 1",
  "} finally {",
  "  try { if ($null -ne $secureWorker -and [IO.File]::Exists($secureWorker)) { [IO.File]::Delete($secureWorker) } } catch { $cleanupFailed = $true }",
  "  try { if ($null -ne $secureDirectory -and [IO.Directory]::Exists($secureDirectory)) { [IO.Directory]::Delete($secureDirectory, $false) } } catch { $cleanupFailed = $true }",
  "}",
  "if ($cleanupFailed) { $exitCode = 1 }",
  "exit $exitCode"
].join("\n");
const elevationLauncherCommand = [
  "$ErrorActionPreference = 'Stop'",
  "$PSModuleAutoLoadingPreference = 'None'",
  "$startInfo = [Diagnostics.ProcessStartInfo]::new()",
  "$startInfo.FileName = $env:PROXYGAUGE_SYSTEM_CMD",
  "$startInfo.Arguments = $env:PROXYGAUGE_SANITIZED_ARGUMENTS",
  "$startInfo.UseShellExecute = $true",
  "$startInfo.Verb = 'RunAs'",
  "$worker = [Diagnostics.Process]::Start($startInfo)",
  "[Console]::Out.WriteLine('WORKER ' + $worker.Id)",
  "[Console]::Out.Flush()",
  "$worker.WaitForExit()",
  "[Console]::Out.WriteLine($worker.ExitCode)"
].join("\n");
const nativeArchitectureCommand = [
  "$ErrorActionPreference = 'Stop'",
  "$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')",
  "Import-Module ([IO.Path]::Combine($PSHOME, 'Modules', 'Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Utility.psd1')) -ErrorAction Stop",
  "$source = @'",
  "using System;",
  "using System.Runtime.InteropServices;",
  "public static class ProxyGaugeNativeArchitecture {",
  "    [DllImport(\"kernel32.dll\", SetLastError = true)]",
  "    [return: MarshalAs(UnmanagedType.Bool)]",
  "    public static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);",
  "}",
  "'@",
  "Add-Type -TypeDefinition $source -ErrorAction Stop",
  "[UInt16]$processMachine = 0",
  "[UInt16]$nativeMachine = 0",
  "$process = [Diagnostics.Process]::GetCurrentProcess()",
  "if (-not [ProxyGaugeNativeArchitecture]::IsWow64Process2($process.Handle, [ref]$processMachine, [ref]$nativeMachine)) {",
  "  throw ('IsWow64Process2 failed: ' + [Runtime.InteropServices.Marshal]::GetLastWin32Error())",
  "}",
  "$productKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\\CurrentControlSet\\Control\\ProductOptions')",
  "try { $productType = [string]$productKey.GetValue('ProductType') } finally { if ($null -ne $productKey) { $productKey.Dispose() } }",
  "[Console]::Out.WriteLine($nativeMachine.ToString('X4') + \"`t\" + $productType)"
].join("\n");
const temporaryDirectoryValidationCommand = [
  "$ErrorActionPreference = 'Stop'",
  "$PSModuleAutoLoadingPreference = 'None'",
  "$candidate = $env:PROXYGAUGE_TEMP_BASE",
  "if ([string]::IsNullOrWhiteSpace($candidate)) { throw '临时目录为空。' }",
  "$fullPath = [IO.Path]::GetFullPath($candidate)",
  "$root = [IO.Path]::GetPathRoot($fullPath)",
  "if ($root -notmatch '^[A-Za-z]:\\\\$') { throw '临时目录必须位于本机固定磁盘。' }",
  "$drive = [IO.DriveInfo]::new($root)",
  "if ($drive.DriveType -ne [IO.DriveType]::Fixed) { throw '临时目录不能位于网络盘或可移动磁盘。' }",
  "if (-not [IO.Directory]::Exists($fullPath)) { throw '临时目录不存在。' }",
  "$current = $root",
  "$relative = $fullPath.Substring($root.Length)",
  "$separators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)",
  "foreach ($part in $relative.Split($separators, [StringSplitOptions]::RemoveEmptyEntries)) {",
  "  $current = [IO.Path]::Combine($current, $part)",
  "  if (-not [IO.Directory]::Exists($current)) { throw '临时目录路径不完整。' }",
  "  if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '临时目录不能经过重解析点。' }",
  "}",
  "$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($fullPath))",
  "[Console]::Out.WriteLine($encoded)"
].join("\n");

const dangerousElevatedEnvironmentNames = [
  "COR_ENABLE_PROFILING",
  "COR_PROFILER",
  "COR_PROFILER_PATH",
  "COR_PROFILER_PATH_32",
  "COR_PROFILER_PATH_64",
  "CORECLR_ENABLE_PROFILING",
  "CORECLR_PROFILER",
  "CORECLR_PROFILER_PATH",
  "CORECLR_PROFILER_PATH_32",
  "CORECLR_PROFILER_PATH_64",
  "DOTNET_STARTUP_HOOKS",
  "DOTNET_ADDITIONAL_DEPS",
  "DOTNET_SHARED_STORE",
  "APPDOMAIN_MANAGER_ASM",
  "APPDOMAIN_MANAGER_TYPE",
  "COMPLUS_ApplicationMigrationRuntimeActivationConfigPath",
  "COMPLUS_Version",
  "DEVPATH"
];

function checkedUrl(value, allowedHosts) {
  const url = new URL(value);
  if (url.protocol !== "https:" || !allowedHosts.has(url.hostname)) {
    throw new Error(`正式版下载地址不受信任：${url.hostname}`);
  }
  return url;
}

function noProxyMatches(url, value) {
  const hostname = url.hostname.toLowerCase();
  const targetPort = url.port || (url.protocol === "https:" ? "443" : "80");
  return (value ?? "")
    .split(",")
    .map(entry => entry.trim().toLowerCase())
    .filter(Boolean)
    .some(entry => {
      if (entry === "*") return true;
      let domain = entry;
      let port = "";
      const bracketed = entry.match(/^\[([^\]]+)\](?::(\d+))?$/u);
      if (bracketed) {
        [, domain, port = ""] = bracketed;
      } else {
        const hostAndPort = entry.match(/^([^:]+):(\d+)$/u);
        if (hostAndPort) [, domain, port] = hostAndPort;
      }
      if (port && port !== targetPort) return false;
      domain = domain.replace(/^\*?\./u, "");
      return hostname === domain || hostname.endsWith(`.${domain}`);
    });
}

function proxySettingsFor(url, environment) {
  const noProxy = [
    environment.npm_config_noproxy,
    environment.NO_PROXY,
    environment.no_proxy
  ].find(candidate => typeof candidate === "string" && candidate.trim()) ?? "";
  const direct = noProxyMatches(url, noProxy);
  const value = [
    environment.npm_config_https_proxy,
    environment.npm_config_proxy,
    environment.HTTPS_PROXY,
    environment.https_proxy,
    environment.HTTP_PROXY,
    environment.http_proxy
  ].find(candidate => typeof candidate === "string" && candidate.trim()) ?? "";
  const trimmedValue = value.trim();
  if (!trimmedValue) {
    return { direct, forceDirect: false, url: "", username: "", password: "", noProxy };
  }
  if (["false", "null"].includes(trimmedValue.toLowerCase())) {
    return { direct: true, forceDirect: true, url: "", username: "", password: "", noProxy };
  }
  const proxy = new URL(trimmedValue);
  if (proxy.protocol !== "http:") {
    throw new Error("Windows PowerShell 5.1 下载仅支持 HTTP 代理地址（HTTPS 目标仍使用 TLS）。");
  }
  if (!proxy.hostname || proxy.pathname !== "/" || proxy.search || proxy.hash) {
    throw new Error("npm/系统代理必须是只含主机、端口和可选凭据的 HTTP 地址。");
  }
  let username;
  let password;
  try {
    username = decodeURIComponent(proxy.username);
    password = decodeURIComponent(proxy.password);
  } catch {
    throw new Error("npm/系统代理凭据不是有效的 URL 编码。");
  }
  if (password && !username) {
    throw new Error("npm/系统代理密码缺少用户名。");
  }
  proxy.username = "";
  proxy.password = "";
  return { direct, forceDirect: false, url: proxy.toString(), username, password, noProxy };
}

function systemPowerShellPath(environment) {
  const fixedSystemRoot = "C:\\Windows";
  for (const candidate of [environment.SystemRoot, environment.WINDIR]) {
    if (candidate === undefined) continue;
    const normalized = String(candidate).replace(/\//gu, "\\").replace(/\\+$/u, "");
    if (normalized.toLowerCase() !== fixedSystemRoot.toLowerCase()) {
      throw new Error("Windows 系统目录不是受支持的 C:\\Windows，安装已停止。");
    }
  }
  const systemDirectory = process.arch === "ia32" ? "Sysnative" : "System32";
  return windowsPath.join(
    fixedSystemRoot,
    systemDirectory,
    "WindowsPowerShell",
    "v1.0",
    "powershell.exe"
  );
}

function systemCmdPath(environment) {
  systemPowerShellPath(environment);
  return windowsPath.join("C:\\Windows", "System32", "cmd.exe");
}

function elevatedPowerShellPath() {
  return windowsPath.join(
    "C:\\Windows",
    "System32",
    "WindowsPowerShell",
    "v1.0",
    "powershell.exe"
  );
}

function temporaryBaseCandidate(environment, fallback = tmpdir()) {
  for (const name of ["TEMP", "TMP"]) {
    const match = Object.entries(environment).find(
      ([candidate]) => candidate.toLowerCase() === name.toLowerCase()
    );
    if (typeof match?.[1] === "string" && match[1].length > 0) return match[1];
  }
  return fallback;
}

function validatedTemporaryBase(environment) {
  const candidate = temporaryBaseCandidate(environment);
  const result = spawnSync(
    systemPowerShellPath(environment),
    ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", temporaryDirectoryValidationCommand],
    {
      encoding: "utf8",
      env: {
        ...selectedWindowsEnvironment(environment),
        PROXYGAUGE_TEMP_BASE: candidate
      },
      windowsHide: true,
      timeout: 10_000,
      maxBuffer: 32 * 1024
    }
  );
  if (result.error?.code === "ETIMEDOUT") {
    throw new Error("验证 Windows 临时目录超过 10 秒。");
  }
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`Windows 临时目录不安全：${result.stderr?.trim() || result.status}`);
  }
  const encoded = result.stdout.trim().split(/\r?\n/u).at(-1) ?? "";
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u.test(encoded)) {
    throw new Error("Windows 临时目录验证组件没有返回有效路径。");
  }
  const bytes = Buffer.from(encoded, "base64");
  const path = bytes.toString("utf8");
  if (!path || path.includes("\0") || bytes.toString("base64") !== encoded) {
    throw new Error("Windows 临时目录验证组件返回了损坏路径。");
  }
  return path;
}

function removeKnownTemporaryDirectory(directory, fileNames) {
  let directoryMetadata;
  try {
    directoryMetadata = lstatSync(directory);
  } catch (error) {
    if (error?.code === "ENOENT") return;
    throw error;
  }
  if (!directoryMetadata.isDirectory() || directoryMetadata.isSymbolicLink()) {
    throw new Error("临时目录已被替换或变成重解析点，拒绝递归清理。");
  }
  for (const fileName of fileNames) {
    const path = join(directory, fileName);
    let metadata;
    try {
      metadata = lstatSync(path);
    } catch (error) {
      if (error?.code === "ENOENT") continue;
      throw error;
    }
    if (!metadata.isFile() || metadata.isSymbolicLink()) {
      throw new Error(`临时文件 ${fileName} 已被替换，拒绝清理。`);
    }
    unlinkSync(path);
  }
  if (readdirSync(directory).length !== 0) {
    throw new Error("临时目录含非安装器创建的项目，拒绝递归清理。");
  }
  rmdirSync(directory);
}

function resolveNativeWindowsRuntimeAtBase(environment, temporaryBase) {
  const compilerTemporaryDirectory = mkdtempSync(
    join(temporaryBase, "proxygauge-architecture-")
  );
  let runtime;
  let detectionError;
  try {
    const result = spawnSync(
      systemPowerShellPath(environment),
      ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", nativeArchitectureCommand],
      {
        encoding: "utf8",
        env: selectedWindowsEnvironment({
          ...environment,
          TEMP: compilerTemporaryDirectory,
          TMP: compilerTemporaryDirectory
        }, ["TEMP", "TMP"]),
        windowsHide: true,
        timeout: 15_000
      }
    );
    if (result.error?.code === "ETIMEDOUT") {
      throw new Error("检测 Windows 原生架构超过 15 秒。");
    }
    if (result.error) throw result.error;
    if (result.status !== 0) {
      throw new Error(`无法检测 Windows 原生架构：${result.stderr?.trim() || result.status}`);
    }
    const [machine, productType] = (result.stdout.trim().split(/\r?\n/u).at(-1) ?? "")
      .split("\t");
    runtime = runtimeForNativeMachine(machine, productType);
  } catch (error) {
    detectionError = error;
  }

  let cleanupError;
  try {
    removeKnownTemporaryDirectory(compilerTemporaryDirectory, []);
  } catch (error) {
    cleanupError = error;
  }
  if (detectionError) {
    if (cleanupError) {
      console.error(`警告：架构检测失败后，临时目录未能安全清理：${cleanupError.message}`);
    }
    throw detectionError;
  }
  if (cleanupError) {
    throw new Error(`架构检测完成，但临时目录未能安全清理：${cleanupError.message}`);
  }
  return runtime;
}

function runtimeForNativeMachine(machine, productType) {
  if (productType !== "WinNT") {
    throw new Error("ProxyGauge 正式版不支持 Windows Server。");
  }
  const normalizedMachine = machine?.toUpperCase();
  if (normalizedMachine === "AA64") return "win-arm64";
  if (normalizedMachine === "8664") return "win-x64";
  throw new Error(`不支持的 Windows 原生架构：${normalizedMachine || "未知"}`);
}

function resolveNativeWindowsRuntime(environment) {
  return resolveNativeWindowsRuntimeAtBase(environment, validatedTemporaryBase(environment));
}

function selectedWindowsEnvironment(environment, additionalNames = []) {
  const allowed = new Set([
    ...additionalNames.map(name => name.toLowerCase())
  ]);
  return {
    ...Object.fromEntries(
    Object.entries(environment).filter(([name]) => allowed.has(name.toLowerCase()))
    ),
    SystemRoot: "C:\\Windows",
    WINDIR: "C:\\Windows"
  };
}

function downloadThroughSystemRoute(
  url,
  destination,
  maximumBytes,
  allowedHosts,
  environment,
  timeoutSeconds = 120,
  returnBytes = false
) {
  const proxy = proxySettingsFor(url, environment);
  const powerShell = systemPowerShellPath(environment);
  const result = spawnSync(
    powerShell,
    ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", downloadCommand],
    {
      env: {
        ...selectedWindowsEnvironment(environment),
        PROXYGAUGE_DOWNLOAD_URL: url.toString(),
        PROXYGAUGE_DOWNLOAD_PATH: destination,
        PROXYGAUGE_DOWNLOAD_PROXY: proxy.url,
        PROXYGAUGE_DOWNLOAD_PROXY_USERNAME: proxy.username,
        PROXYGAUGE_DOWNLOAD_PROXY_PASSWORD: proxy.password,
        PROXYGAUGE_DOWNLOAD_NO_PROXY: proxy.noProxy,
        PROXYGAUGE_DOWNLOAD_FORCE_DIRECT: proxy.forceDirect ? "1" : "0",
        PROXYGAUGE_DOWNLOAD_TIMEOUT: String(timeoutSeconds),
        PROXYGAUGE_DOWNLOAD_MAXIMUM_BYTES: String(maximumBytes),
        PROXYGAUGE_DOWNLOAD_ALLOWED_HOSTS: [...allowedHosts].join(","),
        PROXYGAUGE_DOWNLOAD_RETURN_BASE64: returnBytes ? "1" : "0"
      },
      stdio: returnBytes ? ["ignore", "pipe", "inherit"] : "inherit",
      encoding: returnBytes ? "utf8" : undefined,
      maxBuffer: returnBytes ? Math.ceil(maximumBytes * 4 / 3) + 8192 : undefined,
      windowsHide: true,
      timeout: (timeoutSeconds + 5) * 1000
    }
  );
  if (result.error?.code === "ETIMEDOUT") {
    throw new Error(`系统下载超过 ${timeoutSeconds} 秒总时限。`);
  }
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`系统下载组件退出，代码：${result.status ?? "未知"}`);
  }
  if (returnBytes) {
    const encoded = result.stdout?.trim() ?? "";
    if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u.test(encoded)) {
      throw new Error("系统下载组件没有返回有效数据。");
    }
    const bytes = Buffer.from(encoded, "base64");
    if (bytes.length <= 0 || bytes.length > maximumBytes || bytes.toString("base64") !== encoded) {
      throw new Error("正式版响应为空、损坏或超过安全大小限制。");
    }
    return bytes;
  }
  const size = statSync(destination).size;
  if (size <= 0 || size > maximumBytes) {
    throw new Error("正式版响应为空或超过安全大小限制。");
  }
}

function materializeElevatedWorker({
  sourceMsi,
  expectedSha256
}) {
  const utf8 = value => Buffer.from(value, "utf8").toString("base64");
  const replacements = new Map([
    ["__PROXYGAUGE_SOURCE_MSI_UTF8__", utf8(sourceMsi)],
    ["__PROXYGAUGE_EXPECTED_SHA256_UTF8__", utf8(expectedSha256)]
  ]);
  let command = elevatedWorkerCommand;
  for (const [placeholder, replacement] of replacements) {
    if (!command.includes(placeholder)) {
      throw new Error(`提权安装模板缺少参数：${placeholder}`);
    }
    command = command.replace(placeholder, () => replacement);
  }
  if (/__PROXYGAUGE_[A-Z0-9_]+__/u.test(command)) {
    throw new Error("提权安装模板仍含未解析参数。");
  }
  return command;
}

function encodeElevatedWorker(workerCommand) {
  return Buffer.from(workerCommand, "utf16le").toString("base64");
}

function materializeElevatedBootstrap(sourceWorker, expectedWorkerSha256) {
  const utf8 = value => Buffer.from(value, "utf8").toString("base64");
  const replacements = new Map([
    ["__PROXYGAUGE_WORKER_PATH_UTF8__", utf8(sourceWorker)],
    ["__PROXYGAUGE_WORKER_SHA256_UTF8__", utf8(expectedWorkerSha256)]
  ]);
  let command = elevatedBootstrapCommand;
  for (const [placeholder, replacement] of replacements) {
    if (!command.includes(placeholder)) {
      throw new Error(`提权引导模板缺少参数：${placeholder}`);
    }
    command = command.replace(placeholder, () => replacement);
  }
  if (/__PROXYGAUGE_[A-Z0-9_]+__/u.test(command)) {
    throw new Error("提权引导模板仍含未解析参数。");
  }
  return command;
}

function sanitizedCmdArguments(encodedWorkerCommand) {
  const clearEnvironment = dangerousElevatedEnvironmentNames
    .map(name => `set "${name}="`)
    .join(" & ");
  const argumentsText = [
    "/d /c",
    clearEnvironment,
    "&",
    `"${elevatedPowerShellPath()}"`,
    "-NoLogo -NoProfile -NonInteractive -EncodedCommand",
    encodedWorkerCommand
  ].join(" ");
  if (argumentsText.length > 8_000) {
    throw new Error("安装参数过长，超过 cmd.exe 的安全命令行上限。");
  }
  return argumentsText;
}

function installMsiElevated(sourceMsi, expectedSha256, environment) {
  const powerShell = systemPowerShellPath(environment);
  const workerCommand = materializeElevatedWorker({
    sourceMsi,
    expectedSha256
  });
  const workerPath = windowsPath.join(windowsPath.dirname(sourceMsi), "elevated-worker.ps1");
  writeFileSync(workerPath, workerCommand, { encoding: "utf8", flag: "wx" });
  const workerSha256 = createHash("sha256").update(Buffer.from(workerCommand, "utf8")).digest("hex");
  const bootstrapCommand = materializeElevatedBootstrap(workerPath, workerSha256);
  const encodedBootstrapCommand = encodeElevatedWorker(bootstrapCommand);
  const elevatedArguments = sanitizedCmdArguments(encodedBootstrapCommand);
  const child = spawn(
    powerShell,
    ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", elevationLauncherCommand],
    {
      env: {
        ...selectedWindowsEnvironment(environment),
        PROXYGAUGE_SYSTEM_CMD: systemCmdPath(environment),
        PROXYGAUGE_SANITIZED_ARGUMENTS: elevatedArguments
      },
      stdio: ["ignore", "pipe", "inherit"],
      windowsHide: false
    }
  );
  child.stdout.setEncoding("utf8");

  return new Promise((resolvePromise, rejectPromise) => {
    let output = "";
    let terminationWarningShown = false;
    let settled = false;

    const warnAboutTermination = () => {
      if (!terminationWarningShown) {
        terminationWarningShown = true;
        console.error(
          "管理员授权请求已经发出。为避免留下后台提权事务，请在 Windows 授权窗口选择“否”，或等待安装返回确定结果。"
        );
      }
    };
    process.on("SIGINT", warnAboutTermination);
    process.on("SIGTERM", warnAboutTermination);

    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      process.removeListener("SIGINT", warnAboutTermination);
      process.removeListener("SIGTERM", warnAboutTermination);
      if (error) rejectPromise(error);
      else resolvePromise(value);
    };

    child.stdout.on("data", chunk => {
      output += chunk;
    });
    child.once("error", error => finish(error));
    child.once("close", status => {
      if (status !== 0) {
        finish(new Error(`Windows 提权安装组件退出，代码：${status ?? "未知"}`));
        return;
      }
      const exitCodeLine = output.trim().split(/\r?\n/u).findLast(line => /^\d+$/u.test(line));
      const exitCode = Number.parseInt(exitCodeLine ?? "", 10);
      if (!Number.isInteger(exitCode)) {
        finish(new Error("Windows Installer 没有返回有效退出代码。"));
        return;
      }
      finish(null, exitCode);
    });
  });
}

function expectedChecksum(checksumText, assetName) {
  let expected = "";
  for (const line of checksumText.split(/\r?\n/u)) {
    const match = line.match(/^([0-9a-f]{64})\s+\*?(.+)$/iu);
    if (!match || match[2] !== assetName) continue;
    if (expected) throw new Error("SHA256SUMS.txt 含重复安装包校验值。");
    expected = match[1].toLowerCase();
  }
  if (!expected) throw new Error("SHA256SUMS.txt 缺少当前安装包校验值。");
  return expected;
}

function hashFile(path) {
  return new Promise((resolvePromise, rejectPromise) => {
    const hash = createHash("sha256");
    const stream = createReadStream(path);
    stream.on("error", rejectPromise);
    stream.on("data", chunk => hash.update(chunk));
    stream.on("end", () => resolvePromise(hash.digest("hex")));
  });
}

function exactAsset(release, name, version) {
  const matches = release.assets.filter(asset => asset?.name === name);
  if (matches.length !== 1 || typeof matches[0].browser_download_url !== "string") {
    throw new Error(`正式版缺少唯一的 ${name}。`);
  }
  const url = checkedUrl(matches[0].browser_download_url, assetHosts);
  const expectedPath = `/${repository}/releases/download/v${version}/${name}`;
  if (url.hostname !== "github.com" || url.pathname !== expectedPath ||
      url.port || url.username || url.password || url.search || url.hash) {
    throw new Error(`正式版 ${name} 地址不属于指定的 GitHub Release。`);
  }
  return url;
}

function assertWindows11() {
  if (process.platform !== "win32") {
    throw new Error("Windows 正式版安装器只能在 Windows 11 上运行。");
  }
  const build = Number.parseInt(operatingSystemRelease().split(".")[2] ?? "", 10);
  if (!Number.isInteger(build) || build < 22_000) {
    throw new Error("ProxyGauge 正式版仅支持 Windows 11，不支持 Windows 10 或 Windows Server。");
  }
  // The MSI repeats this check and additionally rejects Windows Server via MsiNTProductType.
}

async function main() {
  assertWindows11();
  const version = process.env.PROXYGAUGE_VERSION;
  if (!/^\d+\.\d+\.\d+$/u.test(version ?? "")) {
    throw new Error(`无效的 ProxyGauge 指定版本：${version ?? "未提供"}`);
  }
  const temporaryBase = validatedTemporaryBase(process.env);
  const runtime = resolveNativeWindowsRuntimeAtBase(process.env, temporaryBase);
  const temporaryDirectory = mkdtempSync(
    join(temporaryBase, "proxygauge-release-")
  );
  const assetName = `ProxyGauge-${version}-${runtime}.msi`;
  const msiPath = join(temporaryDirectory, assetName);
  let installerExitCode;
  let installationError;

  try {
    const releaseUrl = checkedUrl(
      `https://api.github.com/repos/${repository}/releases/tags/v${version}`,
      apiHosts
    );
    const releaseBytes = downloadThroughSystemRoute(
      releaseUrl,
      "",
      2 * 1024 * 1024,
      apiHosts,
      process.env,
      60,
      true
    );
    const release = JSON.parse(releaseBytes.toString("utf8"));
    if (release.draft || release.prerelease || release.tag_name !== `v${version}` ||
        !Array.isArray(release.assets)) {
      throw new Error("GitHub 返回的版本不是指定的 ProxyGauge 正式版。");
    }

    const assetUrl = exactAsset(release, assetName, version);
    const checksumUrl = exactAsset(release, "SHA256SUMS.txt", version);
    const checksumBytes = downloadThroughSystemRoute(
      checksumUrl,
      "",
      1024 * 1024,
      assetHosts,
      process.env,
      60,
      true
    );
    const expectedSha256 = expectedChecksum(checksumBytes.toString("utf8"), assetName);
    console.log(`正在下载 ProxyGauge v${version} 正式版…`);
    downloadThroughSystemRoute(
      assetUrl,
      msiPath,
      512 * 1024 * 1024,
      assetHosts,
      process.env,
      600
    );
    const actualSha256 = await hashFile(msiPath);
    if (actualSha256 !== expectedSha256) {
      throw new Error("SHA-256 校验失败，安装已停止。");
    }

    console.log(
      "校验通过。Windows 将请求管理员授权；授权后会复制到受保护目录并再次校验。"
    );
    console.log(
      "安全提示：当前 MSI 尚未签名；npm 自动安装不提供浏览器下载时的 SmartScreen 信誉提示，且不会关闭系统安全设置。"
    );
    installerExitCode = await installMsiElevated(
      msiPath,
      expectedSha256,
      process.env
    );
    if (![0, 1641, 3010].includes(installerExitCode)) {
      throw new Error(`MSI 安装失败，退出代码：${installerExitCode}`);
    }
  } catch (error) {
    installationError = error;
  }

  let cleanupError;
  try {
    removeKnownTemporaryDirectory(temporaryDirectory, [
      assetName,
      "elevated-worker.ps1"
    ]);
  } catch (error) {
    cleanupError = error;
  }
  if (installationError) {
    if (cleanupError) {
      console.error(`警告：安装失败后，临时目录未能安全清理：${cleanupError.message}`);
    }
    throw installationError;
  }
  if (cleanupError) {
    throw new Error(`MSI 已返回成功，但临时目录未能安全清理：${cleanupError.message}`);
  }
  console.log(`已安装 ProxyGauge v${version} 正式版。`);
  if ([1641, 3010].includes(installerExitCode)) console.log("Windows 要求重启后完成安装。");
}

export {
  downloadCommand,
  elevatedBootstrapCommand,
  elevatedWorkerCommand,
  elevationLauncherCommand,
  exactAsset,
  encodeElevatedWorker,
  expectedChecksum,
  hashFile,
  installMsiElevated,
  materializeElevatedBootstrap,
  materializeElevatedWorker,
  noProxyMatches,
  nativeArchitectureCommand,
  proxySettingsFor,
  resolveNativeWindowsRuntime,
  runtimeForNativeMachine,
  sanitizedCmdArguments,
  systemCmdPath,
  systemPowerShellPath,
  temporaryBaseCandidate,
  temporaryDirectoryValidationCommand,
  validatedTemporaryBase
};

const modulePath = resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? resolve(process.argv[1]) : "";
const isDirectExecution = process.platform === "win32"
  ? invokedPath.toLowerCase() === modulePath.toLowerCase()
  : invokedPath === modulePath;
if (isDirectExecution) {
  main().catch(error => {
    console.error(`ProxyGauge Windows 安装失败：${error.message}`);
    process.exitCode = 1;
  });
}
