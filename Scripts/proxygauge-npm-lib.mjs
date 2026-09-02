import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

export const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

export function packageVersion(root = projectRoot) {
  const metadata = JSON.parse(readFileSync(resolve(root, "package.json"), "utf8"));
  if (!/^\d+\.\d+\.\d+$/.test(metadata.version)) {
    throw new Error(`不支持的 npm 包版本：${metadata.version}`);
  }
  return metadata.version;
}

export function installCommand(platform, architecture, root = projectRoot) {
  if (platform === "darwin" && architecture === "arm64") {
    return {
      executable: "/bin/bash",
      arguments: ["-p", resolve(root, "Scripts/install-release-macos.sh")],
      label: "macOS arm64"
    };
  }

  if (platform === "win32" && ["x64", "arm64"].includes(architecture)) {
    return {
      executable: process.execPath,
      arguments: [resolve(root, "Scripts/install-release-windows.mjs")],
      label: `Windows ${architecture}`
    };
  }

  throw new Error(
    `ProxyGauge 不支持当前平台：${platform}/${architecture}。` +
      "支持 Apple Silicon Mac、Windows 11 x64 和 Windows 11 ARM64。"
  );
}

export function resolveHardwareArchitecture(platform, architecture, arm64Capability = "") {
  if (platform === "darwin" && architecture === "x64" && arm64Capability.trim() === "1") {
    return "arm64";
  }
  return architecture;
}

export function resolveWindowsRuntime(environment, architecture) {
  const native = (
    environment.PROCESSOR_ARCHITEW6432 ||
    environment.PROCESSOR_ARCHITECTURE ||
    architecture
  ).toUpperCase();
  if (native === "ARM64") return "win-arm64";
  if (["AMD64", "X64"].includes(native)) return "win-x64";
  if (architecture === "arm64") return "win-arm64";
  if (architecture === "x64") return "win-x64";
  throw new Error(`不支持的 Windows 架构：${native || architecture}`);
}

export function detectedArchitecture(platform, architecture, environment = process.env) {
  if (platform === "win32") {
    return resolveWindowsRuntime(environment, architecture).slice("win-".length);
  }
  if (platform !== "darwin" || architecture !== "x64") return architecture;
  const result = spawnSync("/usr/sbin/sysctl", ["-n", "hw.optional.arm64"], {
    encoding: "utf8",
    windowsHide: true
  });
  return resolveHardwareArchitecture(platform, architecture, result.stdout ?? "");
}

export function shouldRunPostinstall(environment) {
  if (environment.PROXYGAUGE_FORCE_INSTALL === "1") {
    return true;
  }
  return environment.npm_config_global === "true";
}

const proxyEnvironmentNames = [
  "npm_config_https_proxy",
  "npm_config_proxy",
  "npm_config_noproxy",
  "HTTPS_PROXY",
  "https_proxy",
  "HTTP_PROXY",
  "http_proxy",
  "NO_PROXY",
  "no_proxy"
];

export function nativeInstallerEnvironment(platform, environment, version) {
  const platformNames = platform === "win32"
    ? ["SystemRoot", "WINDIR", "TEMP", "TMP"]
    : platform === "darwin"
      ? ["HOME", "TMPDIR", "ALL_PROXY", "all_proxy"]
      : [];
  const allowedNames = new Set(
    [...proxyEnvironmentNames, ...platformNames].map(name =>
      platform === "win32" ? name.toLowerCase() : name
    )
  );
  const selected = Object.fromEntries(
    Object.entries(environment).filter(([name]) =>
      allowedNames.has(platform === "win32" ? name.toLowerCase() : name)
    )
  );
  return {
    ...selected,
    PROXYGAUGE_VERSION: version
  };
}

export function runNativeInstaller({
  platform = process.platform,
  architecture,
  environment = process.env,
  root = projectRoot,
  dryRun = environment.PROXYGAUGE_INSTALL_DRY_RUN === "1"
} = {}) {
  const targetArchitecture = detectedArchitecture(
    platform,
    architecture ?? process.arch,
    environment
  );
  const version = packageVersion(root);
  const command = installCommand(platform, targetArchitecture, root);

  if (dryRun) {
    console.log(
      `ProxyGauge npm 安装器检查通过：将为 ${command.label} 安装 GitHub Release v${version}。`
    );
    return 0;
  }

  const result = spawnSync(command.executable, command.arguments, {
    cwd: root,
    env: nativeInstallerEnvironment(platform, environment, version),
    stdio: "inherit",
    windowsHide: false
  });

  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(`ProxyGauge 原生安装器退出，代码：${result.status ?? "unknown"}`);
  }
  return 0;
}
