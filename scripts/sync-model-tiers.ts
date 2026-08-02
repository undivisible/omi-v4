#!/usr/bin/env bun
/**
 * Regenerates Rust tier defaults from config/model-tiers.json.
 * Run after editing the JSON; CI should fail if generated files drift.
 */
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dir, "..");
const config = JSON.parse(
  readFileSync(join(root, "config/model-tiers.json"), "utf8"),
) as {
  tiers: Record<string, string>;
  capabilities: Record<string, string[]>;
};

const tierConst = (tier: string) =>
  `DEFAULT_${tier.toUpperCase()}_MODEL`;

const hubDefaults = Object.entries(config.tiers)
  .map(([tier, model]) => {
    const name = tierConst(tier);
    return `pub(crate) const ${name}: &str = "${model}";`;
  })
  .join("\n");

const hubCapabilities = Object.entries(config.capabilities)
  .map(([model, caps]) => {
    const rustCaps = caps
      .map((cap) => {
        switch (cap) {
          case "text":
            return "Capability::Text";
          case "audioIn":
            return "Capability::AudioIn";
          case "audioOut":
            return "Capability::AudioOut";
          case "imageIn":
            return "Capability::ImageIn";
          case "realtime":
            return "Capability::Realtime";
          default:
            throw new Error(`unknown capability: ${cap}`);
        }
      })
      .join(", ");
    return `    ("${model}", &[${rustCaps}]),`;
  })
  .join("\n");

const hubFile = `//! @generated from config/model-tiers.json — do not edit; run scripts/sync-model-tiers.ts

use super::Capability;

${hubDefaults}

pub(crate) const MODEL_CAPABILITIES: &[(&str, &[Capability])] = &[
${hubCapabilities}
];
`;

const workerRsDefaults = Object.entries(config.tiers)
  .map(([tier, model]) => {
    const name = tierConst(tier);
    return `pub const ${name}: &str = "${model}";`;
  })
  .join("\n");

const workerRsCapabilities = Object.entries(config.capabilities)
  .map(([model, caps]) => {
    const rustCaps = caps
      .map((cap) => {
        switch (cap) {
          case "text":
            return "Text";
          case "audioIn":
            return "AudioIn";
          case "audioOut":
            return "AudioOut";
          case "imageIn":
            return "ImageIn";
          case "realtime":
            return "ModelCapability::Realtime";
          default:
            throw new Error(`unknown capability: ${cap}`);
        }
      })
      .join(", ");
    return `    ("${model}", &[${rustCaps}]),`;
  })
  .join("\n");

const workerRsFile = `//! @generated from config/model-tiers.json — do not edit; run scripts/sync-model-tiers.ts

use super::ModelCapability::{AudioIn, AudioOut, ImageIn, Text};
use super::ModelCapability;

${workerRsDefaults}

pub const MODEL_CAPABILITIES: &[(&str, &[ModelCapability])] = &[
${workerRsCapabilities}
];
`;

const hubPath = join(root, "app/native/hub/src/model_tier_defaults.rs");
const workerRsPath = join(root, "worker-rs/src/model_tier_defaults.rs");
writeFileSync(hubPath, hubFile);
writeFileSync(workerRsPath, workerRsFile);

// A long capability list wraps differently than the one-line-per-model shape
// emitted above, so the generated files are handed to rustfmt here. Without
// this, `cargo fmt --check` fails on a file nobody is allowed to hand-edit.
for (const [path, edition] of [
  [hubPath, "2024"],
  [workerRsPath, "2021"],
] as const) {
  const formatted = spawnSync("rustfmt", ["--edition", edition, path], {
    stdio: "inherit",
  });
  if (formatted.status !== 0) {
    throw new Error(`rustfmt failed on ${path}`);
  }
}
console.log("synced model tier defaults to hub and worker-rs");
