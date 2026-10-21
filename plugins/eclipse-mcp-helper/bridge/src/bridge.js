#!/usr/bin/env node
// The bridge: one local process that every helper (MCP server, webhook caller) and every Studio window talks to.
// Studio plugins can't host servers, so the plugin long-polls /plugin/poll for commands and posts results back.
'use strict';

const http = require('node:http');
const crypto = require('node:crypto');
const config = require('./config');
const { Leases, SELECTION_COMMANDS, keysForInvoke, keyOf } = require('./leases');

const VERSION = '1.0.0';
const MAX_BODY = 1024 * 1024;
const BLOCKED_ACTIONS = new Set(['BeginBatch', 'EndBatch']);
// Reads still work while Kash has paused helpers.
const READ_OPS = new Set(['eclipse.status', 'studio.selection', 'studio.rigs', 'studio.pose', 'studio.animation']);

function createBridge(options = {}) {
	const port = options.port ?? config.PORT;
	const token = options.token ?? config.readToken();
	const now = options.now ?? Date.now;
	const t = {
		lease: options.leaseMs ?? config.LEASE_MS,
		human: options.humanActiveMs ?? config.HUMAN_ACTIVE_MS,
		agent: options.agentTimeoutMs ?? config.AGENT_TIMEOUT_MS,
		plugin: options.pluginTimeoutMs ?? config.PLUGIN_TIMEOUT_MS,
		call: options.callTimeoutMs ?? config.CALL_TIMEOUT_MS,
		hold: options.pollHoldMs ?? config.POLL_HOLD_MS,
	};

	const agents = new Map();
	const studios = new Map();
	const pending = new Map();
	const activity = [];
	const listeners = new Set();
	const leases = new Leases({ leaseMs: t.lease, humanActiveMs: t.human, now });
	let colorIndex = 0;

	// ---------- state helpers ----------

	function publicAgent(a) {
		return { id: a.id, name: a.name, color: a.color, kind: a.kind, status: a.status, stopped: a.stopped, lastSeenMsAgo: now() - a.lastSeen };
	}

	function publicStudio(s) {
		return {
			id: s.id, place: s.place, user: s.user, paused: s.paused, eclipse: s.eclipse,
			human: s.human && {
				name: s.human.name, selection: s.human.selection, frame: s.human.frame, fps: s.human.fps,
				editingNow: !!(s.human.editAt && now() - s.human.editAt < t.human),
				lastEditMsAgo: s.human.editAt ? now() - s.human.editAt : null,
			},
			lastSeenMsAgo: now() - s.lastSeen,
		};
	}

	function snapshot() {
		return {
			agents: [...agents.values()].map(publicAgent),
			studios: [...studios.values()].map(publicStudio),
			leases: leases.list().map((l) => ({ ...l, agent: agents.get(l.agentId)?.name })),
			activity: activity.slice(-30),
		};
	}

	function emit(type, data) {
		const event = { type, at: new Date(now()).toISOString(), ...data };
		if (type !== 'state') {
			activity.push(event);
			if (activity.length > 200) activity.shift();
		}
		const line = `event: ${type}\ndata: ${JSON.stringify(event)}\n\n`;
		for (const res of listeners) res.write(line);
		if (type !== 'state') wakeAll();
	}

	// Presence changed: answer every waiting poll so each Studio redraws its helper list now.
	function wakeAll() {
		for (const s of studios.values()) flush(s, true);
	}

	function presenceFor() {
		return {
			agents: [...agents.values()].map(publicAgent),
			leases: leases.list().map((l) => ({ ...l, agent: agents.get(l.agentId)?.name, color: agents.get(l.agentId)?.color })),
			activity: activity.slice(-20),
		};
	}

	function flush(studio, force) {
		if (!studio.waiter) return;
		if (!force && studio.queue.length === 0) return;
		const { res, timer } = studio.waiter;
		studio.waiter = null;
		clearTimeout(timer);
		const commands = studio.queue.splice(0, 20);
		send(res, 200, { commands, presence: presenceFor() });
	}

	function pickStudio(id) {
		if (id) return studios.get(id) || null;
		let best = null;
		for (const s of studios.values()) if (!best || s.lastSeen > best.lastSeen) best = s;
		return best;
	}

	function uniqueName(name, exceptId) {
		const base = String(name || 'Claude').slice(0, 40).trim() || 'Claude';
		const taken = new Set([...agents.values()].filter((a) => a.id !== exceptId).map((a) => a.name));
		if (!taken.has(base)) return base;
		for (let i = 2; ; i++) if (!taken.has(`${base} ${i}`)) return `${base} ${i}`;
	}

	function validColor(c) {
		return typeof c === 'string' && /^#[0-9a-fA-F]{6}$/.test(c) ? c.toUpperCase() : null;
	}

	function join({ name, color, kind }) {
		const id = crypto.randomUUID();
		const agent = {
			id, name: uniqueName(name), color: validColor(color) || config.PALETTE[colorIndex++ % config.PALETTE.length],
			kind: kind === 'webhook' ? 'webhook' : 'agent', status: 'idle', stopped: false, lastSeen: now(), joinedAt: now(),
		};
		agents.set(id, agent);
		emit('joined', { agent: publicAgent(agent) });
		return agent;
	}

	function leave(agent, reason) {
		if (!agents.has(agent.id)) return;
		agents.delete(agent.id);
		leases.release(agent.id);
		emit('left', { agent: publicAgent(agent), reason });
	}

	function conflictMessage(c) {
		if (c.kind === 'human') return `${c.holder} is editing ${c.key} right now. Wait a few seconds, pick another track, or pass force.`;
		const holder = agents.get(c.holder);
		return `${holder ? holder.name : 'Another helper'} is working on ${c.key} (for ${Math.ceil((c.until - now()) / 1000)}s more). Pick another track, coordinate, or pass force.`;
	}

	// ---------- the core: one helper asks one Studio to do one thing ----------

	function call(agent, { op, args = {}, studio: studioId, force = false }) {
		return new Promise((resolve) => {
			if (agent.stopped) return resolve({ ok: false, error: 'Kash stopped this helper in Studio. Ask him to resume it.' });
			if (typeof op !== 'string' || !/^(eclipse|studio|helper)\.[a-zA-Z]+$/.test(op)) {
				return resolve({ ok: false, error: 'Unknown op' });
			}
			const studio = pickStudio(studioId);
			if (!studio) return resolve({ ok: false, error: 'No Studio is connected. Open Roblox Studio with the Eclipse Animator MCP Helper plugin.' });
			if (studio.paused && !READ_OPS.has(op)) {
				return resolve({ ok: false, error: 'Kash paused all helpers in Studio.' });
			}

			let keys = [];
			if (op === 'eclipse.invoke') {
				if (BLOCKED_ACTIONS.has(args.action)) {
					return resolve({ ok: false, error: 'BeginBatch/EndBatch are shared by everyone in Eclipse; use the Batch action (atomic, one undo step) instead.' });
				}
				keys = keysForInvoke(args.action, args.request || {});
			} else if (op === 'eclipse.command' && SELECTION_COMMANDS.has(args.command) && !force) {
				const h = studio.human;
				if (h && h.editAt && now() - h.editAt < t.human) {
					return resolve({ ok: false, conflict: 'human', error: `${h.name || 'Kash'} is editing right now and ${args.command} acts on Eclipse's shared selection. Wait a few seconds or pass force.` });
				}
			}

			if (keys.length && !force) {
				const c = leases.check(agent.id, keys, studio.human);
				if (c) return resolve({ ok: false, conflict: c.kind, error: conflictMessage(c) });
			}
			if (keys.length) leases.take(agent.id, keys);

			const id = crypto.randomUUID();
			const command = { id, op, args, force: !!force, agent: { id: agent.id, name: agent.name, color: agent.color } };
			const timer = setTimeout(() => {
				pending.delete(id);
				const i = studio.queue.indexOf(command);
				if (i >= 0) studio.queue.splice(i, 1);
				resolve({ ok: false, error: 'Studio did not answer in time. Is Studio busy or the plugin paused?' });
			}, t.call);
			pending.set(id, {
				agent, op, keys, studio: studio.id, timer,
				done(result) {
					clearTimeout(timer);
					pending.delete(id);
					resolve(result);
				},
			});
			agent.status = describe(op, args);
			studio.queue.push(command);
			flush(studio);
		});
	}

	function describe(op, args) {
		if (op === 'eclipse.invoke') return args.action || 'eclipse';
		if (op === 'eclipse.command') return args.command || 'command';
		return op.split('.')[1];
	}

	// ---------- HTTP ----------

	function send(res, status, body) {
		if (res.writableEnded) return;
		const text = JSON.stringify(body);
		res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
		res.end(text);
	}

	function readBody(req) {
		return new Promise((resolve, reject) => {
			let size = 0;
			const chunks = [];
			req.on('data', (c) => {
				size += c.length;
				if (size > MAX_BODY) {
					reject(Object.assign(new Error('Body too large'), { status: 413 }));
					req.destroy();
				} else chunks.push(c);
			});
			req.on('end', () => {
				if (!chunks.length) return resolve({});
				try {
					const v = JSON.parse(Buffer.concat(chunks).toString('utf8'));
					resolve(v && typeof v === 'object' ? v : {});
				} catch {
					reject(Object.assign(new Error('Body must be JSON'), { status: 400 }));
				}
			});
			req.on('error', reject);
		});
	}

	function authed(req) {
		const h = req.headers.authorization || '';
		const given = Buffer.from(h.startsWith('Bearer ') ? h.slice(7) : '');
		const want = Buffer.from(token);
		return given.length === want.length && crypto.timingSafeEqual(given, want);
	}

	// Only this machine, and never a web page: browsers always send Origin, and a DNS-rebinding page has the wrong Host.
	function trusted(req) {
		const host = req.headers.host || '';
		const p = server.address() ? server.address().port : port;
		if (host !== `127.0.0.1:${p}` && host !== `localhost:${p}`) return false;
		if (req.headers.origin !== undefined) return false;
		if (req.headers['sec-fetch-site'] !== undefined) return false;
		return true;
	}

	function agentFrom(body, res) {
		const agent = agents.get(body.agentId);
		if (!agent) {
			send(res, 404, { ok: false, error: 'Unknown helper; join again' });
			return null;
		}
		agent.lastSeen = now();
		return agent;
	}

	function studioFrom(body, res) {
		const s = studios.get(body.studio);
		if (!s) {
			send(res, 404, { ok: false, error: 'Unknown studio; say hello first' });
			return null;
		}
		s.lastSeen = now();
		return s;
	}

	const routes = {
		'GET /health': (req, res) => send(res, 200, { ok: true, name: 'eclipse-mcp-helper', version: VERSION }),

		// --- Studio plugin ---
		'POST /plugin/hello': async (req, res, body) => {
			const id = typeof body.studio === 'string' && body.studio.length <= 64 ? body.studio : crypto.randomUUID();
			const existing = studios.get(id);
			const s = existing || { id, queue: [], waiter: null, paused: false, human: null, eclipse: null };
			Object.assign(s, { place: String(body.place || 'Place').slice(0, 100), user: body.user || null, pluginVersion: body.pluginVersion, lastSeen: now() });
			studios.set(id, s);
			if (!existing) emit('studio', { studio: publicStudio(s), connected: true });
			send(res, 200, { ok: true, studio: id, version: VERSION, presence: presenceFor() });
		},
		'POST /plugin/poll': async (req, res, body) => {
			const s = studioFrom(body, res);
			if (!s) return;
			if (s.waiter) flush(s, true);
			s.waiter = { res, timer: setTimeout(() => flush(s, true), t.hold) };
			res.on('close', () => {
				if (s.waiter && s.waiter.res === res) {
					clearTimeout(s.waiter.timer);
					s.waiter = null;
				}
			});
			flush(s);
		},
		'POST /plugin/result': async (req, res, body) => {
			const s = studioFrom(body, res);
			if (!s) return;
			const p = pending.get(body.id);
			if (p && p.studio === s.id) {
				const result = body.ok ? { ok: true, result: body.result } : { ok: false, error: String(body.error || 'Failed') };
				if (body.history) result.history = body.history;
				p.agent.status = 'idle';
				emit('call', { agent: p.agent.name, color: p.agent.color, op: p.op, ok: !!body.ok, summary: body.summary || null, error: body.ok ? undefined : result.error });
				p.done(result);
			}
			send(res, 200, { ok: true });
		},
		'POST /plugin/state': async (req, res, body) => {
			const s = studioFrom(body, res);
			if (!s) return;
			if (body.eclipse) s.eclipse = body.eclipse;
			if (body.human) {
				const h = body.human;
				const prev = s.human || {};
				s.human = {
					name: String(h.name || prev.name || 'Kash').slice(0, 40),
					selection: Array.isArray(h.selection) ? h.selection.slice(0, 50) : prev.selection || [],
					frame: h.frame ?? prev.frame, fps: h.fps ?? prev.fps,
					editAt: typeof h.editAgoMs === 'number' ? now() - h.editAgoMs : prev.editAt,
				};
			}
			emit('state', { studio: s.id });
			send(res, 200, { ok: true });
		},
		'POST /plugin/control': async (req, res, body) => {
			const s = studioFrom(body, res);
			if (!s) return;
			if (typeof body.paused === 'boolean') {
				s.paused = body.paused;
				emit('paused', { paused: s.paused });
			}
			for (const [field, stopped] of [['stop', true], ['resume', false]]) {
				const a = body[field] && agents.get(body[field]);
				if (a) {
					a.stopped = stopped;
					if (stopped) leases.release(a.id);
					emit(stopped ? 'stopped' : 'resumed', { agent: publicAgent(a) });
				}
			}
			send(res, 200, { ok: true, presence: presenceFor() });
		},

		// --- helpers (MCP servers, scripts) ---
		'POST /agent/join': async (req, res, body) => {
			const a = join(body);
			send(res, 200, { ok: true, agent: publicAgent(a) });
		},
		'POST /agent/leave': async (req, res, body) => {
			const a = agentFrom(body, res);
			if (!a) return;
			leave(a, 'left');
			send(res, 200, { ok: true });
		},
		'POST /agent/heartbeat': async (req, res, body) => {
			const a = agentFrom(body, res);
			if (!a) return;
			send(res, 200, { ok: true, agent: publicAgent(a) });
		},
		'POST /agent/identity': async (req, res, body) => {
			const a = agentFrom(body, res);
			if (!a) return;
			if (body.name) a.name = uniqueName(body.name, a.id);
			if (validColor(body.color)) a.color = validColor(body.color);
			emit('identity', { agent: publicAgent(a) });
			send(res, 200, { ok: true, agent: publicAgent(a) });
		},
		'POST /agent/call': async (req, res, body) => {
			const a = agentFrom(body, res);
			if (!a) return;
			const result = await call(a, body);
			send(res, result.ok ? 200 : result.conflict ? 409 : 400, result);
		},
		'POST /agent/claim': async (req, res, body) => {
			const a = agentFrom(body, res);
			if (!a) return;
			const keys = (body.targets || []).map((x) => keyOf(x.target ?? x, x.property)).filter(Boolean);
			if (!keys.length) return send(res, 400, { ok: false, error: 'targets is empty' });
			const seconds = Math.min(Math.max(Number(body.seconds) || 60, 5), 600);
			const studio = pickStudio(body.studio);
			const c = !body.force && leases.check(a.id, keys, studio && studio.human);
			if (c) return send(res, 409, { ok: false, conflict: c.kind, error: conflictMessage(c) });
			leases.take(a.id, keys, seconds * 1000);
			emit('claim', { agent: a.name, color: a.color, keys, seconds });
			send(res, 200, { ok: true, keys, seconds });
		},
		'POST /agent/release': async (req, res, body) => {
			const a = agentFrom(body, res);
			if (!a) return;
			const keys = body.targets ? body.targets.map((x) => keyOf(x.target ?? x, x.property)).filter(Boolean) : undefined;
			leases.release(a.id, keys);
			emit('release', { agent: a.name, keys: keys || 'all' });
			send(res, 200, { ok: true });
		},
		'GET /agent/presence': async (req, res) => send(res, 200, { ok: true, ...snapshot() }),

		// --- webhook: one request, no MCP needed ---
		'POST /hook': async (req, res, body) => {
			const name = uniqueNameFor(body.name);
			let a = [...agents.values()].find((x) => x.kind === 'webhook' && x.name === name);
			if (!a) a = join({ name, color: body.color, kind: 'webhook' });
			a.lastSeen = now();
			const result = await call(a, body);
			send(res, result.ok ? 200 : result.conflict ? 409 : 400, { ...result, helper: a.name });
		},
		'GET /events': (req, res) => {
			res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store', Connection: 'keep-alive' });
			res.write(`event: hello\ndata: ${JSON.stringify(snapshot())}\n\n`);
			listeners.add(res);
			req.on('close', () => listeners.delete(res));
		},
	};

	function uniqueNameFor(name) {
		return String(name || 'Webhook').slice(0, 40).trim() || 'Webhook';
	}

	const server = http.createServer(async (req, res) => {
		try {
			if (!trusted(req)) return send(res, 403, { ok: false, error: 'Local tools only' });
			const url = new URL(req.url, 'http://127.0.0.1');
			const route = routes[`${req.method} ${url.pathname}`];
			if (!route) return send(res, 404, { ok: false, error: 'Not found' });
			const isPublic = url.pathname === '/health' || url.pathname.startsWith('/plugin/');
			if (!isPublic && !authed(req)) return send(res, 401, { ok: false, error: 'Missing or wrong token' });
			if (req.method === 'POST' && !String(req.headers['content-type'] || '').startsWith('application/json')) {
				return send(res, 415, { ok: false, error: 'Send JSON' });
			}
			const body = req.method === 'POST' ? await readBody(req) : {};
			await route(req, res, body);
		} catch (err) {
			send(res, err.status || 500, { ok: false, error: err.status ? err.message : 'Bridge error' });
			if (!err.status) console.error(err);
		}
	});

	const sweeper = setInterval(() => {
		const tNow = now();
		for (const a of agents.values()) if (tNow - a.lastSeen > t.agent) leave(a, 'timed out');
		for (const s of studios.values()) {
			if (tNow - s.lastSeen > t.plugin && !s.waiter) {
				studios.delete(s.id);
				for (const p of pending.values()) if (p.studio === s.id) p.done({ ok: false, error: 'Studio disconnected' });
				emit('studio', { studio: { id: s.id, place: s.place }, connected: false });
			}
		}
		for (const res of listeners) res.write(': ping\n\n');
	}, 2000);
	sweeper.unref();

	return {
		server,
		agents, studios, leases,
		listen() {
			return new Promise((resolve, reject) => {
				server.once('error', reject);
				server.listen(port, '127.0.0.1', () => resolve(server.address().port));
			});
		},
		close() {
			clearInterval(sweeper);
			for (const res of listeners) res.end();
			for (const s of studios.values()) if (s.waiter) flush(s, true);
			for (const p of pending.values()) p.done({ ok: false, error: 'Bridge closed' });
			return new Promise((resolve) => server.close(() => resolve()));
		},
	};
}

module.exports = { createBridge, VERSION };

if (require.main === module) {
	const bridge = createBridge();
	bridge.listen().then(
		(p) => console.log(`Eclipse Animator MCP Helper bridge on http://127.0.0.1:${p}`),
		(err) => {
			if (err.code === 'EADDRINUSE') {
				console.log('A bridge is already running.');
				process.exit(0);
			}
			throw err;
		},
	);
}
