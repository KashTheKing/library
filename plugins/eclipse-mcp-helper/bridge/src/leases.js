// Conflict handling: which helper is working on which track, and when Kash is editing something himself.
'use strict';

// Eclipse API actions that change the animation. Everything else is a read or a view change.
const EDIT_ACTIONS = new Set([
	'Add', 'AddObject', 'SetKeyframe', 'SetEasing', 'CreateFolder', 'RenameFolder', 'MoveToFolder', 'MoveToParent', 'Batch',
]);

// Eclipse keybind commands that act on whatever is selected in Eclipse, which Kash shares with every helper.
const SELECTION_COMMANDS = new Set([
	'DeleteKeys', 'CutKeyframes', 'PasteKeyframes', 'Paste', 'PasteFlipped', 'ReverseKeys', 'ReversePaste',
	'SplitKeyframes', 'SplitStride', 'GroupKeyframes', 'UngroupKeyframes', 'UngroupAllKeyframes', 'StretchFrames',
	'FillFrames', 'ClearTransform', 'ResetMotorPosition', 'ResetMotorOrientation', 'ResetScale', 'RecordKeyframe',
	'RecordAllTracks', 'GraphDelete', 'GraphDeleteAlternate', 'GraphDuplicate', 'GraphInsert', 'GraphMirror',
	'GraphSnap', 'GraphInterpolation', 'GraphExtrapolation',
]);

// A target arrives as {"$inst": [names...]} or "Workspace.Rig.Torso". The key is the path, so the same part
// always gets the same key whichever form a helper used.
function targetPath(target) {
	if (target == null || target === false) return null;
	if (typeof target === 'string') return target.split('.').filter(Boolean);
	if (Array.isArray(target)) return target.map(String);
	if (typeof target === 'object' && Array.isArray(target.$inst)) return target.$inst.map(String);
	return null;
}

function keyOf(target, property) {
	const p = targetPath(target);
	if (!p) return null;
	return p.join('/') + (property ? '#' + property : '');
}

// The tracks an Eclipse API request would change.
function keysForInvoke(action, request = {}) {
	if (!EDIT_ACTIONS.has(action)) return [];
	if (action === 'Batch') {
		const keys = [];
		for (const step of request.Actions || []) keys.push(...keysForInvoke(step && step.Action, step && step.Request));
		return [...new Set(keys)];
	}
	const keys = [];
	const targets = request.Targets || (request.Target != null ? [request.Target] : []);
	for (const t of targets) {
		const k = keyOf(t, action === 'SetKeyframe' || action === 'SetEasing' ? request.Property : null);
		if (k) keys.push(k);
	}
	if (action === 'RenameFolder' && request.Folder) keys.push('folder:' + request.Folder);
	return keys;
}

// Two keys overlap when they name the same track, or one names a whole object that holds the other.
function overlaps(a, b) {
	if (a === b) return true;
	const [pa, propA] = a.split('#');
	const [pb, propB] = b.split('#');
	if (propA && propB && propA !== propB && pa === pb) return false;
	return pa === pb || pb.startsWith(pa + '/') || pa.startsWith(pb + '/');
}

class Leases {
	constructor({ leaseMs, humanActiveMs, now = Date.now }) {
		this.leaseMs = leaseMs;
		this.humanActiveMs = humanActiveMs;
		this.now = now;
		this.held = new Map(); // key -> { agentId, expires }
	}

	prune() {
		const t = this.now();
		for (const [k, v] of this.held) if (v.expires <= t) this.held.delete(k);
	}

	// Returns null when the helper may go ahead, or a description of who is in the way.
	check(agentId, keys, human) {
		this.prune();
		for (const key of keys) {
			for (const [held, lease] of this.held) {
				if (lease.agentId !== agentId && overlaps(key, held)) {
					return { kind: 'helper', key, holder: lease.agentId, until: lease.expires };
				}
			}
			if (human && human.editAt && this.now() - human.editAt < this.humanActiveMs) {
				for (const sel of human.selection || []) {
					const sk = keyOf(sel);
					if (sk && (key.split('#')[0] === sk || key.startsWith(sk + '/'))) {
						return { kind: 'human', key, holder: human.name || 'Kash' };
					}
				}
			}
		}
		return null;
	}

	take(agentId, keys, ms = this.leaseMs) {
		const expires = this.now() + ms;
		for (const key of keys) this.held.set(key, { agentId, expires });
	}

	release(agentId, keys) {
		for (const [k, v] of this.held) {
			if (v.agentId === agentId && (!keys || keys.includes(k))) this.held.delete(k);
		}
	}

	list() {
		this.prune();
		return [...this.held].map(([key, v]) => ({ key, agentId: v.agentId, expiresInMs: v.expires - this.now() }));
	}
}

module.exports = { Leases, EDIT_ACTIONS, SELECTION_COMMANDS, keyOf, keysForInvoke, overlaps, targetPath };
