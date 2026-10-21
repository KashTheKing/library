// Shared settings for the bridge, the MCP server and the deploy script.
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

const PORT = Number(process.env.ECLIPSE_HELPER_PORT || 49210);
const HOME = process.env.ECLIPSE_HELPER_HOME || path.join(os.homedir(), '.eclipse-mcp-helper');

// Helper colors, handed out in join order when a helper doesn't pick one.
const PALETTE = ['#FF8A3D', '#2EC4B6', '#FF5CA8', '#FFC93D', '#9B6BFF', '#4CD964', '#3DB8FF', '#FF5A5A'];

// How long a helper keeps a track after touching it, and how long Kash counts as "editing" after his last edit.
const LEASE_MS = 20_000;
const HUMAN_ACTIVE_MS = 8_000;
const AGENT_TIMEOUT_MS = 20_000;
const PLUGIN_TIMEOUT_MS = 30_000;
const CALL_TIMEOUT_MS = 30_000;
const POLL_HOLD_MS = 15_000;

function ensureHome() {
	fs.mkdirSync(HOME, { recursive: true, mode: 0o700 });
	return HOME;
}

// The agent token lives in a file only local processes can read. Studio never needs it.
function readToken({ create = true } = {}) {
	const file = path.join(ensureHome(), 'token');
	try {
		const token = fs.readFileSync(file, 'utf8').trim();
		if (token.length >= 32) return token;
	} catch {}
	if (!create) return null;
	const token = crypto.randomBytes(32).toString('hex');
	fs.writeFileSync(file, token + '\n', { mode: 0o600 });
	return token;
}

module.exports = {
	PORT, HOME, PALETTE, LEASE_MS, HUMAN_ACTIVE_MS, AGENT_TIMEOUT_MS, PLUGIN_TIMEOUT_MS, CALL_TIMEOUT_MS, POLL_HOLD_MS,
	ensureHome, readToken,
};
