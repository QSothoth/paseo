#!/usr/bin/env bash
set -euo pipefail

# Build and pack Paseo server-side packages cleanly on a small Linux VPS
# without installing Electron, Expo, Playwright, or desktop/web bundles.
#
# Usage:
#   bash scripts/vps-build-server.sh [--out /opt/paseo-custom-dist] [--test] [--install /opt/paseo-app-next]

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="/opt/paseo-custom-dist"
RUN_TESTS=0
INSTALL_DIR=""
KEEP_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_DIR="$2"; shift 2 ;;
    --test) RUN_TESTS=1; shift ;;
    --install) INSTALL_DIR="$2"; shift 2 ;;
    --keep-build) KEEP_BUILD=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

BUILD_DIR="$(mktemp -d /tmp/paseo-server-build.XXXXXX)"
cleanup() {
  if [[ "$KEEP_BUILD" -eq 0 ]]; then
    rm -rf "$BUILD_DIR"
  else
    echo "Kept build dir: $BUILD_DIR"
  fi
}
trap cleanup EXIT

echo "[1/5] Preparing trimmed server-only workspace in $BUILD_DIR ..."
for item in package.json tsconfig.base.json tsconfig.json vitest.config.ts scripts skills plugins plugin-examples patches packages; do
  if [[ -e "$REPO_DIR/$item" ]]; then
    if [[ "$item" == "packages" ]]; then
      mkdir -p "$BUILD_DIR/packages"
      for pkg in protocol client highlight plugin relay server cli; do
        cp -a "$REPO_DIR/packages/$pkg" "$BUILD_DIR/packages/$pkg"
      done
    else
      cp -a "$REPO_DIR/$item" "$BUILD_DIR/$item"
    fi
  fi
done

# Strip non-server workspaces and desktop/browser heavy devDependencies,
# while pinning key compiler/schema/runtime versions from package-lock.json.
python3 - "$REPO_DIR/package-lock.json" "$BUILD_DIR" << 'PY'
import json, pathlib, sys
lock = json.loads(pathlib.Path(sys.argv[1]).read_text())
lock_pkgs = lock.get("packages") or {}
root = pathlib.Path(sys.argv[2])
pkg_path = root / "package.json"
pkg = json.loads(pkg_path.read_text())
pkg["workspaces"] = [
    "plugins",
    "packages/protocol",
    "packages/client",
    "packages/highlight",
    "packages/plugin",
    "packages/relay",
    "packages/server",
    "packages/cli",
]
drop_root_dev = {
    "electron", "electron-builder", "expo-module-scripts",
    "playwright", "react-dom", "lefthook", "knip", "oxfmt", "oxlint", "oxlint-tsgolint",
}
pkg["devDependencies"] = {k: v for k, v in (pkg.get("devDependencies") or {}).items() if k not in drop_root_dev}
pkg.get("scripts", {}).pop("prepare", None)

# Pin ALL direct dependencies from package-lock.json so trimmed npm install matches upstream CI exactly
def lock_ver(pkg_name, ws_prefix=""):
    if ws_prefix:
        e = lock_pkgs.get(f"{ws_prefix}/node_modules/{pkg_name}")
        if e and e.get("version"):
            return e["version"]
    e = lock_pkgs.get(f"node_modules/{pkg_name}")
    if e and e.get("version"):
        return e["version"]
    return None

def apply_pins(doc, ws_prefix=""):
    for sec in ("dependencies", "devDependencies"):
        m = doc.get(sec)
        if not isinstance(m, dict):
            continue
        for k, cur in list(m.items()):
            if k.startswith("@getpaseo/") or not isinstance(cur, str):
                continue
            v = lock_ver(k, ws_prefix)
            if v:
                m[k] = v

apply_pins(pkg)
pkg_path.write_text(json.dumps(pkg, indent=2) + "\n")

for ws in pkg["workspaces"]:
    wp = root / ws / "package.json"
    if not wp.exists():
        continue
    wd = json.loads(wp.read_text())
    apply_pins(wd, ws)
    if ws == "packages/server":
        for k in ("@playwright/test", "@vitest/ui"):
            (wd.get("devDependencies") or {}).pop(k, None)
    wp.write_text(json.dumps(wd, indent=2) + "\n")
PY

echo "[2/5] Installing server workspace dependencies (skipping onnxruntime/playwright/electron) ..."
cd "$BUILD_DIR"
ONNXRUNTIME_NODE_INSTALL=skip \
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
ELECTRON_SKIP_BINARY_DOWNLOAD=1 \
npm install --no-audit --no-fund --legacy-peer-deps

echo "[3/5] Building server packages ..."
npm run build --workspace=@getpaseo/protocol
npm run build --workspace=@getpaseo/client
npm run build --workspace=@getpaseo/highlight
npm run build --workspace=@getpaseo/plugin
npm run build --workspace=@getpaseo/relay
npm run build --workspace=@getpaseo/server
npm run build --workspace=@getpaseo/cli

# Copy existing bundled web-ui assets from installed /opt/paseo-app if present (avoids building Expo app)
if [[ -d /opt/paseo-app/node_modules/@getpaseo/server/dist/server/web-ui ]]; then
  echo "Copying existing bundled web-ui static assets into server dist ..."
  cp -a /opt/paseo-app/node_modules/@getpaseo/server/dist/server/web-ui "$BUILD_DIR/packages/server/dist/server/web-ui"
fi

if [[ "$RUN_TESTS" -eq 1 ]]; then
  echo "[4/5] Running targeted unit tests for custom fork patches ..."
  export NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=1280"
  npx --prefix "$BUILD_DIR/plugins" vitest run antigravity-provider/server/provider.test.ts --maxWorkers=1 --testTimeout=20000
  npx --prefix "$BUILD_DIR/packages/plugin" vitest run src/server/acp.test.ts --maxWorkers=1 --testTimeout=20000
  npx --prefix "$BUILD_DIR/packages/client" vitest run src/daemon-client.test.ts -t "liveness heartbeat|starts pinging|stops pinging" --maxWorkers=1 --testTimeout=20000
  (
    cd "$BUILD_DIR/packages/server"
    npx vitest run --maxWorkers=1 --testTimeout=20000 \
      src/server/agent/plugin-provider.test.ts \
      src/server/agent/idle-runtime-cleanup/idle-runtime-cleanup.test.ts \
      src/server/config.test.ts \
      src/server/daemon-config-store.test.ts \
      src/server/persisted-config.test.ts \
      src/server/plugins/runtime.posix.test.ts \
      src/server/agent/providers/claude/agent.redesign.test.ts
    npx vitest run --maxWorkers=1 --testTimeout=20000 \
      src/server/agent/providers/codex-app-server-agent.test.ts \
      -t "Codex runtime safety"
  )
else
  echo "[4/5] Skipping tests (pass --test to run)."
fi

echo "[5/5] Packing tarballs into $OUT_DIR ..."
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
# Pack without re-running prepack (which tries to build Expo web-ui)
for pkg in protocol client highlight plugin relay server cli; do
  python3 - "$BUILD_DIR/packages/$pkg/package.json" << 'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
d = json.loads(p.read_text())
(d.get("scripts") or {}).pop("prepack", None)
p.write_text(json.dumps(d, indent=2) + "\n")
PY
  npm pack --workspace="@getpaseo/$pkg" --pack-destination "$OUT_DIR"
done

ls -lh "$OUT_DIR"

if [[ -n "$INSTALL_DIR" ]]; then
  echo "[install] Installing packed custom build into $INSTALL_DIR ..."
  rm -rf "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  python3 - "$OUT_DIR" "$INSTALL_DIR/package.json" << 'PY'
import glob, json, os, sys
out_dir, dest = sys.argv[1], sys.argv[2]
tg = {os.path.basename(p).split("-0.")[0]: f"file:{p}" for p in sorted(glob.glob(os.path.join(out_dir, "*.tgz")))}
mapping = {
    "@getpaseo/protocol": tg["getpaseo-protocol"],
    "@getpaseo/client": tg["getpaseo-client"],
    "@getpaseo/highlight": tg["getpaseo-highlight"],
    "@getpaseo/plugin": tg["getpaseo-plugin"],
    "@getpaseo/relay": tg["getpaseo-relay"],
    "@getpaseo/server": tg["getpaseo-server"],
    "@getpaseo/cli": tg["getpaseo-cli"],
}
doc = {
    "name": "paseo-vps-runtime",
    "private": True,
    "dependencies": {"@getpaseo/cli": mapping["@getpaseo/cli"]},
    "overrides": mapping,
}
open(dest, "w").write(json.dumps(doc, indent=2) + "\n")
PY
  cd "$INSTALL_DIR"
  ONNXRUNTIME_NODE_INSTALL=skip npm install --omit=dev --no-audit --no-fund
  "$INSTALL_DIR/node_modules/.bin/paseo" --version
  echo "[install] Ready at $INSTALL_DIR"
fi
