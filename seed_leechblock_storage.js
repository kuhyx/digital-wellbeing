#!/usr/bin/env node
/**
 * seed_leechblock_storage.js
 *
 * Writes LeechBlock NG default settings directly into Chrome's extension
 * LevelDB storage.  This bypasses Chrome's content-verification and service
 * worker caching entirely.
 *
 * Usage:
 *   node seed_leechblock_storage.js <path/to/defaults.js> [--force]
 *
 * Must be run while Chrome is NOT open.
 *
 * Requires: classic-level  (npm install classic-level)
 */

import { ClassicLevel } from "classic-level";
import { readFileSync, existsSync } from "fs";
import path from "path";
import os from "os";

// ── CLI args ─────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const force = args.includes("--force");
const defaultsPath = args.find((a) => !a.startsWith("--"));

if (!defaultsPath) {
  console.error("Usage: node seed_leechblock_storage.js <defaults.js> [--force]");
  process.exit(1);
}
if (!existsSync(defaultsPath)) {
  console.error(`defaults.js not found: ${defaultsPath}`);
  process.exit(1);
}

// ── Load defaults from .json or .js file ────────────────────────────
const src = readFileSync(defaultsPath, "utf8");
let DEFAULTS;
try {
  if (defaultsPath.endsWith(".json")) {
    DEFAULTS = JSON.parse(src);
  } else {
    // Legacy .js format: const LEECHBLOCK_DEFAULTS = { ... }
    // eslint-disable-next-line no-new-func
    DEFAULTS = new Function(src + "\nreturn LEECHBLOCK_DEFAULTS;")();
  }
} catch (e) {
  console.error("Failed to load defaults file:", e.message);
  process.exit(1);
}
console.log(`Loaded ${Object.keys(DEFAULTS).length} keys from ${defaultsPath}`);

// ── Known CWS extension ID for LeechBlock NG ─────────────────────────
const EXT_ID = "blaaajhemilngeeffpbfkdjjoefldkok";

// ── Find all Chrome/Chromium profile dirs with this extension ────────
const configDirs = [
  path.join(os.homedir(), ".config/google-chrome"),
  path.join(os.homedir(), ".config/chromium"),
  path.join(os.homedir(), ".config/BraveSoftware/Brave-Browser"),
  path.join(os.homedir(), ".config/vivaldi"),
  path.join(os.homedir(), ".config/thorium"),
];

async function seedProfile(storageDir) {
  const db = new ClassicLevel(storageDir, { createIfMissing: true });
  try {
    // Check for existing sites unless --force
    if (!force) {
      let hasAnySites = false;
      const numSets = +(DEFAULTS.numSets ?? 6);
      for (let s = 1; s <= numSets; s++) {
        try {
          const val = await db.get(`sites${s}`);
          if (val && JSON.parse(val)) {
            hasAnySites = true;
            break;
          }
        } catch (_) {
          /* key doesn't exist */
        }
      }
      if (hasAnySites) {
        console.log(`  Skipping ${storageDir} — sites already configured (use --force to override).`);
        return;
      }
    }

    const entries = Object.entries(DEFAULTS);
    for (const [key, value] of entries) {
      await db.put(key, JSON.stringify(value));
    }
    console.log(`  ✓ Seeded ${entries.length} settings into ${storageDir}`);
  } finally {
    await db.close();
  }
}

let found = false;
const { readdirSync } = await import("fs");
for (const configDir of configDirs) {
  if (!existsSync(configDir)) continue;
  // Walk profiles: Default, Profile 1, Profile 2, ...
  for (const profile of readdirSync(configDir)) {
    const storageDir = path.join(
      configDir, profile, "Local Extension Settings", EXT_ID
    );
    const extDir = path.join(configDir, profile, "Extensions", EXT_ID);
    // Only seed profiles where LeechBlock is actually installed
    if (existsSync(extDir) || existsSync(storageDir)) {
      console.log(`Seeding ${configDir}/${profile}...`);
      try {
        await seedProfile(storageDir);
        found = true;
      } catch (e) {
        console.warn(`  ⚠ Failed to seed ${storageDir}: ${e.message}`);
      }
    }
  }
}

if (!found) {
  console.log("No LeechBlock NG installations found.");
  process.exit(0);
}
