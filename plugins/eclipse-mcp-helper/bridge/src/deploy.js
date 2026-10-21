#!/usr/bin/env node
// Deploy helpers: start N headless Claude Code helpers that all work in the open Eclipse animation at once.
//   node deploy.js --count 3 --task "Block out a 24-frame idle on Workspace.Rig, one body area each"
//   node deploy.js --names "Claude,Arms,Legs" --task "..."
// Each helper gets its own name and color in Studio. Logs go to ~/.eclipse-mcp-helper/logs.
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const config = require('./config');
const { ensureBridge, request } = require('./client');

function arg(name, fallback) {
	const i = process.argv.indexOf(`--${name}`);
	return i >= 0 ? process.argv[i + 1] : fallback;
}

function helperNames() {
	const names = arg('names');
	if (names) return names.split(',').map((s) => s.trim()).filter(Boolean);
	const count = Math.min(Math.max(Number(arg('count', 1)) || 1, 1), 12);
	return Array.from({ length: count }, (_, i) => (i === 0 ? 'Claude' : `Claude ${i + 1}`));
}

function mcpConfig(name) {
	return {
		mcpServers: {
			eclipse: { command: process.execPath, args: [path.join(__dirname, 'mcp.js'), '--name', name] },
		},
	};
}

async function main() {
	const task = arg('task');
	if (!task) {
		console.log('Usage: node deploy.js --count 3 --task "what the helpers should do"');
		process.exit(1);
	}
	await ensureBridge();
	const home = config.ensureHome();
	const logs = path.join(home, 'logs');
	fs.mkdirSync(logs, { recursive: true });
	const names = helperNames();
	const claude = arg('claude', process.env.CLAUDE_BIN || 'claude');

	const team = names.join(', ');
	for (const [i, name] of names.entries()) {
		const file = path.join(home, `helper-${name.replace(/[^A-Za-z0-9]+/g, '-')}.json`);
		fs.writeFileSync(file, JSON.stringify(mcpConfig(name), null, 2));
		const prompt = [
			`You are ${name}, helper ${i + 1} of ${names.length} (${team}) working live in Kash's Eclipse Animator session through the eclipse MCP tools.`,
			`Task: ${task}`,
			names.length > 1 ? 'Split the work with the other helpers: check helper_presence, claim the tracks you take with helper_claim, and leave tracks held by others alone.' : '',
			'Kash may be editing at the same time; if a track is busy, do something else first. Use eclipse_batch for whole poses. Finish with a one-paragraph summary of what you changed.',
		].join('\n');
		const log = fs.openSync(path.join(logs, `${name.replace(/[^A-Za-z0-9]+/g, '-')}-${Date.now()}.log`), 'a');
		const child = spawn(claude, ['-p', prompt, '--mcp-config', file, '--strict-mcp-config', '--allowedTools', 'mcp__eclipse'], {
			detached: true, stdio: ['ignore', log, log],
		});
		child.on('error', (err) => console.error(`${name}: could not start ${claude}: ${err.message}`));
		child.unref();
		console.log(`Started ${name} (pid ${child.pid})`);
	}

	const token = config.readToken();
	await new Promise((r) => setTimeout(r, 3000));
	const p = await request(config.PORT, token, 'GET', '/agent/presence').catch(() => null);
	if (p) console.log(`Helpers online now: ${p.body.agents.map((a) => a.name).join(', ') || 'starting...'}`);
	console.log(`Logs: ${logs}`);
}

main().catch((err) => {
	console.error(err.message);
	process.exit(1);
});
