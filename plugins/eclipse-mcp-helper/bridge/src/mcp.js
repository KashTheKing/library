#!/usr/bin/env node
// One MCP server per helper (stdio). Each one joins the shared bridge with its own name and color, so Kash can run
// as many helpers as he likes. Usage: node mcp.js --name Claude [--color #FF8A3D]
'use strict';

const readline = require('node:readline');
const config = require('./config');
const { request, ensureBridge } = require('./client');
const { TOOLS } = require('./tools');
const { VERSION } = require('./bridge');

const PROTOCOL = '2025-06-18';

function arg(name) {
	const i = process.argv.indexOf(`--${name}`);
	return i >= 0 ? process.argv[i + 1] : undefined;
}

const identity = {
	name: arg('name') || process.env.ECLIPSE_HELPER_NAME || 'Claude',
	color: arg('color') || process.env.ECLIPSE_HELPER_COLOR,
};
const port = Number(arg('port') || config.PORT);
let token = null;
let agent = null;
let joining = null;

async function bridge(method, route, body) {
	if (!token) token = config.readToken();
	return request(port, token, method, route, body);
}

async function ensureAgent() {
	if (agent) return agent;
	if (!joining) {
		joining = (async () => {
			await ensureBridge(port);
			const r = await bridge('POST', '/agent/join', { ...identity, kind: 'agent' });
			if (!r.body.ok) throw new Error(r.body.error || 'Could not join the bridge');
			agent = r.body.agent;
			return agent;
		})().finally(() => (joining = null));
	}
	return joining;
}

// Agent calls go through here so a restarted bridge just means joining again.
async function agentCall(route, body) {
	await ensureAgent();
	let r = await bridge('POST', route, { ...body, agentId: agent.id });
	if (r.status === 404 && /Unknown helper/.test(r.body.error || '')) {
		agent = null;
		await ensureAgent();
		r = await bridge('POST', route, { ...body, agentId: agent.id });
	}
	return r.body;
}

async function runTool(name, args = {}) {
	const tool = TOOLS.find((t) => t.name === name);
	if (!tool) throw new Error(`Unknown tool ${name}`);
	if (tool.route === 'presence') {
		await ensureAgent();
		const r = await bridge('GET', '/agent/presence');
		return { you: agent, ...r.body };
	}
	if (tool.route === 'identity') {
		const r = await agentCall('/agent/identity', { name: args.name, color: args.color });
		if (r.ok) Object.assign(identity, { name: r.agent.name, color: r.agent.color }), (agent = r.agent);
		return r;
	}
	if (tool.route === 'claim') return agentCall('/agent/claim', args);
	if (tool.route === 'release') return agentCall('/agent/release', args);
	const result = await agentCall('/agent/call', tool.call(args));
	if (tool.presence) {
		const p = await bridge('GET', '/agent/presence');
		return { you: agent, ...result, helpers: p.body.agents, studios: p.body.studios, leases: p.body.leases };
	}
	return result;
}

function reply(id, result) {
	process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, result }) + '\n');
}

function fail(id, code, message) {
	process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, error: { code, message } }) + '\n');
}

async function handle(msg) {
	const { id, method, params } = msg;
	if (method === 'initialize') {
		ensureAgent().catch(() => {});
		return reply(id, {
			protocolVersion: params?.protocolVersion || PROTOCOL,
			capabilities: { tools: {} },
			serverInfo: { name: 'eclipse-animator-mcp-helper', version: VERSION },
			instructions: `You are "${identity.name}", a live helper inside Kash's Eclipse Animator session in Roblox Studio. Kash works at the same time: your edits show up in his timeline immediately, under your name in his undo history, and your targets glow in your color. Call eclipse_status first. Respect conflicts: if a track is held by another helper or Kash is editing it, work on something else or coordinate. Prefer eclipse_batch for whole poses so Kash can undo them in one step.`,
		});
	}
	if (method === 'ping') return reply(id, {});
	if (method === 'tools/list') {
		return reply(id, { tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })) });
	}
	if (method === 'tools/call') {
		try {
			const result = await runTool(params.name, params.arguments || {});
			const isError = result && result.ok === false;
			return reply(id, { content: [{ type: 'text', text: JSON.stringify(result, null, 1) }], isError });
		} catch (err) {
			return reply(id, { content: [{ type: 'text', text: `Bridge error: ${err.message}` }], isError: true });
		}
	}
	if (id !== undefined && id !== null) return fail(id, -32601, `Method not found: ${method}`);
}

const heartbeat = setInterval(() => {
	if (agent) agentCall('/agent/heartbeat', {}).catch(() => {});
}, 5000);
heartbeat.unref();

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', (line) => {
	if (!line.trim()) return;
	let msg;
	try {
		msg = JSON.parse(line);
	} catch {
		return fail(null, -32700, 'Parse error');
	}
	handle(msg).catch((err) => msg.id != null && fail(msg.id, -32603, err.message));
});

async function shutdown() {
	clearInterval(heartbeat);
	if (agent) await bridge('POST', '/agent/leave', { agentId: agent.id }).catch(() => {});
	process.exit(0);
}
rl.on('close', shutdown);
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
