#!/usr/bin/env bash
# Sets up the Eclipse Animator MCP Helper on this computer (macOS or Linux; on Windows use the steps in README.md):
#   1. builds the Studio plugin with Rojo and copies it into Studio's Plugins folder,
#   2. registers the "eclipse" MCP server with Claude Code, so every Claude Code session is a helper named Claude.
# Run from anywhere: bash plugins/eclipse-mcp-helper/install.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
name="${ECLIPSE_HELPER_NAME:-Claude}"

command -v node >/dev/null || { echo "Node 18+ is needed (brew install node)."; exit 1; }

rojo_bin="$(command -v rojo || true)"
if [ -z "$rojo_bin" ]; then
	echo "Rojo isn't installed. Install it (brew install rojo, or rokit add rojo-rbx/rojo) and run this again."
	exit 1
fi

mkdir -p "$here/build"
"$rojo_bin" build "$here/default.project.json" -o "$here/build/EclipseMCPHelper.rbxm"

case "$(uname)" in
	Darwin) plugins="$HOME/Documents/Roblox/Plugins" ;;
	*) plugins="${ROBLOX_PLUGINS_DIR:-$HOME/.local/share/Roblox/Plugins}" ;;
esac
mkdir -p "$plugins"
cp "$here/build/EclipseMCPHelper.rbxm" "$plugins/EclipseMCPHelper.rbxm"
echo "Plugin installed: $plugins/EclipseMCPHelper.rbxm"

if command -v claude >/dev/null; then
	claude mcp remove --scope user eclipse >/dev/null 2>&1 || true
	claude mcp add --scope user eclipse -- node "$here/bridge/src/mcp.js" --name "$name"
	echo "Claude Code now has the eclipse tools (helper name: $name)."
else
	echo "Claude Code isn't on PATH; add the MCP server yourself: node $here/bridge/src/mcp.js --name $name"
fi

echo "Done. Restart Studio, open Eclipse Animator and an animation, then open the MCP Helper panel from the Plugins tab."
