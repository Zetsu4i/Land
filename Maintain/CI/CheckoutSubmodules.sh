#!/usr/bin/env bash

# CheckoutSubmodules.sh - CI-safe, selective submodule checkout
#
# The dependency repositories are public, but older .gitmodules files use SSH
# URLs. GitHub-hosted runners do not have the SSH key that those URLs require.
# Some of the dependency repositories also contain historical submodule entries
# that point at commits which no longer exist. CI uses the Current branch of
# each dependency instead of recursively walking those stale entries.
#
# Usage:
#   bash Maintain/CI/CheckoutSubmodules.sh [all|node|rust]
#
# `node` checks out the JavaScript workspaces and VS Code source. `rust` checks
# out the Rust workspace and the vendored Tauri sources. `all` does both and is
# used by the Windows release job.

set -euo pipefail

MODE="${1:-all}"
case "$MODE" in
    all|node|rust) ;;
    *)
        echo "Unknown submodule checkout mode: $MODE (expected all, node, or rust)" >&2
        exit 2
        ;;
esac

# Keep this rewrite in the runner's global config: submodule child clones do
# not inherit repository-local config. --add is intentional; without it the
# second insteadOf value replaces the first and ssh:// URLs still win.
git config --global url."https://github.com/".insteadOf "ssh://git@github.com/"
git config --global --add url."https://github.com/".insteadOf "git@github.com:"
git config --global --add url."https://github.com/".insteadOf "ssh://github.com/"
export GIT_TERMINAL_PROMPT=0

# Do not use --recursive here. The dependency graph contains stale optional
# submodules (for example an old NPM/Ingress entry). Every path below is
# required by the corresponding build and is checked out from its Current
# branch, which is both reproducible for this repository's dependency policy
# and resilient to those stale gitlink SHAs.
git submodule sync

git submodule update --init --remote --depth 1 --jobs 8 Dependency Element

git -C Element submodule sync
# All Element crates are workspace members or are needed by the frontend build.
git -C Element submodule update --init --remote --depth 1 --jobs 8 \
    Air Cache Cocoon Common Echo Grove Maintain Mist Mountain Output Rest \
    SideCar Sky Vine Wind Worker

if [[ "$MODE" == "all" || "$MODE" == "node" ]]; then
    # JavaScript workspaces and the VS Code platform build.
    git -C Dependency submodule sync
    git -C Dependency submodule update --init --remote --depth 1 --jobs 8 Microsoft SWC Tauri

    git -C Dependency/Microsoft submodule sync
    git -C Dependency/Microsoft submodule update --init --remote --depth 1 --jobs 8 Dependency NPM
    git -C Dependency/Microsoft/Dependency submodule sync
    git -C Dependency/Microsoft/Dependency submodule update --init --remote --depth 1 --jobs 8 Editor

    git -C Dependency/SWC submodule sync
    git -C Dependency/SWC submodule update --init --remote --depth 1 --jobs 8 NPM

    git -C Dependency/Tauri submodule sync
    git -C Dependency/Tauri submodule update --init --remote --depth 1 --jobs 8 NPM
fi

if [[ "$MODE" == "all" || "$MODE" == "rust" ]]; then
    # The root Cargo.toml patches Tauri crates to these local paths.
    git -C Dependency submodule sync
    git -C Dependency submodule update --init --remote --depth 1 --jobs 8 Tauri
    git -C Dependency/Tauri submodule sync
    git -C Dependency/Tauri submodule update --init --remote --depth 1 --jobs 8 Dependency
    git -C Dependency/Tauri/Dependency submodule sync
    git -C Dependency/Tauri/Dependency submodule update --init --remote --depth 1 --jobs 8 \
        Muda PluginsWorkspace Tao TrayIcon Wry Tauri
fi

echo "Submodules ready ($MODE mode)."
