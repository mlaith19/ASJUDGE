#!/usr/bin/env node
/**
 * Copy the current Flutter release build into apks/, under a name that says what
 * it is.
 *
 * `flutter build apk` always writes to the same path and overwrites what was
 * there. Nothing else keeps a copy, so the build running on the tablets right
 * now exists only on the tablets — there is no file of it anywhere. This makes
 * keeping one a single command.
 *
 *   node scripts/archive-apk.mjs
 *   node scripts/archive-apk.mjs --label RC
 *
 * A build whose bytes are already archived is not copied twice.
 */
import { readFileSync, existsSync, mkdirSync, copyFileSync, readdirSync, statSync } from "node:fs"
import { createHash } from "node:crypto"
import { fileURLToPath } from "node:url"
import path from "node:path"

// fileURLToPath, not the URL's pathname: this project lives under "SCORING ARABINA
// SHOW", and a pathname keeps every space as %20, so the path never resolves.
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const APK = path.join(ROOT, "tablet_app", "build", "app", "outputs", "apk", "release", "app-release.apk")
const OUT = path.join(ROOT, "apks")

const args = process.argv.slice(2)
const label = (args[args.indexOf("--label") + 1] && args.includes("--label")) ? args[args.indexOf("--label") + 1] : "A.S-JUDGE"

if (!existsSync(APK)) {
  console.error(`no build found at:\n  ${APK}\nrun  flutter build apk --release  first.`)
  process.exit(1)
}

const read = (p) => { try { return readFileSync(p, "utf-8") } catch { return "" } }

// Identity comes from the sources the build was made from, not from the file name.
const version = (read(path.join(ROOT, "tablet_app", "pubspec.yaml")).match(/^version:\s*(.+)$/m)?.[1] ?? "0.0.0").trim()
const appId = (read(path.join(ROOT, "tablet_app", "android", "app", "build.gradle"))
  .match(/applicationId\s+"([^"]+)"/)?.[1] ?? "unknown").trim()

const sha = createHash("sha256").update(readFileSync(APK)).digest("hex")

if (!existsSync(OUT)) mkdirSync(OUT, { recursive: true })

const already = readdirSync(OUT).filter((f) => f.endsWith(".apk")).find((f) => {
  try { return createHash("sha256").update(readFileSync(path.join(OUT, f))).digest("hex") === sha } catch { return false }
})
if (already) {
  console.log(`this exact build is already archived as:\n  ${already}`)
  process.exit(0)
}

const d = new Date(statSync(APK).mtime)
const p2 = (n) => String(n).padStart(2, "0")
const stamp = `${d.getFullYear()}${p2(d.getMonth() + 1)}${p2(d.getDate())}-${p2(d.getHours())}${p2(d.getMinutes())}`
const name = `${label}_${version.replace(/[^\w.+-]/g, "")}_${appId}_${stamp}.apk`

copyFileSync(APK, path.join(OUT, name))
const mb = (statSync(APK).size / 1048576).toFixed(1)
console.log(`archived ${mb} MB\n  apks/${name}`)
