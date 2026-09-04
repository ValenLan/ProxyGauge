& {
$PreviousSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
try {
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repository = "ValenLan/ProxyGauge"
$MinimumWindowsBuild = 22000

function Assert-ExactReleaseAsset($Release, [string]$Name, [string]$Version) {
    $Matches = @($Release.assets | Where-Object { $_.name -eq $Name })
    if ($Matches.Count -ne 1 -or [string]::IsNullOrWhiteSpace($Matches[0].browser_download_url)) {
        throw "正式版缺少唯一的 ${Name}。"
    }
    $Expected = "https://github.com/$Repository/releases/download/v$Version/$Name"
    $Candidate = [Uri]$Matches[0].browser_download_url
    if (-not [string]::Equals($Candidate.AbsoluteUri, $Expected, [StringComparison]::Ordinal)) {
        throw "正式版 $Name 地址不属于指定的 GitHub Release。"
    }
}

function Test-ProxyBypass([Uri]$Uri, [string]$Rules) {
    if ([string]::IsNullOrWhiteSpace($Rules)) { return $false }
    $HostName = $Uri.Host.ToLowerInvariant()
    $TargetPort = if ($Uri.IsDefaultPort) {
        if ($Uri.Scheme -eq "https") { "443" } else { "80" }
    } else {
        $Uri.Port.ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    foreach ($RawEntry in $Rules.Split(',')) {
        $Entry = $RawEntry.Trim().ToLowerInvariant()
        if ($Entry -eq "*") { return $true }
        if ([string]::IsNullOrWhiteSpace($Entry)) { continue }
        $Domain = $Entry
        $Port = ""
        if ($Entry -match '^\[([^\]]+)\](?::(\d+))?$') {
            $Domain = $Matches[1]
            $Port = $Matches[2]
        } elseif ($Entry -match '^([^:]+):(\d+)$') {
            $Domain = $Matches[1]
            $Port = $Matches[2]
        }
        if ($Port -and $Port -ne $TargetPort) { continue }
        if ($Domain.StartsWith("*.")) {
            $Domain = $Domain.Substring(2)
        } elseif ($Domain.StartsWith(".")) {
            $Domain = $Domain.Substring(1)
        }
        if ($HostName -eq $Domain -or $HostName.EndsWith("." + $Domain)) { return $true }
    }
    return $false
}

function New-ExplicitProxy {
    $Proxy = [Net.WebProxy]::new([Uri]$ProxyUrl, $false)
    if (-not [string]::IsNullOrWhiteSpace($ProxyUsername)) {
        $CredentialUser = $ProxyUsername
        $DomainSeparator = $CredentialUser.IndexOf('\')
        if ($DomainSeparator -gt 0 -and $DomainSeparator -lt ($CredentialUser.Length - 1)) {
            $CredentialDomain = $CredentialUser.Substring(0, $DomainSeparator)
            $CredentialUser = $CredentialUser.Substring($DomainSeparator + 1)
            $Proxy.Credentials = [Net.NetworkCredential]::new(
                $CredentialUser,
                $ProxyPassword,
                $CredentialDomain
            )
        } else {
            $Proxy.Credentials = [Net.NetworkCredential]::new($CredentialUser, $ProxyPassword)
        }
    }
    return $Proxy
}

function Get-DownloadProxy([Uri]$Uri) {
    if ($ForceDirect -or (Test-ProxyBypass $Uri $NoProxyRules)) {
        return [Net.GlobalProxySelection]::GetEmptyWebProxy()
    }
    if (-not [string]::IsNullOrWhiteSpace($ProxyUrl)) { return New-ExplicitProxy }
    return [Net.WebRequest]::DefaultWebProxy
}

function Assert-LocalFixedDirectory([string]$Path) {
    $FullPath = [IO.Path]::GetFullPath($Path)
    $Root = [IO.Path]::GetPathRoot($FullPath)
    if ($Root -notmatch '^[A-Za-z]:\\$') {
        throw "临时目录必须位于本机固定磁盘。"
    }
    $Drive = [IO.DriveInfo]::new($Root)
    if ($Drive.DriveType -ne [IO.DriveType]::Fixed) {
        throw "临时目录不能位于网络盘或可移动磁盘。"
    }

    $Current = $Root
    $Relative = $FullPath.Substring($Root.Length)
    $Separators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    foreach ($Part in $Relative.Split($Separators, [StringSplitOptions]::RemoveEmptyEntries)) {
        $Current = [IO.Path]::Combine($Current, $Part)
        if (-not [IO.Directory]::Exists($Current)) { break }
        if (([IO.File]::GetAttributes($Current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "临时目录不能经过重解析点。"
        }
    }
    return $FullPath
}

function Remove-KnownInstallerTempDirectory([string]$Directory, [string[]]$KnownFiles) {
    if ([string]::IsNullOrWhiteSpace($Directory) -or -not [IO.Directory]::Exists($Directory)) {
        return
    }
    try {
        if (([IO.File]::GetAttributes($Directory) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Write-Warning "安装临时目录已变为重解析点，已停止自动清理：$Directory"
            return
        }
        $FullDirectory = [IO.Path]::GetFullPath($Directory).TrimEnd([char[]]@(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        ))
    } catch {
        Write-Warning ("无法安全解析安装临时目录：" + $_.Exception.Message)
        return
    }
    foreach ($KnownFile in $KnownFiles) {
        try {
            if ([string]::IsNullOrWhiteSpace($KnownFile)) { continue }
            $FullFile = [IO.Path]::GetFullPath($KnownFile)
            if (-not [string]::Equals(
                [IO.Path]::GetDirectoryName($FullFile),
                $FullDirectory,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                Write-Warning "拒绝清理临时目录之外的文件：$FullFile"
                continue
            }
            if ([IO.File]::Exists($FullFile)) { [IO.File]::Delete($FullFile) }
        } catch {
            Write-Warning ("未能清理安装临时文件：" + $_.Exception.Message)
        }
    }
    try {
        [IO.Directory]::Delete($FullDirectory, $false)
    } catch {
        Write-Warning ("未能完整清理安装临时目录：" + $_.Exception.Message)
    }
}

function Invoke-TrustedDownload(
    [Uri]$InitialUri,
    [string]$Destination,
    [long]$MaximumBytes,
    [int]$TimeoutSeconds,
    [string[]]$AllowedHostNames,
    [bool]$ReturnBase64 = $false
) {
    $AllowedHosts = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($AllowedHostName in $AllowedHostNames) { $null = $AllowedHosts.Add($AllowedHostName) }
    $Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $CurrentUri = $InitialUri
    $Completed = $false
    $ResultBase64 = $null
    for ($RedirectCount = 0; $RedirectCount -le 5; $RedirectCount++) {
        if ([DateTime]::UtcNow -ge $Deadline) { throw "下载网络读取超过时限。" }
        if ($CurrentUri.Scheme -ne "https" -or -not $AllowedHosts.Contains($CurrentUri.Host)) {
            throw "下载重定向到不受信任的地址。"
        }
        $Request = [Net.HttpWebRequest]::Create($CurrentUri)
        $Request.Method = "GET"
        $Request.Accept = "application/vnd.github+json, application/octet-stream;q=0.9, text/plain;q=0.8"
        $Request.UserAgent = "ProxyGauge-Release-Installer"
        $Request.Headers["X-GitHub-Api-Version"] = "2022-11-28"
        $Request.AllowAutoRedirect = $false
        $Remaining = [Math]::Max(1, [Math]::Min(
            [int]::MaxValue,
            [int]($Deadline - [DateTime]::UtcNow).TotalMilliseconds
        ))
        $Request.Timeout = $Remaining
        $Request.ReadWriteTimeout = $Remaining
        $Request.Proxy = Get-DownloadProxy $CurrentUri
        $Response = $null
        $InputStream = $null
        $OutputStream = $null
        try {
            $Response = [Net.HttpWebResponse]$Request.GetResponse()
            $StatusCode = [int]$Response.StatusCode
            if ($StatusCode -ge 300 -and $StatusCode -le 399) {
                if ($RedirectCount -ge 5) { throw "正式版下载重定向次数过多。" }
                $Location = $Response.Headers["Location"]
                if ([string]::IsNullOrWhiteSpace($Location)) { throw "下载响应缺少重定向地址。" }
                $CurrentUri = [Uri]::new($CurrentUri, $Location)
                continue
            }
            if ($StatusCode -lt 200 -or $StatusCode -gt 299) { throw "HTTP $StatusCode" }
            if ($Response.ContentLength -gt $MaximumBytes) { throw "正式版响应超过安全大小限制。" }
            $InputStream = $Response.GetResponseStream()
            if ($ReturnBase64) {
                $OutputStream = [IO.MemoryStream]::new()
            } else {
                $OutputStream = [IO.FileStream]::new(
                    $Destination,
                    [IO.FileMode]::CreateNew,
                    [IO.FileAccess]::Write,
                    [IO.FileShare]::None
                )
            }
            $Buffer = [byte[]]::new(8192)
            $Total = [long]0
            while ($true) {
                $RemainingRead = [int]($Deadline - [DateTime]::UtcNow).TotalMilliseconds
                if ($RemainingRead -le 0) { throw "下载网络读取超过时限。" }
                if (-not $InputStream.CanTimeout) { throw "下载流不支持读取时限。" }
                $InputStream.ReadTimeout = [Math]::Max(1, $RemainingRead)
                $Read = $InputStream.Read($Buffer, 0, $Buffer.Length)
                if ($Read -le 0) { break }
                $Total += $Read
                if ($Total -gt $MaximumBytes) { throw "正式版响应超过安全大小限制。" }
                $OutputStream.Write($Buffer, 0, $Read)
            }
            if ($Total -le 0) { throw "正式版响应为空。" }
            if ($ReturnBase64) {
                $ResultBase64 = [Convert]::ToBase64String($OutputStream.ToArray())
            }
            $Completed = $true
            break
        } finally {
            if ($null -ne $OutputStream) { $OutputStream.Dispose() }
            if ($null -ne $InputStream) { $InputStream.Dispose() }
            if ($null -ne $Response) { $Response.Dispose() }
        }
    }
    if (-not $Completed) { throw "正式版下载未完成。" }
    if ($ReturnBase64) { return $ResultBase64 }
}

$NoProxyRules = @(
    $env:npm_config_noproxy,
    $env:NO_PROXY,
    $env:no_proxy
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
$ProxyText = @(
    $env:npm_config_https_proxy,
    $env:npm_config_proxy,
    $env:HTTPS_PROXY,
    $env:https_proxy,
    $env:HTTP_PROXY,
    $env:http_proxy
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
$NoProxyRules = [string]$NoProxyRules
$ProxyText = ([string]$ProxyText).Trim()
$ForceDirect = $ProxyText.ToLowerInvariant() -in @("false", "null")
$ProxyUrl = ""
$ProxyUsername = ""
$ProxyPassword = ""
if (-not [string]::IsNullOrWhiteSpace($ProxyText) -and -not $ForceDirect) {
    $ProxyCandidate = $null
    if (-not [Uri]::TryCreate($ProxyText, [UriKind]::Absolute, [ref]$ProxyCandidate)) {
        throw "npm/系统代理地址格式无效。"
    }
    if ($ProxyCandidate.Scheme -ne "http") {
        throw "Windows PowerShell 5.1 下载仅支持 HTTP 代理地址（HTTPS 目标仍使用 TLS）。"
    }
    if ([string]::IsNullOrWhiteSpace($ProxyCandidate.Host) -or
        $ProxyCandidate.AbsolutePath -ne "/" -or
        -not [string]::IsNullOrEmpty($ProxyCandidate.Query) -or
        -not [string]::IsNullOrEmpty($ProxyCandidate.Fragment)) {
        throw "npm/系统代理必须是只含主机、端口和可选凭据的 HTTP 地址。"
    }
    $UserInfo = $ProxyCandidate.UserInfo
    if (-not [string]::IsNullOrEmpty($UserInfo)) {
        $Separator = $UserInfo.IndexOf(':')
        if ($Separator -ge 0) {
            $ProxyUsername = [Uri]::UnescapeDataString($UserInfo.Substring(0, $Separator))
            $ProxyPassword = [Uri]::UnescapeDataString($UserInfo.Substring($Separator + 1))
        } else {
            $ProxyUsername = [Uri]::UnescapeDataString($UserInfo)
        }
    }
    if ($ProxyPassword -and -not $ProxyUsername) { throw "代理密码缺少用户名。" }
    $ProxyBuilder = [UriBuilder]::new($ProxyCandidate)
    $ProxyBuilder.UserName = ""
    $ProxyBuilder.Password = ""
    $ProxyUrl = $ProxyBuilder.Uri.AbsoluteUri
}

if (-not [Environment]::Is64BitOperatingSystem) {
    throw "ProxyGauge 正式版仅支持 64 位 Windows 11。"
}

$WindowsKey = $null
$ProductKey = $null
try {
    $WindowsKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        "SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    )
    $ProductKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        "SYSTEM\CurrentControlSet\Control\ProductOptions"
    )
    if ($null -eq $WindowsKey -or $null -eq $ProductKey) {
        throw "无法读取受保护的 Windows 版本信息。"
    }
    $BuildText = [string]$WindowsKey.GetValue("CurrentBuild")
    $ProductType = [string]$ProductKey.GetValue("ProductType")
} finally {
    if ($null -ne $WindowsKey) { $WindowsKey.Dispose() }
    if ($null -ne $ProductKey) { $ProductKey.Dispose() }
}
$WindowsBuild = 0
if (-not [int]::TryParse($BuildText, [ref]$WindowsBuild) -or
    $WindowsBuild -lt $MinimumWindowsBuild -or $ProductType -ne "WinNT") {
    throw "ProxyGauge 正式版仅支持 Windows 11，不支持 Windows 10 或 Windows Server。"
}

$PowerShellPath = [IO.Path]::Combine(
    [Environment]::SystemDirectory,
    "WindowsPowerShell", "v1.0", "powershell.exe"
)
if (-not [IO.File]::Exists($PowerShellPath)) { throw "无法定位受保护的 Windows PowerShell。" }
$ArchitectureCommand = @'
$ErrorActionPreference = 'Stop'
$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
Import-Module ([IO.Path]::Combine($PSHOME, 'Modules', 'Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Utility.psd1')) -ErrorAction Stop
$Source = @"
using System;
using System.Runtime.InteropServices;
public static class ProxyGaugeNativeArchitecture {
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);
}
"@
Add-Type -TypeDefinition $Source -ErrorAction Stop
[UInt16]$ProcessMachine = 0
[UInt16]$NativeMachine = 0
$Process = [Diagnostics.Process]::GetCurrentProcess()
if (-not [ProxyGaugeNativeArchitecture]::IsWow64Process2(
    $Process.Handle, [ref]$ProcessMachine, [ref]$NativeMachine
)) {
    throw ('IsWow64Process2 failed: ' + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
}
[Console]::Out.WriteLine($NativeMachine.ToString('X4'))
'@
$ArchitectureStartInfo = [Diagnostics.ProcessStartInfo]::new()
$ArchitectureStartInfo.FileName = $PowerShellPath
$ArchitectureStartInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -EncodedCommand " +
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ArchitectureCommand))
$ArchitectureStartInfo.UseShellExecute = $false
$ArchitectureStartInfo.CreateNoWindow = $true
$ArchitectureStartInfo.RedirectStandardOutput = $true
$ArchitectureStartInfo.RedirectStandardError = $true
$ArchitectureProcess = [Diagnostics.Process]::Start($ArchitectureStartInfo)
$ArchitectureOutput = ""
$ArchitectureError = ""
$ArchitectureExitCode = -1
try {
    if (-not $ArchitectureProcess.WaitForExit(15000)) {
        $ArchitectureProcess.Kill()
        throw "检测 Windows 原生架构超过 15 秒。"
    }
    $ArchitectureOutput = $ArchitectureProcess.StandardOutput.ReadToEnd().Trim()
    $ArchitectureError = $ArchitectureProcess.StandardError.ReadToEnd().Trim()
    $ArchitectureExitCode = $ArchitectureProcess.ExitCode
} finally {
    $ArchitectureProcess.Dispose()
}
if ($ArchitectureExitCode -ne 0) {
    throw "无法检测 Windows 原生架构：$ArchitectureError"
}
$NativeMachine = ($ArchitectureOutput -split '\r?\n')[-1].ToUpperInvariant()
$Runtime = switch ($NativeMachine) {
    "8664" { "win-x64" }
    "AA64" { "win-arm64" }
    default { throw "不支持的 Windows 原生架构：$NativeMachine" }
}

$RequestedVersion = $env:PROXYGAUGE_VERSION
$ReleaseUri = "https://api.github.com/repos/$Repository/releases/latest"
if (-not [string]::IsNullOrWhiteSpace($RequestedVersion)) {
    if ($RequestedVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw "无效的 ProxyGauge 指定版本：$RequestedVersion"
    }
    $ReleaseUri = "https://api.github.com/repos/$Repository/releases/tags/v$RequestedVersion"
}
$TempBase = Assert-LocalFixedDirectory ([IO.Path]::GetTempPath())
$TempDirectory = [IO.Path]::Combine(
    $TempBase,
    ("proxygauge-release-" + [Guid]::NewGuid().ToString("N"))
)
$null = [IO.Directory]::CreateDirectory($TempDirectory)
$MsiPath = $null
$WorkerPath = $null
try {
    $ReleaseBase64 = Invoke-TrustedDownload `
        ([Uri]$ReleaseUri) "" 2097152 60 @("api.github.com") $true
    $ReleaseJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ReleaseBase64))
    $Release = $ReleaseJson | ConvertFrom-Json
    if ($Release.draft -or $Release.prerelease -or $Release.tag_name -notmatch '^v\d+\.\d+\.\d+$') {
        throw "GitHub 返回的版本不是 ProxyGauge 正式版。"
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestedVersion) -and
        $Release.tag_name -ne "v$RequestedVersion") {
        throw "GitHub 返回的版本 $($Release.tag_name) 与指定版本 v$RequestedVersion 不一致。"
    }

    $Version = $Release.tag_name.Substring(1)
    $AssetName = "ProxyGauge-$Version-$Runtime.msi"
    Assert-ExactReleaseAsset $Release $AssetName $Version
    Assert-ExactReleaseAsset $Release "SHA256SUMS.txt" $Version
    $ReleaseBase = "https://github.com/$Repository/releases/download/v$Version"
    $MsiPath = [IO.Path]::Combine($TempDirectory, $AssetName)

    Write-Host "正在下载 ProxyGauge v$Version 正式版…"
    $ChecksumBase64 = Invoke-TrustedDownload ([Uri]"$ReleaseBase/SHA256SUMS.txt") `
        "" 1048576 60 @(
        "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"
    ) $true
    Invoke-TrustedDownload ([Uri]"$ReleaseBase/$AssetName") $MsiPath 536870912 600 @(
        "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"
    )
    $ChecksumText = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String($ChecksumBase64)
    )
    $Expected = $null
    foreach ($Line in $ChecksumText -split '\r?\n') {
        $Match = [Text.RegularExpressions.Regex]::Match($Line, '^([0-9A-Fa-f]{64})\s+\*?(.+)$')
        if ($Match.Success -and $Match.Groups[2].Value -eq $AssetName) {
            if ($null -ne $Expected) { throw "SHA256SUMS.txt 含重复安装包校验值。" }
            $Expected = $Match.Groups[1].Value.ToLowerInvariant()
        }
    }
    if ($null -eq $Expected) { throw "SHA256SUMS.txt 缺少当前安装包校验值。" }
    $Stream = [IO.File]::OpenRead($MsiPath)
    $Sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $Actual = ([BitConverter]::ToString($Sha256.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant()
    } finally {
        $Sha256.Dispose()
        $Stream.Dispose()
    }
    if ($Actual -ne $Expected) { throw "SHA-256 校验失败，安装已停止。" }

    $ElevatedWorker = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PSModuleAutoLoadingPreference = 'None'
function Decode-Payload([string]$Value) {
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
}
$SourceMsi = Decode-Payload '__PROXYGAUGE_SOURCE_MSI_UTF8__'
$Expected = Decode-Payload '__PROXYGAUGE_EXPECTED_SHA256_UTF8__'
$SecureDirectory = $null
$SecureMsi = $null
$ExitCode = 1
try {
    if ($Expected -notmatch '^[0-9a-f]{64}$' -or -not [IO.File]::Exists($SourceMsi)) {
        throw '提权安装参数无效。'
    }
    $SourceLength = [IO.FileInfo]::new($SourceMsi).Length
    if ($SourceLength -le 0 -or $SourceLength -gt 536870912) { throw '安装包大小无效。' }
    $ProgramFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    if ([string]::IsNullOrWhiteSpace($ProgramFiles)) { throw '无法定位受保护的 Program Files。' }
    $SecureDirectory = [IO.Path]::Combine(
        $ProgramFiles,
        ('ProxyGauge Installer ' + [Guid]::NewGuid().ToString('N'))
    )
    $null = [IO.Directory]::CreateDirectory($SecureDirectory)
    $SecureMsi = [IO.Path]::Combine($SecureDirectory, 'ProxyGauge.msi')
    [IO.File]::Copy($SourceMsi, $SecureMsi, $false)
    $Stream = [IO.File]::OpenRead($SecureMsi)
    $Sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $Actual = ([BitConverter]::ToString($Sha256.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant()
    } finally {
        $Sha256.Dispose()
        $Stream.Dispose()
    }
    if ($Actual -ne $Expected) { throw '提权后的 SHA-256 复核失败，安装已停止。' }
    $MsiExec = [IO.Path]::Combine([Environment]::SystemDirectory, 'msiexec.exe')
    $StartInfo = [Diagnostics.ProcessStartInfo]::new()
    $StartInfo.FileName = $MsiExec
    $StartInfo.Arguments = '/i "' + $SecureMsi + '" /passive /norestart'
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    $Installer = [Diagnostics.Process]::Start($StartInfo)
    try {
        if (-not $Installer.WaitForExit(1800000)) {
            try { $Installer.Kill() } catch {}
            throw 'Windows Installer 超过 30 分钟仍未完成，安装已停止等待。'
        }
        $ExitCode = $Installer.ExitCode
    } finally {
        if ($null -ne $Installer) { $Installer.Dispose() }
    }
} catch {
    $ExitCode = 1
} finally {
    try {
        if ($null -ne $SecureDirectory -and [IO.Directory]::Exists($SecureDirectory)) {
            if (([IO.File]::GetAttributes($SecureDirectory) -band
                [IO.FileAttributes]::ReparsePoint) -eq 0) {
                if ($null -ne $SecureMsi -and [IO.File]::Exists($SecureMsi)) {
                    [IO.File]::Delete($SecureMsi)
                }
                [IO.Directory]::Delete($SecureDirectory, $false)
            }
        }
    } catch {}
}
return $ExitCode
'@
    $ElevatedWorker = $ElevatedWorker.Replace(
        '__PROXYGAUGE_SOURCE_MSI_UTF8__',
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($MsiPath))
    ).Replace(
        '__PROXYGAUGE_EXPECTED_SHA256_UTF8__',
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Expected))
    )
    $null = [ScriptBlock]::Create($ElevatedWorker)
    $WorkerPath = [IO.Path]::Combine($TempDirectory, "elevated-worker.ps1")
    $WorkerBytes = [Text.UTF8Encoding]::new($false).GetBytes($ElevatedWorker)
    $WorkerSha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $ExpectedWorker = ([BitConverter]::ToString(
            $WorkerSha256.ComputeHash($WorkerBytes)
        )).Replace('-', '').ToLowerInvariant()
    } finally {
        $WorkerSha256.Dispose()
    }
    $WorkerStream = [IO.FileStream]::new(
        $WorkerPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try {
        $WorkerStream.Write($WorkerBytes, 0, $WorkerBytes.Length)
        $WorkerStream.Flush($true)
    } finally {
        $WorkerStream.Dispose()
    }
$ElevatedBootstrap = @'
$ErrorActionPreference = 'Stop'
$PSModuleAutoLoadingPreference = 'None'
function Decode-Payload([string]$Value) {
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
}
$SourceWorker = Decode-Payload '__PROXYGAUGE_WORKER_PATH_UTF8__'
$ExpectedWorker = Decode-Payload '__PROXYGAUGE_WORKER_SHA256_UTF8__'
$SecureDirectory = $null
$SecureWorker = $null
$ExitCode = 1
try {
    if ($ExpectedWorker -notmatch '^[0-9a-f]{64}$' -or -not [IO.File]::Exists($SourceWorker)) {
        throw '提权工作文件参数无效。'
    }
    $SourceLength = [IO.FileInfo]::new($SourceWorker).Length
    if ($SourceLength -le 0 -or $SourceLength -gt 131072) { throw '提权工作文件大小无效。' }
    $ProgramFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    if ([string]::IsNullOrWhiteSpace($ProgramFiles)) { throw '无法定位受保护的 Program Files。' }
    $SecureDirectory = [IO.Path]::Combine(
        $ProgramFiles,
        ('ProxyGauge Bootstrap ' + [Guid]::NewGuid().ToString('N'))
    )
    $null = [IO.Directory]::CreateDirectory($SecureDirectory)
    $SecureWorker = [IO.Path]::Combine($SecureDirectory, 'worker.ps1')
    [IO.File]::Copy($SourceWorker, $SecureWorker, $false)
    $Stream = [IO.File]::OpenRead($SecureWorker)
    $Sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $ActualWorker = ([BitConverter]::ToString(
            $Sha256.ComputeHash($Stream)
        )).Replace('-', '').ToLowerInvariant()
    } finally {
        $Sha256.Dispose()
        $Stream.Dispose()
    }
    if ($ActualWorker -ne $ExpectedWorker) { throw '提权工作文件 SHA-256 复核失败。' }
    $WorkerScript = [ScriptBlock]::Create([IO.File]::ReadAllText($SecureWorker))
    $WorkerOutput = @(& $WorkerScript)
    if ($WorkerOutput.Count -ne 1 -or
        -not [int]::TryParse([string]$WorkerOutput[0], [ref]$ExitCode)) {
        throw '提权工作文件没有返回有效退出代码。'
    }
} catch {
    $ExitCode = 1
} finally {
    try {
        if ($null -ne $SecureDirectory -and [IO.Directory]::Exists($SecureDirectory)) {
            if (([IO.File]::GetAttributes($SecureDirectory) -band
                [IO.FileAttributes]::ReparsePoint) -eq 0) {
                if ($null -ne $SecureWorker -and [IO.File]::Exists($SecureWorker)) {
                    [IO.File]::Delete($SecureWorker)
                }
                [IO.Directory]::Delete($SecureDirectory, $false)
            }
        }
    } catch {}
}
exit $ExitCode
'@
    $ElevatedBootstrap = $ElevatedBootstrap.Replace(
        '__PROXYGAUGE_WORKER_PATH_UTF8__',
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($WorkerPath))
    ).Replace(
        '__PROXYGAUGE_WORKER_SHA256_UTF8__',
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ExpectedWorker))
    )
    $null = [ScriptBlock]::Create($ElevatedBootstrap)
    $EncodedBootstrap = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($ElevatedBootstrap)
    )
    $WorkerArguments = "-NoLogo -NoProfile -NonInteractive -EncodedCommand $EncodedBootstrap"
    $DangerousEnvironmentVariables = @(
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
    )
    $ClearEnvironment = ($DangerousEnvironmentVariables | ForEach-Object {
        'set "' + $_ + '="'
    }) -join ' & '
    $CmdPath = [IO.Path]::Combine([Environment]::SystemDirectory, "cmd.exe")
    if (-not [IO.File]::Exists($CmdPath)) { throw "无法定位受保护的 Windows 命令处理器。" }
    $SanitizedWorkerArguments = '/d /c ' + $ClearEnvironment + ' & "' +
        $PowerShellPath + '" ' + $WorkerArguments
    if ($SanitizedWorkerArguments.Length -gt 8000) {
        throw "提权安装命令超过 cmd.exe 的安全长度限制。"
    }
    Write-Host "校验通过。Windows 将请求管理员授权，并在受保护目录复核安装包。"
    Write-Host "安全提示：当前 MSI 尚未签名；脚本安装不提供浏览器下载时的 SmartScreen 信誉提示，且不会关闭系统安全设置。"
    $StartInfo = [Diagnostics.ProcessStartInfo]::new()
    $StartInfo.FileName = $CmdPath
    $StartInfo.Arguments = $SanitizedWorkerArguments
    $StartInfo.UseShellExecute = $true
    $StartInfo.Verb = "RunAs"
    $Worker = [Diagnostics.Process]::Start($StartInfo)
    try {
        $Worker.WaitForExit()
        $InstallerExitCode = $Worker.ExitCode
    } finally {
        $Worker.Dispose()
    }

    if ($InstallerExitCode -notin @(0, 1641, 3010)) {
        throw "MSI 安装失败，退出代码：${InstallerExitCode}；安装包复制、复核或 Windows Installer 未完成。"
    }
    Write-Host "已安装 ProxyGauge v$Version 正式版。"
    if ($InstallerExitCode -in @(1641, 3010)) { Write-Host "Windows 要求重启后完成安装。" }
} finally {
    Remove-KnownInstallerTempDirectory $TempDirectory ([string[]]@($MsiPath, $WorkerPath))
}
} finally {
    [Net.ServicePointManager]::SecurityProtocol = $PreviousSecurityProtocol
}
}
