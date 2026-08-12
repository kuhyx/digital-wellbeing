#!/usr/bin/env node
/**
 * seed_ublock_storage.js
 *
 * Writes a uBlock Origin `selectedFilterLists` entry directly into Chrome's
 * extension LevelDB storage, enabling every filter list uBO ships (not just
 * the defaults that are on out of the box). Same mechanism as
 * seed_leechblock_storage.js: chrome.storage.local is a LevelDB store under
 * "Local Extension Settings/<extension-id>/", writable while the browser is
 * closed.
 *
 * uBO downloads/compiles the content of any newly-enabled 3rd-party list on
 * its own update cycle after the extension's first real launch (~105s), so
 * newly-selected lists need one browser launch with network access before
 * they're actually enforced — this only sets which lists are selected.
 *
 * Usage:
 *   node seed_ublock_storage.js [--force] [--ext-path=/path/to/unpacked/ublock]
 *
 * --ext-path overrides the unpacked install path to match against (defaults
 * to Arch's /usr/lib/ublock-origin). Pass this on non-Arch installers whose
 * package path differs, e.g. Debian/Ubuntu's
 * /usr/share/chromium/extensions/ublock-origin.
 *
 * Must be run while the browser is NOT open.
 *
 * Requires: classic-level (npm install classic-level)
 */

import { ClassicLevel } from "classic-level";
import { existsSync, readdirSync, readFileSync } from "fs";
import path from "path";
import os from "os";
import https from "https";

// ── CLI args ─────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const force = args.includes("--force");
const extPathArg = args.find((a) => a.startsWith("--ext-path="));
const customExtPath = extPathArg ? extPathArg.slice("--ext-path=".length) : null;

// ── Known CWS extension ID for uBlock Origin (MV2) ────────────────────
const CWS_EXT_ID = "cjpalhdlnbpafiamejdnhcphjbkeiagm";

// uBO's package install path(s), used with --load-extension deployments.
// Chromium derives a synthetic, install-specific extension ID from the
// unpacked path rather than using the CWS ID — read it back out of the
// profile's own Preferences file instead of guessing it. Includes both
// known distro package paths so this script works unmodified whether it
// was seeded via --ext-path (e.g. from the Ubuntu installer) or run bare
// (Arch's ublock-origin package).
const UNPACKED_EXT_PATHS = customExtPath
  ? [customExtPath]
  : ["/usr/lib/ublock-origin", "/usr/share/chromium/extensions/ublock-origin"];

// Find the extension ID Chromium assigned to an unpacked extension loaded via
// --load-extension, by matching extensions.settings[*].path against known
// install paths. Returns null if the profile has no Preferences file yet
// (i.e. the browser has never been launched with this profile).
function findUnpackedExtensionId(configDir, profile) {
  const prefsPath = path.join(configDir, profile, "Preferences");
  if (!existsSync(prefsPath)) return null;
  let prefs;
  try {
    prefs = JSON.parse(readFileSync(prefsPath, "utf8"));
  } catch (_) {
    return null;
  }
  const settings = prefs?.extensions?.settings ?? {};
  for (const [id, entry] of Object.entries(settings)) {
    if (UNPACKED_EXT_PATHS.includes(entry?.path)) return id;
  }
  return null;
}

// ── Fetch uBO's own filter-list catalog and select every filter list ──
function fetchAssetsJson() {
  return new Promise((resolve, reject) => {
    https
      .get(
        "https://raw.githubusercontent.com/gorhill/uBlock/master/assets/assets.json",
        (res) => {
          if (res.statusCode !== 200) {
            reject(new Error(`HTTP ${res.statusCode} fetching assets.json`));
            return;
          }
          let body = "";
          res.on("data", (chunk) => (body += chunk));
          res.on("end", () => {
            try {
              resolve(JSON.parse(body));
            } catch (e) {
              reject(e);
            }
          });
        },
      )
      .on("error", reject);
  });
}

function selectAllFilterListKeys(assets) {
  // Every entry with content === "filters" is a filter list (as opposed to
  // uBO's own resource/scriptlet/redirect assets, which use other content
  // types). "off: true" only means "not selected by default" — it is still
  // a valid, selectable list, which is exactly what we want to force on.
  return Object.entries(assets)
    .filter(([, v]) => v.content === "filters")
    .map(([key]) => key);
}

// ── Find all Chrome/Chromium profile dirs with this extension ────────
const configDirs = [
  path.join(os.homedir(), ".config/google-chrome"),
  path.join(os.homedir(), ".config/chromium"),
  path.join(os.homedir(), ".config/BraveSoftware/Brave-Browser"),
  path.join(os.homedir(), ".config/vivaldi"),
  path.join(os.homedir(), ".config/thorium"),
  path.join(os.homedir(), ".config/ungoogled-chromium"),
];

async function seedProfile(storageDir, selectedFilterLists) {
  const db = new ClassicLevel(storageDir, { createIfMissing: true });
  try {
    if (!force) {
      try {
        const existing = await db.get("selectedFilterLists");
        if (existing && JSON.parse(existing).length > 0) {
          console.log(`  Skipping ${storageDir} — filter lists already configured (use --force to override).`);
          return;
        }
      } catch (_) {
        /* key doesn't exist — fine, proceed to seed */
      }
    }

    await db.put("selectedFilterLists", JSON.stringify(selectedFilterLists));
    console.log(`  ✓ Selected ${selectedFilterLists.length} filter lists in ${storageDir}`);
  } finally {
    await db.close();
  }
}

console.log("Fetching uBlock Origin's filter-list catalog...");
const assets = await fetchAssetsJson();
const selectedFilterLists = selectAllFilterListKeys(assets);
console.log(`Found ${selectedFilterLists.length} selectable filter lists (enabling all of them).`);

let found = false;
for (const configDir of configDirs) {
  if (!existsSync(configDir)) continue;
  for (const profile of readdirSync(configDir)) {
    // --load-extension deployments (this repo's normal case): Chromium
    // assigns a synthetic ID derived from the unpacked path, discoverable
    // only via the profile's own Preferences file.
    const unpackedId = findUnpackedExtensionId(configDir, profile);
    // Real CWS installs (e.g. Brave's Chrome Web Store install): fixed ID.
    const cwsExtDir = path.join(configDir, profile, "Extensions", CWS_EXT_ID);
    const cwsStorageDir = path.join(configDir, profile, "Local Extension Settings", CWS_EXT_ID);
    const cwsInstalled = existsSync(cwsExtDir) || existsSync(cwsStorageDir);

    const extId = unpackedId ?? (cwsInstalled ? CWS_EXT_ID : null);
    if (!extId) continue;

    const storageDir = path.join(configDir, profile, "Local Extension Settings", extId);
    console.log(`Seeding ${configDir}/${profile} (extension id ${extId})...`);
    try {
      await seedProfile(storageDir, selectedFilterLists);
      found = true;
    } catch (e) {
      console.warn(`  ⚠ Failed to seed ${storageDir}: ${e.message}`);
    }
  }
}

if (!found) {
  console.log("No uBlock Origin installations found.");
  process.exit(0);
}
