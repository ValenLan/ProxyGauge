#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { copyFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const masterPath = resolve(process.argv[2] ?? join(projectRoot, "Resources/ProxyGauge-source.png"));
const windowsPngPath = join(projectRoot, "Windows/Assets/ProxyGauge.png");
const windowsIcoPath = join(projectRoot, "Windows/Assets/ProxyGauge.ico");
const macIcnsPath = join(projectRoot, "Resources/ProxyGauge.icns");
const workDirectory = mkdtempSync(join(tmpdir(), "proxygauge-icons."));
const preparedMasterPath = join(workDirectory, "ProxyGauge-master.png");

function resize(size, outputPath) {
  execFileSync("/usr/bin/sips", [
    "-z",
    String(size),
    String(size),
    preparedMasterPath,
    "--out",
    outputPath
  ], { stdio: "ignore" });
}

function buildWindowsIcon() {
  const sizes = [16, 24, 32, 48, 64, 128, 256];
  const images = sizes.map((size) => {
    const outputPath = join(workDirectory, `windows-${size}.png`);
    resize(size, outputPath);
    return { size, data: readFileSync(outputPath) };
  });

  const directorySize = 6 + (16 * images.length);
  const header = Buffer.alloc(directorySize);
  header.writeUInt16LE(0, 0);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(images.length, 4);

  let imageOffset = directorySize;
  images.forEach(({ size, data }, index) => {
    const entryOffset = 6 + (16 * index);
    header.writeUInt8(size === 256 ? 0 : size, entryOffset);
    header.writeUInt8(size === 256 ? 0 : size, entryOffset + 1);
    header.writeUInt8(0, entryOffset + 2);
    header.writeUInt8(0, entryOffset + 3);
    header.writeUInt16LE(1, entryOffset + 4);
    header.writeUInt16LE(32, entryOffset + 6);
    header.writeUInt32LE(data.length, entryOffset + 8);
    header.writeUInt32LE(imageOffset, entryOffset + 12);
    imageOffset += data.length;
  });

  writeFileSync(windowsIcoPath, Buffer.concat([header, ...images.map(({ data }) => data)]));
  resize(1024, windowsPngPath);
}

function buildMacIcon() {
  // ICNS stores PNG payloads in typed chunks. Keep both normal and Retina
  // chunk identifiers so Finder and the Dock can choose their native scale.
  const entries = [
    ["icp4", 16],
    ["icp5", 32],
    ["icp6", 64],
    ["ic07", 128],
    ["ic08", 256],
    ["ic09", 512],
    ["ic10", 1024],
    ["ic11", 32],
    ["ic12", 64],
    ["ic13", 256],
    ["ic14", 512]
  ];

  const chunks = entries.map(([type, size], index) => {
    const outputPath = join(workDirectory, `mac-${index}-${size}.png`);
    resize(size, outputPath);
    const data = readFileSync(outputPath);
    const chunk = Buffer.alloc(8 + data.length);
    chunk.write(type, 0, 4, "ascii");
    chunk.writeUInt32BE(chunk.length, 4);
    data.copy(chunk, 8);
    return chunk;
  });

  const totalLength = 8 + chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const header = Buffer.alloc(8);
  header.write("icns", 0, 4, "ascii");
  header.writeUInt32BE(totalLength, 4);
  writeFileSync(macIcnsPath, Buffer.concat([header, ...chunks]));
}

try {
  execFileSync("/usr/bin/xcrun", [
    "swift",
    "-module-cache-path",
    join(workDirectory, "swift-module-cache"),
    join(projectRoot, "Scripts/apply-icon-mask.swift"),
    masterPath,
    preparedMasterPath
  ]);
  buildWindowsIcon();
  buildMacIcon();
  copyFileSync(preparedMasterPath, join(projectRoot, "Resources/ProxyGauge.png"));
  console.log(`Updated ${windowsPngPath}`);
  console.log(`Updated ${windowsIcoPath}`);
  console.log(`Updated ${macIcnsPath}`);
} finally {
  rmSync(workDirectory, { recursive: true, force: true });
}
