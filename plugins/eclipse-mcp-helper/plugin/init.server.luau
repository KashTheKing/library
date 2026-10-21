--!strict
-- Eclipse Animator MCP Helper: lets AI helpers (Claude, as many as Kash wants) work live in Eclipse Animator next
-- to him. Commands come from the local bridge; edits go through Eclipse's own extension API.

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local Selection = game:GetService("Selection")
local StudioService = game:GetService("StudioService")

local Root = script
local Fusion = require(Root.Packages.Fusion)
local Bridge = require(Root.Bridge)
local Commands = require(Root.Commands)
local Ownership = require(Root.Ownership)
local Presence = require(Root.Presence)
local Live = require(Root.Live)
local EclipseWindow = require(Root.EclipseWindow)
local Theme = require(Root.UI.Theme)
local Watcher = require(Root.Watcher)
local App = require(Root.UI.App)

local VERSION = "1.0.0"
local PORT = tonumber(plugin:GetSetting("Port")) or 49210

local okId, studioUserId = pcall(function()
	return StudioService:GetUserId()
end)
local userId: number = if okId and type(studioUserId) == "number" then studioUserId else 0

local function userName(): string
	local id = userId
	if id > 0 then
		local okName, name = pcall(Players.GetNameFromUserIdAsync, Players, id)
		if okName then
			return name
		end
	end
	return "Kash"
end

local me = userName()
local scope = Fusion.scoped(Fusion)
local state: App.State = {
	Connection = scope:Value("connecting"),
	Detail = scope:Value(nil :: string?),
	Eclipse = scope:Value({ found = false, active = false } :: any),
	Agents = scope:Value({}),
	Leases = scope:Value({}),
	Activity = scope:Value({}),
	Paused = scope:Value(false),
	ShowPresence = scope:Value(plugin:GetSetting("ShowPresence") ~= false),
}

local presence = Presence.new()
presence:setEnabled(Fusion.peek(state.ShowPresence))
local live = Live.new(ServerStorage, userId)

local ctx: Commands.Context = {
	root = game,
	coreGui = nil,
	ownership = Ownership.new(),
	selection = function()
		return Selection:Get()
	end,
	touch = function(agent, targets, note, frame)
		presence:touch(agent, targets, note)
		if frame then
			live:noteFrame(agent.id, frame)
		end
	end,
	human = function()
		return nil
	end,
	busy = false,
	live = function()
		return live:status()
	end,
}

local lastSnapshot: any = nil
ctx.human = function()
	return lastSnapshot and lastSnapshot.human
end

-- Commands run strictly one after another: Eclipse's API takes one request at a time.
local queue: { any } = {}
local running = false
local bridge: Bridge.Bridge

local function drain()
	if running then
		return
	end
	running = true
	while #queue > 0 do
		local cmd = table.remove(queue, 1) :: any
		local ok, result, summary = Commands.run(ctx, cmd)
		bridge:result(cmd.id, ok, result, summary)
	end
	running = false
end

local known: { [string]: boolean } = {}

bridge = Bridge.new(PORT, {
	place = game.Name,
	user = { name = me },
	pluginVersion = VERSION,
}, {
	onCommands = function(commands)
		for _, cmd in commands do
			table.insert(queue, cmd)
		end
		task.spawn(drain)
	end,
	onPresence = function(p)
		local seen: { [string]: boolean } = {}
		for _, a: any in p.agents or {} do
			seen[a.id] = true
		end
		for id in known do
			if not seen[id] then
				presence:forget(id)
			end
		end
		known = seen
		state.Agents:set(p.agents or {})
		state.Leases:set(p.leases or {})
		state.Activity:set(p.activity or {})
	end,
	onStatus = function(status, detail)
		state.Connection:set(status)
		state.Detail:set(detail)
		if status == "connected" and Fusion.peek(state.Paused) then
			-- A restarted bridge forgets the pause; tell it again.
			bridge:control({ paused = true })
		end
	end,
})
bridge:start()

local stopWatching = Watcher.start(ctx, me, function(snap: any)
	snap.live = live:status() or false -- false tells the bridge Live ended
	lastSnapshot = snap
	state.Eclipse:set(snap.eclipse)
	bridge:state(snap)
end)

-- Eclipse Live: while Kash is in a Live session, each helper is in it too (paused or stopped helpers step out).
local liveRunning = true
task.spawn(function()
	while liveRunning do
		local agents = if Fusion.peek(state.Paused) then {} else Fusion.peek(state.Agents)
		local eclipse = Fusion.peek(state.Eclipse)
		pcall(live.update, live, agents, eclipse.frame, eclipse.fps)
		task.wait(1)
	end
end)

-- UI: a dock widget opened from a HELPERS button in Eclipse's own top bar (no toolbar of its own). A plugin action
-- (bind a shortcut to it in Studio's shortcut settings) opens it too.
local widget = plugin:CreateDockWidgetPluginGui(
	"EclipseMCPHelper",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 340, 520, 280, 320)
)
widget.Title = "Eclipse Animator · Helpers"
widget.Name = "EclipseMCPHelper"

local function toggle()
	widget.Enabled = not widget.Enabled
end

local eclipseWindow = EclipseWindow.watch({
	defaults = Theme.Defaults :: any,
	onPalette = function(palette)
		Theme.Palette:set(palette :: any)
	end,
	onClick = toggle,
})

local action = plugin:CreatePluginAction(
	"EclipseMCPHelperToggle",
	"Eclipse Animator: Helpers",
	"Show the AI helpers working with you in Eclipse Animator",
	"",
	true
)
action.Triggered:Connect(toggle)

App(scope, {
	State = state,
	Parent = widget,
	OnPause = function(paused)
		state.Paused:set(paused)
		bridge:control({ paused = paused })
	end,
	OnShowPresence = function(on)
		state.ShowPresence:set(on)
		presence:setEnabled(on)
		plugin:SetSetting("ShowPresence", on)
	end,
	OnStop = function(id)
		presence:forget(id)
		bridge:control({ stop = id })
	end,
	OnResume = function(id)
		bridge:control({ resume = id })
	end,
})

widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	eclipseWindow.setOpen(widget.Enabled)
end)
eclipseWindow.setOpen(widget.Enabled)

plugin.Unloading:Connect(function()
	bridge:stop()
	stopWatching()
	presence:destroy()
	liveRunning = false
	live:leave()
	eclipseWindow.stop()
	Fusion.doCleanup(scope)
end)
