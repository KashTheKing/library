--!strict
--[=[
	@class Studio
	Server-side controller used by the Studio plugin during play tests. The
	plugin lives in the client DataModel, so it drives recording through a
	RemoteFunction that only exists in Studio.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local HttpStore = require(script.Parent.HttpStore)
local Recorder = require(script.Parent.Recorder)
local Store = require(script.Parent.Store)

local REMOTE_NAME = "FlashbackStudio"

export type StartOptions = {
	tickRate: number?,
	keyframeEvery: number?,
	trackCharacters: boolean?,
	watch: string?,
	recordAnimations: boolean?,
	recordAttributes: boolean?,
	recordScale: boolean?,
	recordDescendants: boolean?,
}

export type Status = {
	recording: boolean,
	elapsed: number,
	bytes: number,
	pending: boolean,
}

export type SaveResult = {
	ok: boolean,
	exists: boolean?,
	message: string,
}

-- Where replays live. `store` is a DataStore name for `datastore` and a base
-- URL for `http`.
export type Target = {
	backend: "datastore" | "http",
	store: string,
	token: string?,
}

local Studio = {}
Studio.REMOTE_NAME = REMOTE_NAME
Studio.DEFAULT_WATCH = Recorder.DEFAULT_WATCH

local recorder: Recorder.Recorder? = nil
local blob: buffer? = nil

--[=[
	Builds a recorder from plugin settings. Shared with the plugin's local
	backend so edit-mode and play-mode recordings match. `watch` is a list
	such as `BasePart.Color,Humanoid.Health` (see `Recorder.parseWatch`).
	@within Studio
]=]
function Studio.createRecorder(opts: StartOptions): Recorder.Recorder
	local rec = Recorder.new({
		tickRate = math.clamp(opts.tickRate or 15, 1, 60),
		keyframeEvery = math.max(1, opts.keyframeEvery or 150),
		trackCharacters = opts.trackCharacters ~= false,
		watch = opts.watch,
		recordAnimations = opts.recordAnimations ~= false,
		recordAttributes = opts.recordAttributes == true,
		recordScale = opts.recordScale == true,
		recordDescendants = opts.recordDescendants ~= false,
	})
	return rec
end

local function exists(key: string, target: Target): boolean
	if target.backend == "http" then
		return HttpStore.exists(key, target.store, target.token)
	end
	return Store.meta(key, target.store) ~= nil
end

function Studio.list(target: Target): { string }
	if target.backend == "http" then
		return HttpStore.list(target.store, target.token)
	end
	return Store.list(target.store)
end

function Studio.load(key: string, target: Target): buffer?
	if target.backend == "http" then
		return HttpStore.load(key, target.store, target.token)
	end
	return Store.load(key, target.store)
end

function Studio.remove(key: string, target: Target)
	if target.backend == "http" then
		HttpStore.remove(key, target.store, target.token)
	else
		Store.remove(key, target.store)
	end
end

--[=[
	Saves a finished recording, refusing to overwrite unless forced.
	@within Studio
]=]
function Studio.saveBlob(data: buffer, key: string, target: Target, force: boolean): SaveResult
	if key == "" then
		return { ok = false, message = "Set a session name before saving" }
	end
	if not force then
		local ok, found = pcall(exists, key, target)
		if not ok then
			return { ok = false, message = `Storage unavailable: {found}` }
		end
		if found then
			return { ok = false, exists = true, message = `"{key}" already exists` }
		end
	end
	local ok, err = pcall(function()
		if target.backend == "http" then
			HttpStore.save(key, data, target.store, target.token)
		else
			Store.save(key, data, target.store)
		end
	end)
	if ok then
		return { ok = true, message = `Saved {key}` }
	end
	return { ok = false, message = `Save failed: {err}` }
end

local function status(): Status
	local rec = recorder
	return {
		recording = rec ~= nil and rec:isRunning(),
		elapsed = if rec then rec:elapsed() else 0,
		bytes = if blob then buffer.len(blob) elseif rec then rec:byteCount() else 0,
		pending = blob ~= nil,
	}
end

local function handle(_player: Player, action: string, arg: any): any
	if action == "status" then
		return status()
	elseif action == "start" then
		if recorder and recorder:isRunning() then
			return status()
		end
		local rec = Studio.createRecorder(arg or {})
		rec:start()
		recorder = rec
		blob = nil
		return status()
	elseif action == "stop" then
		local rec = recorder
		if rec and rec:isRunning() then
			blob = rec:stop()
		end
		return status()
	elseif action == "save" then
		local data = blob
		if not data then
			return { ok = false, message = "Nothing recorded yet" }
		end
		local result = Studio.saveBlob(data, arg.key, arg.target, arg.force == true)
		if result.ok then
			blob = nil
		end
		return result
	elseif action == "take" then
		local data = blob
		blob = nil
		return data
	elseif action == "discard" then
		blob = nil
		return status()
	elseif action == "list" then
		return Studio.list(arg.target)
	elseif action == "load" then
		return Studio.load(arg.key, arg.target)
	elseif action == "remove" then
		Studio.remove(arg.key, arg.target)
		return true
	end
	error(`unknown action {action}`)
end

--[=[
	Creates the RemoteFunction and starts serving. No-op outside Studio.
	@within Studio
]=]
function Studio.serve()
	if not RunService:IsStudio() or not RunService:IsServer() then
		return
	end
	if ReplicatedStorage:FindFirstChild(REMOTE_NAME) then
		return
	end
	local remote = Instance.new("RemoteFunction")
	remote.Name = REMOTE_NAME
	remote.OnServerInvoke = handle
	remote.Parent = ReplicatedStorage
end

function Studio.remote(): RemoteFunction?
	local r = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
	return if r and r:IsA("RemoteFunction") then r else nil
end

return Studio
