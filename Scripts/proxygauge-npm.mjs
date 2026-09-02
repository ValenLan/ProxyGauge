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
  if (argumentsList.length === 0) {
    runNativeInstaller();
    return;
  }

  if (argumentsList.length === 1 && ["--version", "-v", "version"].includes(argumentsList[0])) {
    console.log(packageVersion());
    return;
  }

  if (argumentsList.length === 1 && ["--help", "-h", "help"].includes(argumentsList[0])) {
    printHelp();
    return;
  }

  if (argumentsList.length === 1 && argumentsList[0] === "install") {
    runNativeInstaller();
    return;
  }

  if (argumentsList.length === 2 &&
      argumentsList[0] === "install" &&
      argumentsList[1] === "--postinstall") {
    if (process.env.npm_lifecycle_event !== "postinstall") {
      throw new Error("--postinstall 只能由 npm postinstall 生命周期调用。");
    }
    if (!shouldRunPostinstall(process.env)) {
      console.log(
        "ProxyGauge 桌面应用只在全局安装时自动安装；请运行 npm install -g proxygauge。"
      );
      return;
    }
    runNativeInstaller();
    return;
  }

  throw new Error(`未知或多余的参数：${argumentsList.join(" ")}`);
}

try {
  main();
} catch (error) {
  console.error(`ProxyGauge 安装失败：${error.message}`);
  process.exitCode = 1;
}
