'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { spawn } = require('node:child_process');

const home = fs.mkdtempSync(path.join(os.tmpdir(), 'eclipse-helper-'));
process.env.ECLIPSE_HELPER_HOME = home;

const { createBridge } = require('../src/bridge');
const { request } = require('../src/client');
const { keysForInvoke, overlaps, Leases } = require('../src/leases');
const config = require('../src/config');

const token = config.readToken();

// A pretend Studio plugin: polls, runs a handler for each command, posts the result.
function fakeStudio(port, handler, { studio = 'studio-1', human } = {}) {
	let running = true;
	const seen = [];
	const loop = (async () => {
		await request(port, null, 'POST', '/plugin/hello', { studio, place: 'Test Place', user: { id: 1, name: 'Kash' } });
		if (human) await request(port, null, 'POST', '/plugin/state', { studio, human });
		while (running) {
			const r = await request(port, null, 'POST', '/plugin/poll', { studio }).catch(() => null);
			if (!r || r.status !== 200) break;
			for (const cmd of r.body.commands) {
				seen.push(cmd);
				let out;
				try {
					out = { ok: true, result: await handler(cmd) };
				} catch (err) {
					out = { ok: false, error: err.message };
				}
				await request(port, null, 'POST', '/plugin/result', { studio, id: cmd.id, ...out });
			}
		}
	})();
	return { seen, stop: () => ((running = false), loop) };
}

async function setup(t, opts = {}) {
	let clock = 1_000_000;
	const now = opts.realClock ? Date.now : () => clock;
	const bridge = createBridge({ port: 0, token, now, pollHoldMs: 200, callTimeoutMs: 2000, ...opts });
	const port = await bridge.listen();
	t.after(() => bridge.close());
	const api = (method, route, body, tk = token) => request(port, tk, method, route, body);
	const join = async (name, color) => (await api('POST', '/agent/join', { name, color })).body.agent;
	return { bridge, port, api, join, advance: (ms) => (clock += ms) };
}

function raw(port, headers, route = '/agent/presence') {
	return new Promise((resolve, reject) => {
		const req = http.request({ host: '127.0.0.1', port, path: route, method: 'GET', headers }, (res) => {
			res.resume();
			res.on('end', () => resolve(res.statusCode));
		});
		req.on('error', reject);
		req.end();
	});
}

test('keys for edits cover every target, batch steps and property tracks', () => {
	assert.deepEqual(keysForInvoke('ListTracks', { Target: 'Workspace.Rig' }), []);
	assert.deepEqual(keysForInvoke('SetKeyframe', { Target: { $inst: ['Workspace', 'Rig', 'Torso'] }, Frame: 3 }), ['Workspace/Rig/Torso']);
	assert.deepEqual(keysForInvoke('SetKeyframe', { Target: 'Workspace.Lamp', Property: 'Brightness' }), ['Workspace/Lamp#Brightness']);
	assert.deepEqual(
		keysForInvoke('Batch', { Actions: [{ Action: 'SetKeyframe', Request: { Target: 'Workspace.Rig.Head' } }, { Action: 'SetKeyframe', Request: { Target: 'Workspace.Rig.Head' } }] }),
		['Workspace/Rig/Head'],
	);
	assert.ok(overlaps('Workspace/Rig', 'Workspace/Rig/Head'));
	assert.ok(!overlaps('Workspace/Rig/Head', 'Workspace/Rig/Torso'));
	assert.ok(!overlaps('Workspace/Lamp#Color', 'Workspace/Lamp#Brightness'));
	assert.ok(!overlaps('Workspace/Rig2', 'Workspace/Rig'));
});

test('leases expire', () => {
	let t = 0;
	const l = new Leases({ leaseMs: 100, humanActiveMs: 50, now: () => t });
	l.take('a', ['W/Rig/Head']);
	assert.equal(l.check('b', ['W/Rig/Head']).kind, 'helper');
	t = 150;
	assert.equal(l.check('b', ['W/Rig/Head']), null);
});

test('only local, token-carrying, non-browser callers get in', async (t) => {
	const { port, api } = await setup(t);
	assert.equal((await api('GET', '/health', undefined, null)).status, 200);
	assert.equal((await api('GET', '/agent/presence', undefined, null)).status, 401);
	assert.equal((await api('GET', '/agent/presence', undefined, 'x'.repeat(64))).status, 401);
	assert.equal(await raw(port, { Authorization: `Bearer ${token}` }), 200);
	assert.equal(await raw(port, { Authorization: `Bearer ${token}`, Origin: 'https://evil.example' }), 403);
	assert.equal(await raw(port, { Authorization: `Bearer ${token}`, Host: 'evil.example' }), 403);
	assert.equal(await raw(port, { Origin: 'https://evil.example' }, '/plugin/hello'), 403);
	// Windows has no Unix permission bits; the token file sits in the user's own profile there.
	if (process.platform !== 'win32') assert.equal(fs.statSync(path.join(home, 'token')).mode & 0o077, 0);
});

test('helpers get unique names and their own colors', async (t) => {
	const { join } = await setup(t);
	const a = await join('Claude');
	const b = await join('Claude');
	const c = await join('Arms', '#123abc');
	assert.equal(a.name, 'Claude');
	assert.equal(b.name, 'Claude 2');
	assert.notEqual(a.color, b.color);
	assert.equal(c.color, '#123ABC');
});

test('a call reaches Studio with the helper identity and the answer comes back', async (t) => {
	const { port, api, join } = await setup(t);
	const studio = fakeStudio(port, (cmd) => ({ echo: cmd.args, by: cmd.agent.name }));
	t.after(studio.stop);
	const a = await join('Claude');
	const r = await api('POST', '/agent/call', { agentId: a.id, op: 'eclipse.invoke', args: { action: 'ListTracks', request: {} } });
	assert.equal(r.status, 200);
	assert.equal(r.body.result.by, 'Claude');
	assert.equal(studio.seen[0].agent.color, a.color);
});

test('two helpers cannot edit the same track; force and other tracks still work', async (t) => {
	const { port, api, join } = await setup(t);
	const studio = fakeStudio(port, () => ({ done: true }));
	t.after(studio.stop);
	const a = await join('Claude');
	const b = await join('Claude');
	const edit = (agent, target, extra = {}) =>
		api('POST', '/agent/call', { agentId: agent.id, op: 'eclipse.invoke', args: { action: 'SetKeyframe', request: { Target: target, Frame: 1 } }, ...extra });
	assert.equal((await edit(a, 'Workspace.Rig.Head')).status, 200);
	const blocked = await edit(b, 'Workspace.Rig.Head');
	assert.equal(blocked.status, 409);
	assert.match(blocked.body.error, /Claude is working on Workspace\/Rig\/Head/);
	assert.equal((await edit(b, 'Workspace.Rig.LeftArm')).status, 200);
	assert.equal((await edit(b, 'Workspace.Rig.Head', { force: true })).status, 200);
	assert.equal((await edit(a, 'Workspace.Rig.Head')).status, 409, 'b took the lease with force');
});

test('claims hold tracks and release frees them', async (t) => {
	const { port, api, join } = await setup(t);
	const studio = fakeStudio(port, () => ({}));
	t.after(studio.stop);
	const a = await join('Claude');
	const b = await join('Legs');
	assert.equal((await api('POST', '/agent/claim', { agentId: a.id, targets: [{ target: 'Workspace.Rig.LeftLeg' }], seconds: 60 })).status, 200);
	const call = () => api('POST', '/agent/call', { agentId: b.id, op: 'eclipse.invoke', args: { action: 'SetKeyframe', request: { Target: 'Workspace.Rig.LeftLeg', Frame: 0 } } });
	assert.equal((await call()).status, 409);
	await api('POST', '/agent/release', { agentId: a.id });
	assert.equal((await call()).status, 200);
});

test('helpers wait while Kash is editing what he has selected', async (t) => {
	const { port, api, join, advance } = await setup(t);
	const studio = fakeStudio(port, () => ({}), { human: { name: 'Kash', selection: [{ $inst: ['Workspace', 'Rig', 'Head'] }], editAgoMs: 0 } });
	t.after(studio.stop);
	await new Promise((r) => setTimeout(r, 100));
	const a = await join('Claude');
	const edit = (target) => api('POST', '/agent/call', { agentId: a.id, op: 'eclipse.invoke', args: { action: 'SetKeyframe', request: { Target: target, Frame: 0 } } });
	const r = await edit('Workspace.Rig.Head');
	assert.equal(r.status, 409);
	assert.match(r.body.error, /Kash is editing/);
	assert.equal((await edit('Workspace.Rig.Torso')).status, 200);
	const del = await api('POST', '/agent/call', { agentId: a.id, op: 'eclipse.command', args: { command: 'DeleteKeys' } });
	assert.equal(del.status, 409);
	advance(10_000);
	assert.equal((await edit('Workspace.Rig.Head')).status, 200);
});

test('shared batches are refused; pause stops edits but not reads; Kash can stop one helper', async (t) => {
	const { port, api, join } = await setup(t);
	const studio = fakeStudio(port, () => ({}));
	t.after(studio.stop);
	const a = await join('Claude');
	const call = (op, args) => api('POST', '/agent/call', { agentId: a.id, op, args });
	assert.match((await call('eclipse.invoke', { action: 'BeginBatch', request: {} })).body.error, /Batch action/);
	await api('POST', '/plugin/control', { studio: 'studio-1', paused: true }, null);
	assert.match((await call('eclipse.invoke', { action: 'SetKeyframe', request: { Target: 'Workspace.R', Frame: 0 } })).body.error, /paused/);
	assert.equal((await call('studio.rigs', {})).status, 200);
	await api('POST', '/plugin/control', { studio: 'studio-1', paused: false, stop: a.id }, null);
	assert.match((await call('studio.rigs', {})).body.error, /stopped this helper/);
	await api('POST', '/plugin/control', { studio: 'studio-1', resume: a.id }, null);
	assert.equal((await call('studio.rigs', {})).status, 200);
});

test('webhook runs a call in one request', async (t) => {
	const { port, api } = await setup(t);
	const studio = fakeStudio(port, (cmd) => ({ op: cmd.op, who: cmd.agent.name }));
	t.after(studio.stop);
	const r = await api('POST', '/hook', { name: 'Panel', op: 'studio.selection', args: {} });
	assert.equal(r.status, 200);
	assert.deepEqual(r.body.result, { op: 'studio.selection', who: 'Panel' });
	assert.equal((await api('POST', '/hook', { name: 'Panel', op: 'studio.rigs' })).body.helper, 'Panel');
});

test('webhook keeps one identity per name and a failed edit frees its tracks', async (t) => {
	const { port, api, join } = await setup(t);
	const studio = fakeStudio(port, (cmd) => {
		if (cmd.args.request && cmd.args.request.Frame === 99) throw new Error('Choose one track');
		return { who: cmd.agent.name };
	});
	t.after(studio.stop);
	await join('Claude'); // an MCP helper already holds the name
	const edit = (frame) => api('POST', '/hook', { name: 'Claude', op: 'eclipse.invoke', args: { action: 'SetKeyframe', request: { Target: 'Workspace.Rig.Head', Frame: frame } } });
	const first = await edit(99);
	assert.equal(first.status, 400);
	const second = await edit(1);
	assert.equal(second.status, 200, 'the failed call left no lease behind');
	assert.equal(second.body.helper, first.body.helper);
	const names = (await api('GET', '/agent/presence')).body.agents.map((a) => a.name);
	assert.deepEqual(names.sort(), ['Claude', 'Claude 2']);
});

test('no Studio means a clear error, and a silent Studio times out', async (t) => {
	const { port, api, join } = await setup(t, { callTimeoutMs: 300 });
	const a = await join('Claude');
	assert.match((await api('POST', '/agent/call', { agentId: a.id, op: 'studio.rigs' })).body.error, /No Studio/);
	await request(port, null, 'POST', '/plugin/hello', { studio: 'mute' });
	assert.match((await api('POST', '/agent/call', { agentId: a.id, op: 'studio.rigs' })).body.error, /did not answer/);
});

test('MCP server: initialize, list tools, call through the bridge', async (t) => {
	const { port } = await setup(t, { realClock: true });
	const studio = fakeStudio(port, (cmd) => (cmd.op === 'eclipse.status' ? { eclipse: { found: true } } : { cmd: cmd.op }));
	t.after(studio.stop);
	const child = spawn(process.execPath, [path.join(__dirname, '../src/mcp.js'), '--name', 'Tester', '--port', String(port)], {
		env: { ...process.env, ECLIPSE_HELPER_HOME: home },
	});
	t.after(() => child.kill());
	const replies = new Map();
	let buf = '';
	child.stdout.on('data', (d) => {
		buf += d;
		let i;
		while ((i = buf.indexOf('\n')) >= 0) {
			const msg = JSON.parse(buf.slice(0, i));
			buf = buf.slice(i + 1);
			replies.get(msg.id)?.(msg);
		}
	});
	let next = 1;
	const rpc = (method, params) =>
		new Promise((resolve) => {
			const id = next++;
			replies.set(id, resolve);
			child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
		});
	const init = await rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 't', version: '1' } });
	assert.equal(init.result.serverInfo.name, 'eclipse-animator-mcp-helper');
	assert.match(init.result.instructions, /Tester/);
	const list = await rpc('tools/list', {});
	const names = list.result.tools.map((x) => x.name);
	for (const n of ['eclipse_status', 'eclipse_call', 'eclipse_set_keyframe', 'eclipse_batch', 'helper_claim']) assert.ok(names.includes(n), n);
	const status = await rpc('tools/call', { name: 'eclipse_status', arguments: {} });
	const body = JSON.parse(status.result.content[0].text);
	assert.equal(body.you.name, 'Tester');
	assert.equal(body.result.eclipse.found, true);
	assert.ok(body.helpers.some((h) => h.name === 'Tester'));
	const kf = await rpc('tools/call', { name: 'eclipse_set_keyframe', arguments: { target: 'Workspace.Rig.Head', frame: 4, offset: { $cf: { p: [0, 0, 0], r: [0, 0, 30] } } } });
	assert.equal(kf.result.isError, false);
	const sent = studio.seen.find((c) => c.args.action === 'SetKeyframe');
	assert.deepEqual(sent.args.request, { Target: 'Workspace.Rig.Head', Frame: 4, Offset: { $cf: { p: [0, 0, 0], r: [0, 0, 30] } } });
});
