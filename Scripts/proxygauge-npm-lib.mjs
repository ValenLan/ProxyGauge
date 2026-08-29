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
      arguments: [resolve(root, "Scripts/install-release-macos.sh")],
      label: "macOS arm64"
    };
  }

  if (platform === "win32" && ["x64", "arm64"].includes(architecture)) {
    return {
      executable: "powershell.exe",
      arguments: [
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-File",
        resolve(root, "Scripts/install-release-windows.ps1")
      ],
      label: `Windows ${architecture}`
    };
  }

  throw new Error(
    `ProxyGauge 不支持当前平台：${platform}/${architecture}。` +
      "支持 Apple Silicon Mac、Windows 11 x64 和 Windows 11 ARM64。"
  );
}

export function shouldRunPostinstall(environment) {
  if (environment.PROXYGAUGE_FORCE_INSTALL === "1") {
    return true;
  }
  return environment.npm_config_global === "true";
}

export function runNativeInstaller({
  platform = process.platform,
  architecture = process.arch,
  environment = process.env,
  root = projectRoot,
  dryRun = environment.PROXYGAUGE_INSTALL_DRY_RUN === "1"
} = {}) {
  const version = packageVersion(root);
  const command = installCommand(platform, architecture, root);

  if (dryRun) {
    console.log(
      `ProxyGauge npm 安装器检查通过：将为 ${command.label} 安装 GitHub Release v${version}。`
    );
    return 0;
  }

  const result = spawnSync(command.executable, command.arguments, {
    cwd: root,
    env: {
      ...environment,
      PROXYGAUGE_VERSION: version
    },
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
