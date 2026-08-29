#!/usr/bin/env node

import {
  packageVersion,
  runNativeInstaller,
  shouldRunPostinstall
} from "./proxygauge-npm-lib.mjs";

function printHelp() {
  console.log(`ProxyGauge npm installer

Usage:
  proxygauge install    Reinstall the native app matching this npm package version
  proxygauge --version  Print the package version
  proxygauge --help     Show this help`);
}

function main() {
  const argumentsList = process.argv.slice(2);
  const postinstall = argumentsList.includes("--postinstall");
  const command = argumentsList.find((argument) => !argument.startsWith("--")) ?? "install";

  if (postinstall && !shouldRunPostinstall(process.env)) {
    console.log(
      "ProxyGauge 桌面应用只在全局安装时自动安装；请运行 npm install -g proxygauge。"
    );
    return;
  }

  if (["--version", "-v", "version"].some((argument) => argumentsList.includes(argument))) {
    console.log(packageVersion());
    return;
  }

  if (["--help", "-h", "help"].some((argument) => argumentsList.includes(argument))) {
    printHelp();
    return;
  }

  if (command !== "install") {
    throw new Error(`未知命令：${command}`);
  }

  runNativeInstaller();
}

try {
  main();
} catch (error) {
  console.error(`ProxyGauge 安装失败：${error.message}`);
  process.exitCode = 1;
}
