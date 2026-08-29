$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repository = "ValenLan/ProxyGauge"
$MinimumWindowsBuild = 22000

if (-not [Environment]::Is64BitOperatingSystem) {
    throw "ProxyGauge 正式版仅支持 64 位 Windows 11。"
}

$BuildText = (Get-ItemProperty `
    "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" `
    -Name CurrentBuild).CurrentBuild
$WindowsBuild = 0
if (-not [int]::TryParse($BuildText, [ref]$WindowsBuild) -or $WindowsBuild -lt $MinimumWindowsBuild) {
    throw "ProxyGauge 正式版仅支持 Windows 11，不支持 Windows 10 或 Windows Server。"
}

$NativeArchitecture = if ($env:PROCESSOR_ARCHITEW6432) {
    $env:PROCESSOR_ARCHITEW6432
} else {
    $env:PROCESSOR_ARCHITECTURE
}

$Runtime = switch ($NativeArchitecture.ToUpperInvariant()) {
    "AMD64" { "win-x64" }
    "ARM64" { "win-arm64" }
    default { throw "不支持的 Windows 架构：$NativeArchitecture" }
}

$Headers = @{
    Accept = "application/vnd.github+json"
    "User-Agent" = "ProxyGauge-Release-Installer"
    "X-GitHub-Api-Version" = "2022-11-28"
}
$RequestedVersion = $env:PROXYGAUGE_VERSION
$ReleaseUri = "https://api.github.com/repos/$Repository/releases/latest"
if (-not [string]::IsNullOrWhiteSpace($RequestedVersion)) {
    if ($RequestedVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw "无效的 ProxyGauge 指定版本：$RequestedVersion"
    }
    $ReleaseUri = "https://api.github.com/repos/$Repository/releases/tags/v$RequestedVersion"
}
$Release = Invoke-RestMethod `
    -Uri $ReleaseUri `
    -Headers $Headers

if ($Release.draft -or $Release.prerelease -or $Release.tag_name -notmatch '^v\d+\.\d+\.\d+$') {
    throw "GitHub 返回的版本不是 ProxyGauge 正式版。"
}
if (-not [string]::IsNullOrWhiteSpace($RequestedVersion) -and `
    $Release.tag_name -ne "v$RequestedVersion") {
    throw "GitHub 返回的版本 $($Release.tag_name) 与指定版本 v$RequestedVersion 不一致。"
}

$Version = $Release.tag_name.Substring(1)
$AssetName = "ProxyGauge-$Version-$Runtime.msi"
$InstallerAssets = @($Release.assets | Where-Object { $_.name -eq $AssetName })
$ChecksumAssets = @($Release.assets | Where-Object { $_.name -eq "SHA256SUMS.txt" })

if ($InstallerAssets.Count -ne 1 -or $ChecksumAssets.Count -ne 1) {
    throw "正式版缺少 $AssetName 或 SHA256SUMS.txt。"
}

$TempDirectory = Join-Path ([IO.Path]::GetTempPath()) `
    ("proxygauge-release-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempDirectory | Out-Null

try {
    $MsiPath = Join-Path $TempDirectory $AssetName
    $ChecksumPath = Join-Path $TempDirectory "SHA256SUMS.txt"

    Write-Host "正在下载 ProxyGauge $($Release.tag_name) 正式版…"
    Invoke-WebRequest `
        -UseBasicParsing `
        -Uri $InstallerAssets[0].browser_download_url `
        -OutFile $MsiPath
    Invoke-WebRequest `
        -UseBasicParsing `
        -Uri $ChecksumAssets[0].browser_download_url `
        -OutFile $ChecksumPath

    $ChecksumText = Get-Content -Raw -Path $ChecksumPath
    $ChecksumPattern = "(?im)^([0-9a-f]{64})\s+\*?$([regex]::Escape($AssetName))\s*$"
    $ChecksumMatch = [regex]::Match($ChecksumText, $ChecksumPattern)
    if (-not $ChecksumMatch.Success) {
        throw "SHA256SUMS.txt 中没有 $AssetName 的有效校验值。"
    }

    $ExpectedSha = $ChecksumMatch.Groups[1].Value.ToLowerInvariant()
    $ActualSha = (Get-FileHash -Algorithm SHA256 -Path $MsiPath).Hash.ToLowerInvariant()
    if ($ActualSha -ne $ExpectedSha) {
        throw "SHA-256 校验失败，安装已停止。"
    }

    Write-Host "校验通过。Windows 将请求管理员权限以安装正式版和 Guard Service。"
    $Installer = Start-Process `
        -FilePath "msiexec.exe" `
        -Verb RunAs `
        -ArgumentList @("/i", "`"$MsiPath`"", "/passive", "/norestart") `
        -Wait `
        -PassThru

    if ($Installer.ExitCode -notin @(0, 3010)) {
        throw "MSI 安装失败，退出代码：$($Installer.ExitCode)"
    }

    Write-Host "已安装 ProxyGauge $($Release.tag_name) 正式版。"
    if ($Installer.ExitCode -eq 3010) {
        Write-Host "Windows 要求重启后完成安装。"
    }
    Write-Host "当前正式版尚未购买代码签名证书；脚本不会绕过 Windows 安全检查。"
} finally {
    if (Test-Path -LiteralPath $TempDirectory) {
        Remove-Item -LiteralPath $TempDirectory -Recurse -Force
    }
}
