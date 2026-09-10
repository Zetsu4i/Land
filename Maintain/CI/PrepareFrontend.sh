#!/usr/bin/env bash

# Prepare the generated inputs used by the frontend build. The Element
# submodules are checked out from their moving Current branches, so this keeps
# CI compatible with both the older Wind checkout and newer checkouts that
# already contain these generated configuration files.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WIND="$ROOT/Element/Wind"
REST="$ROOT/Element/Rest"

if [[ ! -d "$WIND" ]]; then
    echo "Wind submodule is not checked out: $WIND" >&2
    exit 1
fi

# @playform/build loads an ESBuild configuration as JavaScript before it can
# compile TypeScript. Wind's self-contained config is intentionally ignored by
# the submodule, so compile it directly before Wind's prepublish script runs.
if [[ -f "$WIND/Source/ESBuild.ts" && ! -f "$WIND/Source/ESBuild.js" ]]; then
    if command -v pnpm >/dev/null 2>&1; then
        ESBUILD=(pnpm exec esbuild)
    else
        ESBUILD=("$ROOT/node_modules/.bin/esbuild")
    fi
    "${ESBUILD[@]}" "$WIND/Source/ESBuild.ts" \
        --bundle \
        --format=esm \
        --platform=node \
        --target=esnext \
        --outfile="$WIND/Source/ESBuild.js"
fi

# Current Wind's prepublish script references these two configs, but an
# incomplete upstream commit omitted their TypeScript sources. Add the small
# configs only when they are absent; a fixed upstream checkout remains the
# source of truth once it supplies them.
CODEGEN_CONFIG="$WIND/Source/Configuration/ESBuild/Codegen.ts"
if [[ ! -f "$CODEGEN_CONFIG" ]]; then
    mkdir -p "$(dirname "$CODEGEN_CONFIG")"
    cat > "$CODEGEN_CONFIG" <<'EOF'
/** ESBuild configuration for Wind's bundled code-generation entry point. */
import type { BuildOptions } from "esbuild";

export default {
	bundle: true,
	format: "esm",
	platform: "node",
	target: "node22",
	outdir: "Configuration/Codegen",
	minify: false,
	sourcemap: "inline",
	write: true,
} satisfies BuildOptions;
EOF
fi

CODEGEN_COMPAT_CONFIG="$WIND/Source/Configuration/ESBuild/Config/CodegenConfig.ts"
if [[ ! -f "$CODEGEN_COMPAT_CONFIG" ]]; then
    mkdir -p "$(dirname "$CODEGEN_COMPAT_CONFIG")"
    cat > "$CODEGEN_COMPAT_CONFIG" <<'EOF'
/** Compatibility export for Wind's target configuration. */
import type { BuildOptions } from "esbuild";

export default {} satisfies BuildOptions;
EOF
fi

# REST_SKIP_BUILD is deliberately passed through Turbo, but older Rest
# submodule revisions check for rustup before evaluating that flag. Relocate
# the existing skip block ahead of the toolchain check so frontend CI does not
# require a native Rest compiler that the release path does not use.
REST_SCRIPT="$REST/prepublishOnly.sh"
if [[ -f "$REST_SCRIPT" ]] && grep -q 'REST_SKIP_BUILD' "$REST_SCRIPT"; then
    awk '
        BEGIN { removing = 0; inserted = 0 }
        /^# Check if build should be skipped$/ {
            removing = 1
            next
        }
        removing && /^fi$/ {
            removing = 0
            next
        }
        /^# Ensure Rust toolchain is configured$/ && !inserted {
            print "# Check if build should be skipped before requiring the native toolchain."
            print "if [ \"${REST_SKIP_BUILD}\" = \"true\" ]; then"
            print "\tlog_info \"Build skipped via REST_SKIP_BUILD environment variable\""
            print "\texit 0"
            print "fi"
            print ""
            inserted = 1
        }
        !removing { print }
    ' "$REST_SCRIPT" > "$REST_SCRIPT.tmp"
    mv "$REST_SCRIPT.tmp" "$REST_SCRIPT"
fi

# The Current Wind checkout no longer contains three small integration modules
# that Sky still imports. Generate compatibility boundaries only when the
# upstream checkout does not provide them; a future Wind revision that restores
# the implementations is left untouched.
if [[ ! -f "$WIND/Source/Effect/Bootstrap.ts" ]]; then
    mkdir -p "$WIND/Source/Effect"
    cat > "$WIND/Source/Effect/Bootstrap.ts" <<'EOF'
/** Compatibility boundary for Sky until Wind restores its Effect bootstrap. */
export interface BootstrapStage {
	readonly success: boolean;
	readonly stageName: string;
	readonly duration: number;
}

export interface BootstrapResult {
	readonly success: boolean;
	readonly totalDuration: number;
	readonly stages: readonly BootstrapStage[];
	readonly error?: unknown;
}

export interface BootstrapOptions {
	readonly skipHealthCheck?: boolean;
	readonly debugMode?: boolean;
}

export async function runBootstrap(
	_Options: BootstrapOptions = {},
): Promise<BootstrapResult> {
	return { success: true, totalDuration: 0, stages: [] };
}
EOF
    echo "Added Wind bootstrap compatibility boundary"
fi

if [[ ! -f "$WIND/Source/Effect/Extensions/ChangeStream.ts" ]]; then
    mkdir -p "$WIND/Source/Effect/Extensions"
    cat > "$WIND/Source/Effect/Extensions/ChangeStream.ts" <<'EOF'
/** Compatibility boundary for Sky's optional extension change subscriber. */
export interface ExtensionChange {
	readonly Kind: "Installed" | "Uninstalled";
	readonly Identifier: string;
}

export type ExtensionChangeCallback = (Change: ExtensionChange) => void;

export interface ExtensionChangeSubscription {
	readonly dispose: () => void;
}

export default async function watchExtensionChanges(
	_Callback: ExtensionChangeCallback,
): Promise<ExtensionChangeSubscription> {
	return { dispose: () => undefined };
}
EOF
    echo "Added Wind extension change compatibility boundary"
fi

if [[ ! -f "$WIND/Source/Effect/LandWorkbench/LandWorkbenchGlobal.ts" ]]; then
    mkdir -p "$WIND/Source/Effect/LandWorkbench"
    cat > "$WIND/Source/Effect/LandWorkbench/LandWorkbenchGlobal.ts" <<'EOF'
/** Idempotent global bridge installed after VS Code exposes its services. */
interface LandWindow extends Window {
	__CEL_SERVICES__?: Record<string, unknown>;
	__CEL_WIND__?: Record<string, unknown>;
}

export function InstallLandWorkbench(): void {
	const Land = globalThis as unknown as LandWindow;
	const Services = Land.__CEL_SERVICES__;
	if (!Services) return;

	Land.__CEL_WIND__ = {
		services: Services,
		invokeFunction: Services["invokeFunction"],
	};

	if (typeof window !== "undefined") {
		window.dispatchEvent(new CustomEvent("cel:wind-ready"));
	}
}
EOF
    echo "Added Wind workbench compatibility boundary"
fi

# Astro 7 removed the experimental flags that the current Sky submodule still
# emits. They are optional build features, and leaving the stale block in place
# makes Astro reject the entire configuration before Vite starts. Remove only
# that top-level config block; the rest of Sky's build settings stay unchanged.
SKY_CONFIG="$ROOT/Element/Sky/astro.config.ts"
if [[ -f "$SKY_CONFIG" ]] && grep -q '^[[:space:]]*experimental: {' "$SKY_CONFIG"; then
    node - "$SKY_CONFIG" <<'NODE'
const fs = require("node:fs");
const file = process.argv[2];
let source = fs.readFileSync(file, "utf8");
const marker = "\n\texperimental: {";
const start = source.indexOf(marker);
if (start !== -1) {
  const open = source.indexOf("{", start);
  let depth = 0;
  let end = -1;
  for (let i = open; i < source.length; i += 1) {
    if (source[i] === "{") depth += 1;
    if (source[i] === "}") {
      depth -= 1;
      if (depth === 0) {
        end = i + 1;
        break;
      }
    }
  }
  if (end !== -1) {
    if (source[end] === ",") end += 1;
    if (source[end] === "\n") end += 1;
    source = source.slice(0, start) + "\n" + source.slice(end);
    fs.writeFileSync(file, source);
    console.log("Removed Sky's stale Astro experimental configuration");
  }
}
NODE
fi

# Vite 8 inlines Rolldown, whose external option accepts only strings and
# regular expressions. Sky's older Rollup callback is equivalent to this
# static rule set for the non-bundled profile.
if [[ -f "$SKY_CONFIG" ]] && grep -q 'external: (id: string) =>' "$SKY_CONFIG"; then
    node - "$SKY_CONFIG" <<'NODE'
const fs = require("node:fs");
const file = process.argv[2];
let source = fs.readFileSync(file, "utf8");
const marker = "\n\t\t\t\texternal: (id: string) => {";
const start = source.indexOf(marker);
if (start !== -1) {
  const open = source.indexOf("{", start);
  let depth = 0;
  let end = -1;
  for (let i = open; i < source.length; i += 1) {
    if (source[i] === "{") depth += 1;
    if (source[i] === "}") {
      depth -= 1;
      if (depth === 0) {
        end = i + 1;
        break;
      }
    }
  }
  if (end !== -1) {
    if (source[end] === ",") end += 1;
    const replacement = `
\t\t\t\texternal: BundledActive
\t\t\t\t\t? ["vscode"]
\t\t\t\t\t: [
\t\t\t\t\t\t"@codeeditorland/output",
\t\t\t\t\t\t/^@codeeditorland\\/output\\//,
\t\t\t\t\t\t"monaco-editor",
\t\t\t\t\t\t/^monaco-editor\\//,
\t\t\t\t\t\t"@microsoft/1ds-post-js",
\t\t\t\t\t\t"@microsoft/1ds-core-js",
\t\t\t\t\t\t"@microsoft/1ds-signalr-js",
\t\t\t\t\t\t/^\\/vs\\//,
\t\t\t\t\t\t/\\/base\\/common\\//,
\t\t\t\t\t\t/\\/base\\/browser\\//,
\t\t\t\t\t\t/\\/base\\/node\\//,
\t\t\t\t\t\t/\\/platform\\//,
\t\t\t\t\t\t/\\/workbench\\//,
\t\t\t\t\t\t/^vs\\//,
\t\t\t\t\t\t"vscode",
\t\t\t\t\t],
`;
    source = source.slice(0, start) + replacement + source.slice(end);
    fs.writeFileSync(file, source);
    console.log("Converted Sky's Rollup external callback for Rolldown");
  }
}
NODE
fi

# Rolldown requires moduleSideEffects callbacks to return booleans; Rollup's
# legacy `no-external` sentinel is rejected by Vite 8.
if [[ -f "$SKY_CONFIG" ]] && grep -q 'return "no-external";' "$SKY_CONFIG"; then
    sed -i 's/return "no-external";/return false;/' "$SKY_CONFIG"
fi

# The top-level-await plugin currently emits an SWC AST shape that Vite 8's
# Rolldown rejects. Modern Chromium/WebView targets used by this release
# support native top-level await, so omit the incompatible polyfill.
if [[ -f "$SKY_CONFIG" ]] && grep -q 'vite-plugin-top-level-await' "$SKY_CONFIG"; then
    node - "$SKY_CONFIG" <<'NODE'
const fs = require("node:fs");
const file = process.argv[2];
let source = fs.readFileSync(file, "utf8");
const pattern = /\.\.\.\(BundledActive\s*\?\s*\[\]\s*:\s*\[\(await import\("vite-plugin-top-level-await"\)\)\.default\(\)\]\),/;
if (pattern.test(source)) {
  source = source.replace(pattern, "...[],");
  fs.writeFileSync(file, source);
  console.log("Removed the incompatible Vite top-level-await polyfill");
}
NODE
fi

echo "Frontend build inputs prepared."
