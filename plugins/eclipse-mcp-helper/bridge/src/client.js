// Small HTTP client for the bridge, used by the MCP server, the deploy script and tests.
'use strict';

const http = require('node:http');
const path = require('node:path');
const { spawn } = require('node:child_process');
const config = require('./config');

function request(port, token, method, route, body) {
	return new Promise((resolve, reject) => {
		const data = body === undefined ? null : Buffer.from(JSON.stringify(body));
		const req = http.request(
			{
				host: '127.0.0.1', port, method, path: route,
				headers: {
					...(data ? { 'Content-Type': 'application/json', 'Content-Length': data.length } : {}),
					...(token ? { Authorization: `Bearer ${token}` } : {}),
				},
			},
			(res) => {
				const chunks = [];
				res.on('data', (c) => chunks.push(c));
				res.on('end', () => {
					try {
						resolve({ status: res.statusCode, body: JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}') });
					} catch (err) {
						reject(err);
					}
				});
			},
		);
		req.on('error', reject);
		req.setTimeout(config.CALL_TIMEOUT_MS + 5000, () => req.destroy(new Error('Bridge timed out')));
		if (data) req.write(data);
		req.end();
	});
}

async function healthy(port) {
	try {
		const r = await request(port, null, 'GET', '/health');
		return r.status === 200 && r.body.name === 'eclipse-mcp-helper';
	} catch {
		return false;
	}
}

// Start the shared bridge in the background if no helper has started it yet.
async function ensureBridge(port = config.PORT) {
	if (await healthy(port)) return;
	const child = spawn(process.execPath, [path.join(__dirname, 'bridge.js')], {
		detached: true,
		stdio: 'ignore',
		env: { ...process.env, ECLIPSE_HELPER_PORT: String(port) },
	});
	child.unref();
	for (let i = 0; i < 50; i++) {
		await new Promise((r) => setTimeout(r, 100));
		if (await healthy(port)) return;
	}
	throw new Error(`Could not start the bridge on port ${port}`);
}

module.exports = { request, healthy, ensureBridge };
