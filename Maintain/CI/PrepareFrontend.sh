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
    pnpm exec esbuild "$WIND/Source/ESBuild.ts" \
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

echo "Frontend build inputs prepared."
