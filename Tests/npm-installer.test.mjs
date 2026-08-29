import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

import {
  installCommand,
  packageVersion,
  projectRoot,
  shouldRunPostinstall
} from "../Scripts/proxygauge-npm-lib.mjs";

const packageMetadata = JSON.parse(
  readFileSync(resolve(projectRoot, "package.json"), "utf8")
);

test("Windows installer carries a UTF-8 BOM for Windows PowerShell 5.1", () => {
  const installer = readFileSync(
    resolve(projectRoot, "Scripts/install-release-windows.ps1")
  );
  assert.deepEqual([...installer.subarray(0, 3)], [0xef, 0xbb, 0xbf]);
});

test("npm package version matches both native applications", () => {
  const plist = readFileSync(resolve(projectRoot, "Info.plist"), "utf8");
  const macVersion = plist.match(
    /<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/
  )?.[1];
  const windowsProject = readFileSync(
    resolve(projectRoot, "Windows/ProxyGauge.Windows.csproj"),
    "utf8"
  );
  const windowsVersion = windowsProject.match(/<Version>([^<]+)<\/Version>/)?.[1];

  assert.equal(packageVersion(), packageMetadata.version);
  assert.equal(macVersion, packageMetadata.version);
  assert.equal(windowsVersion, packageMetadata.version);
});

test("installer selection is explicit for every supported target", () => {
  assert.equal(installCommand("darwin", "arm64").executable, "/bin/bash");
  assert.match(
    installCommand("darwin", "arm64").arguments.at(-1),
    /install-release-macos\.sh$/
  );
  assert.equal(installCommand("win32", "x64").executable, "powershell.exe");
  assert.equal(installCommand("win32", "arm64").executable, "powershell.exe");
  assert.throws(() => installCommand("darwin", "x64"), /不支持当前平台/);
  assert.throws(() => installCommand("linux", "x64"), /不支持当前平台/);
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
