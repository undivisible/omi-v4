#!/usr/bin/env bun
/**
 * Regenerates Rust tier defaults from config/model-tiers.json.
 * Run after editing the JSON; CI should fail if generated files drift.
 */
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
    return caps.length > 1
      ? `    (\n        "${model}",\n        &[${rustCaps}],\n    ),`
      : `    ("${model}", &[${rustCaps}]),`;
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

use super::ModelCapability;
use super::ModelCapability::{AudioIn, AudioOut, ImageIn, Text};

${workerRsDefaults}

pub const MODEL_CAPABILITIES: &[(&str, &[ModelCapability])] = &[
${workerRsCapabilities}
];
`;

writeFileSync(join(root, "app/native/hub/src/model_tier_defaults.rs"), hubFile);
writeFileSync(join(root, "worker-rs/src/model_tier_defaults.rs"), workerRsFile);
console.log("synced model tier defaults to hub and worker-rs");
