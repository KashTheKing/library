// The MCP tools each helper gets. Each tool becomes one bridge call ({op, args}) that the Studio plugin runs.
'use strict';

const VALUES = [
	'Roblox values in JSON:',
	'instance {"$inst":["Workspace","Rig","Torso"]} or "Workspace.Rig.Torso" (results also carry "id"; pass it back as {"$id":"..."} for an exact match);',
	'CFrame {"$cf":[x,y,z,R00,R01,R02,R10,R11,R12,R20,R21,R22]} or {"$cf":{"p":[x,y,z],"r":[rx,ry,rz]}} (r = Orientation degrees, YXZ);',
	'Vector3 {"$v3":[x,y,z]}, Vector2 {"$v2":[x,y]}, Color3 {"$c3":[r,g,b]} (0-1), UDim2 {"$udim2":[sx,ox,sy,oy]}, enum {"$enum":"EasingStyle.Quad"}.',
].join(' ');

const target = { description: 'The rig, part or object. ' + VALUES, oneOf: [{ type: 'string' }, { type: 'object' }] };
const easing = {
	type: 'object',
	description: 'Easing: {"Style":"Linear|Constant|Cubic|Quad|Quart|Quint|Sine|Back|Bounce|Elastic|Exponential|Circular|Bezier", "Direction":"In|Out|InOut|OutIn"}',
	properties: { Style: { type: 'string' }, Direction: { type: 'string' } },
	required: ['Style'],
};
const force = { type: 'boolean', description: 'Skip the conflict check (another helper or Kash is on this track). Only when you are sure.' };
const studio = { type: 'string', description: 'Which Studio window (id from eclipse_status). Defaults to the most recently active one.' };

function invoke(action, map = (a) => a) {
	return (a) => ({ op: 'eclipse.invoke', args: { action, request: map(a) }, force: a.force, studio: a.studio });
}

// Turn friendly snake_case arguments into the Eclipse API's request fields.
function editRequest(a) {
	const r = { Target: a.target, Frame: a.frame };
	if (a.property !== undefined) r.Property = a.property;
	if (a.value !== undefined) r.Value = a.value;
	if (a.value_space !== undefined) r.ValueSpace = a.value_space;
	if (a.easing !== undefined) r.Easing = a.easing;
	if (a.offset !== undefined) r.Offset = a.offset;
	return r;
}

const TOOLS = [
	{
		name: 'eclipse_status',
		description: 'Start here. Shows the connected Studio windows, whether Eclipse Animator is open with an animation, its API version and actions, the current frame/FPS, undo state, the other helpers online, the tracks they hold, and what Kash is doing (selection, frame, editing now).',
		inputSchema: { type: 'object', properties: { studio } },
		call: (a) => ({ op: 'eclipse.status', args: {}, studio: a.studio }),
		presence: true,
	},
	{
		name: 'eclipse_call',
		description: 'Run any Eclipse Animator extension API action directly (full control). Actions: GetInfo, Add, AddObject, ListTracks, ListProperties, Select, SetKeyframe, SetEasing, GetCurrentFrame, GetCurrentTime, GetFPS, Batch, HistoryRecord, RevertChanges, CreateFolder, RenameFolder, GetFolder, ListFolders, MoveToFolder, MoveToParent, GetTimelineParent, ListTimelineChildren, GetHistoryState, SetExpanded, ForwardInput (Undo/Redo: use eclipse_history). Request fields use the API names (Target, Property, Frame, Value, ValueSpace, Easing, Record, Changes, Name, Folder, Parent, Targets, Index, Expanded, Recursive, Key, Modifiers, Actions). ' + VALUES,
		inputSchema: {
			type: 'object',
			properties: { action: { type: 'string' }, request: { type: 'object' }, force, studio },
			required: ['action'],
		},
		call: (a) => ({ op: 'eclipse.invoke', args: { action: a.action, request: a.request || {} }, force: a.force, studio: a.studio }),
	},
	{
		name: 'eclipse_list_tracks',
		description: 'List timeline tracks (joints and property tracks), optionally only for one target or property. Each row has Target, Property, Name and Rig.',
		inputSchema: { type: 'object', properties: { target, property: { type: 'string' }, studio } },
		call: invoke('ListTracks', (a) => ({ Target: a.target, Property: a.property })),
	},
	{
		name: 'eclipse_list_properties',
		description: 'List the property tracks an object supports (Transparency, Color, light Brightness, camera FieldOfView...) and which are enabled.',
		inputSchema: { type: 'object', properties: { target, studio }, required: ['target'] },
		call: invoke('ListProperties', (a) => ({ Target: a.target })),
	},
	{
		name: 'eclipse_add_object',
		description: 'Add a rig, part or object from Workspace to the open animation timeline, optionally enabling property tracks.',
		inputSchema: { type: 'object', properties: { target, properties: { type: 'array', items: { type: 'string' } }, force, studio }, required: ['target'] },
		call: invoke('AddObject', (a) => ({ Target: a.target, Properties: a.properties })),
	},
	{
		name: 'eclipse_set_keyframe',
		description: 'Set a keyframe on one track at an integer frame. For joints, value is the joint\'s local CFrame (Motor6D C0 space); leave it out to key the current pose, or pass offset (a CFrame) to key current C0 * offset, e.g. {"$cf":{"p":[0,0,0],"r":[0,0,30]}} to bend 30 degrees. For property tracks pass property and a value of that type. value_space "BoneTransform" keys native Bones by Transform. Shows up live in Eclipse and in Kash\'s undo history under your name.',
		inputSchema: {
			type: 'object',
			properties: {
				target, frame: { type: 'integer', minimum: 0 }, property: { type: 'string' }, value: { description: VALUES },
				offset: { description: 'CFrame applied on top of the joint\'s current C0. ' + VALUES },
				value_space: { type: 'string', enum: ['LocalPose', 'BoneTransform'] }, easing, force, studio,
			},
			required: ['target', 'frame'],
		},
		call: invoke('SetKeyframe', editRequest),
	},
	{
		name: 'eclipse_set_easing',
		description: 'Change the easing of an existing keyframe.',
		inputSchema: { type: 'object', properties: { target, frame: { type: 'integer' }, property: { type: 'string' }, easing, force, studio }, required: ['target', 'frame', 'easing'] },
		call: invoke('SetEasing', editRequest),
	},
	{
		name: 'eclipse_batch',
		description: 'Run many edits as one atomic step (all or nothing, one undo step for Kash). actions: [{"action":"SetKeyframe","request":{"Target":...,"Frame":12,"Value":...}}, ...]. Allowed actions: Add, AddObject, SetKeyframe, SetEasing, CreateFolder, RenameFolder, MoveToFolder, MoveToParent. Use this to block out whole poses.',
		inputSchema: {
			type: 'object',
			properties: {
				name: { type: 'string', description: 'Undo history label (your name is added in front).' },
				actions: { type: 'array', items: { type: 'object', properties: { action: { type: 'string' }, request: { type: 'object' } }, required: ['action'] } },
				force, studio,
			},
			required: ['actions'],
		},
		call: (a) => ({
			op: 'eclipse.invoke',
			args: { action: 'Batch', request: { Name: a.name, Actions: (a.actions || []).map((s) => ({ Action: s.action ?? s.Action, Request: s.request ?? s.Request ?? {} })) } },
			force: a.force, studio: a.studio,
		}),
	},
	{
		name: 'eclipse_command',
		description: 'Press an Eclipse command (its default keybind is sent through the API). Playback: TogglePlayback, JumpToStart, StepFrameLeft/Right, StepSingleFrameLeft/Right, JumpKeyframeLeft/Right. Editing (acts on Eclipse\'s shared selection, so call eclipse_call Select first): CopyKeyframes, Copy, Paste, PasteFlipped, CutKeyframes, DeleteKeys, ReverseKeys, SplitKeyframes, GroupKeyframes, RecordKeyframe, RecordAllTracks, SelectAll. View: FocusSelection, FitTimeline, ToggleGraphEditor, ToggleOnionSkin, CaptureOnionSkin. Project: SaveProject, ExportAnimation (opens Eclipse\'s export dialog). Pass key + modifiers instead if Kash rebound a key.',
		inputSchema: {
			type: 'object',
			properties: {
				command: { type: 'string' }, repeat: { type: 'integer', minimum: 1, maximum: 120 },
				key: { type: 'string', description: 'KeyCode name, e.g. "Space"' }, modifiers: { type: 'array', items: { type: 'string', enum: ['Ctrl', 'Shift', 'Alt', 'Meta'] } },
				force, studio,
			},
		},
		call: (a) => ({ op: 'eclipse.command', args: { command: a.command, repeat: a.repeat, key: a.key, modifiers: a.modifiers }, force: a.force, studio: a.studio }),
	},
	{
		name: 'eclipse_history',
		description: 'Undo or redo your own last edit, or read the history state. Undo only runs when the newest step is yours, so you never undo Kash\'s or another helper\'s work (force overrides).',
		inputSchema: { type: 'object', properties: { op: { type: 'string', enum: ['state', 'undo', 'redo'] }, force, studio }, required: ['op'] },
		call: (a) => ({ op: 'eclipse.history', args: { op: a.op }, force: a.force, studio: a.studio }),
	},
	{
		name: 'studio_find_rigs',
		description: 'Find animatable rigs in Workspace (Humanoid, AnimationController or Motor6D models), with joint counts, saved animations and whether each is on the Eclipse timeline.',
		inputSchema: { type: 'object', properties: { studio } },
		call: (a) => ({ op: 'studio.rigs', args: {}, studio: a.studio }),
	},
	{
		name: 'studio_read_pose',
		description: 'Read a rig\'s joints: every Motor6D (Part0, Part1, C0, C1, Transform) and Bone (CFrame, Transform). Use C0 values as the base for eclipse_set_keyframe.',
		inputSchema: { type: 'object', properties: { target, studio }, required: ['target'] },
		call: (a) => ({ op: 'studio.pose', args: { target: a.target }, studio: a.studio }),
	},
	{
		name: 'studio_read_animation',
		description: 'List the animations saved in a rig\'s AnimSaves (Eclipse exports KeyframeSequences there), or read one by name: every keyframe time and pose (CFrame, easing, weight).',
		inputSchema: { type: 'object', properties: { target, name: { type: 'string' }, studio }, required: ['target'] },
		call: (a) => ({ op: 'studio.animation', args: { target: a.target, name: a.name }, studio: a.studio }),
	},
	{
		name: 'studio_selection',
		description: 'What Kash has selected in Studio right now (read only; helpers never change his selection).',
		inputSchema: { type: 'object', properties: { studio } },
		call: (a) => ({ op: 'studio.selection', args: {}, studio: a.studio }),
	},
	{
		name: 'helper_focus',
		description: 'Show Kash what you are looking at: outlines the targets in your color with your name and a short note in the Studio viewport, without editing anything.',
		inputSchema: { type: 'object', properties: { targets: { type: 'array', items: target }, note: { type: 'string', maxLength: 80 }, studio }, required: ['targets'] },
		call: (a) => ({ op: 'helper.focus', args: { targets: a.targets, note: a.note }, studio: a.studio }),
	},
	{
		name: 'helper_claim',
		description: 'Reserve tracks so other helpers leave them alone while you work (5 to 600 seconds). Edits also reserve their tracks for 20 seconds automatically. property narrows a claim to one property track.',
		inputSchema: {
			type: 'object',
			properties: { targets: { type: 'array', items: { type: 'object', properties: { target, property: { type: 'string' } }, required: ['target'] } }, seconds: { type: 'integer' }, force, studio },
			required: ['targets'],
		},
		route: 'claim',
	},
	{
		name: 'helper_release',
		description: 'Release tracks you claimed (all of them when targets is left out).',
		inputSchema: { type: 'object', properties: { targets: { type: 'array', items: { type: 'object' } } } },
		route: 'release',
	},
	{
		name: 'helper_presence',
		description: 'Who is working right now: every helper (name, color, status), Studio windows, Kash\'s selection/frame/editing state, held tracks, and recent activity.',
		inputSchema: { type: 'object', properties: {} },
		route: 'presence',
	},
	{
		name: 'helper_identity',
		description: 'Change your helper name or color (#RRGGBB) as shown to Kash in Studio.',
		inputSchema: { type: 'object', properties: { name: { type: 'string' }, color: { type: 'string' } } },
		route: 'identity',
	},
];

module.exports = { TOOLS, VALUES };
