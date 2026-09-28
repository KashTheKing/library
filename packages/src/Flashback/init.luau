--!strict
--[=[
	@class Flashback
	Flashback records gameplay on the server into a compact binary replay and
	plays it back on the client or inside Studio.

	Server:
		local Flashback = require(ReplicatedStorage.Flashback)
		local rec = Flashback.Recorder.new({ tickRate = 15 })
		rec:start()
		local blob = rec:stop()
		Flashback.Store.save("match_1", blob)

	Client or Studio:
		local player = Flashback.Player.new(blob)
		player:play()

	The Studio plugin installs a server Script that calls Flashback.Studio.serve()
	so play tests can be recorded from the plugin.
]=]

local HttpStore = require(script.HttpStore)
local MoonExport = require(script.MoonExport)
local Player = require(script.Player)
local Recorder = require(script.Recorder)
local Serializer = require(script.Serializer)
local Snapshot = require(script.Snapshot)
local Store = require(script.Store)
local Studio = require(script.Studio)

export type Recorder = Recorder.Recorder
export type Player = Player.Player
export type Writer = Serializer.Writer
export type Reader = Serializer.Reader
export type StudioStartOptions = Studio.StartOptions
export type StudioSaveResult = Studio.SaveResult
export type StudioTarget = Studio.Target

local Flashback = {
	Recorder = Recorder,
	Player = Player,
	Serializer = Serializer,
	Snapshot = Snapshot,
	Store = Store,
	HttpStore = HttpStore,
	MoonExport = MoonExport,
	Studio = Studio,
	VERSION = Serializer.VERSION,
	TAG = Recorder.TAG,
	DESCRIPTOR_ATTRIBUTE = Recorder.DESCRIPTOR_ATTRIBUTE,
}

return Flashback
