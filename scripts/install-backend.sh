#!/bin/bash

# Install the eufy-sdk runtime the backend needs, from the plugin's lockfile,
# into ~/.local/share/omarchy-eufy-doorbell. It lives outside the plugin folder:
# the shell reloads a plugin whenever a file inside it changes.

set -euo pipefail

plugin_backend="$(cd "$(dirname "$0")/../backend" && pwd)"
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-eufy-doorbell"

command -v npm >/dev/null || { echo "npm not found; install Node.js 24.5 or newer" >&2; exit 1; }

mkdir -p "$data_dir"
chmod 700 "$data_dir"
cp "$plugin_backend/package.json" "$plugin_backend/package-lock.json" "$data_dir/"

# A failed install must not look like a finished one to the backend's check.
trap 'rm -rf "$data_dir/node_modules" "$data_dir/package-lock.json"' ERR

npm ci --prefix "$data_dir" --omit=dev --no-audit --no-fund --loglevel=error
