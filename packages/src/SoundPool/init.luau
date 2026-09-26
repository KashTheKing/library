--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ObjectPool = require(script.Parent.ObjectPool)
local Signal = require(script.Parent.Signal)
local Trove = require(script.Parent.Trove)

local ID_FORMAT: string = "rbxassetid://%s"

--[=[
	@class SoundPlayback
	@deprecated v1.0.0 -- Part of the deprecated SoundPool package; no longer maintained.

	A handle to one sound started by [SoundPool:PlaySound](/api/SoundPool#PlaySound). It wraps the
	borrowed `Sound` instance, lets you pause / resume / stop it or change its config while it
	plays, and returns the pooled part to the pool with `Return`. When the sound ends on its own
	(`Sound.Ended`) it is returned automatically. After `Return`, using the handle in any way
	errors with "Sound has already been returned.".

	```lua
	local playback = pool:PlaySound(1234567890)
	playback:UpdateConfig({ Volume = 0.3, Position = character.HumanoidRootPart.Position })

	playback.Ended:Connect(function()
		print("done") -- the pooled sound has already been returned at this point
	end)

	task.wait(1)
	playback:Stop()
	playback:Return() -- Stop does not fire Ended, so return it yourself
	```

	This package is no longer maintained; see the deprecation notice on
	[SoundPool](/api/SoundPool).
]=]
local SoundPlayback = {}
SoundPlayback.__index = SoundPlayback

--[=[
	@class SoundPool
	@deprecated v1.0.0 -- No longer maintained; kept for existing projects. There is no direct replacement.

	:::caution Deprecated
	SoundPool is no longer maintained and is kept only for existing projects. There is no direct
	replacement in this library.
	:::

	A pool of reusable, invisible anchored Parts each holding one `Sound`, for playing many short
	3D sound effects (fighting-game SFX, hit sounds) without creating and destroying instances every
	time. `PlaySound` borrows a part from the pool, points its `Sound` at the asset and plays it,
	handing you a [SoundPlayback](/api/SoundPlayback) to control it; the part goes back to the pool
	when the sound ends or when you call `Return`.

	The pooled parts live in a Folder created in `workspace` and named after the pool. Pooling is
	done by frqstbite's `object-pool` package (`ObjectPool.new(generator, minimum, maximum)`), so
	`minimum` parts are created up front and the pool never grows past `maximum`.

	```lua
	local SoundPool = require(path.to.SoundPool)

	local hitSounds = SoundPool.new("HitSounds", 4, 32)

	local function playHit(position: Vector3)
		local playback = hitSounds:PlaySound(9118823101, { Volume = 0.8, Position = position })
		-- In this version the config passed to PlaySound is not applied; set it explicitly:
		playback:UpdateConfig({ Volume = 0.8, Position = position })
		return playback
	end
	```

	Depends on Sleitnick's [Trove](https://sleitnick.github.io/RbxUtil/api/Trove/) and
	[Signal](https://sleitnick.github.io/RbxUtil/api/Signal/) and on frqstbite's
	[object-pool](https://wally.run/package/frqstbite/object-pool), all installed by Wally.

	**Credits:** [Trove](https://sleitnick.github.io/RbxUtil/api/Trove/) and [Signal](https://sleitnick.github.io/RbxUtil/api/Signal/) are by [sleitnick](https://github.com/Sleitnick) ([sleitnick's RbxUtil](https://sleitnick.github.io/RbxUtil/)); the pooling is [object-pool](https://wally.run/package/frqstbite/object-pool) by [frqstbite](https://github.com/frqstbite). Wally installs all three.

	Installation and guide: [SoundPool package page](/docs/packages/sound-pool).
]=]
local SoundPool = {}
SoundPool.__index = SoundPool

--Types
--[=[
	@type PooledSound Part & { Sound: Sound }
	@within SoundPool
	An invisible, anchored, non-collidable Part with a child `Sound` named "Sound". The Part is positioned for 3D playback; the Sound plays the asset.
]=]
export type PooledSound = Part & {["Sound"]: Sound}

--[=[
	@prop PooledSoundsFolder Folder
	@within SoundPool
	@readonly
	The Folder in `workspace` (named after the pool's `displayName`) that holds every pooled Part.
]=]
--[=[
	@prop ObjectPool ObjectPool<PooledSound>
	@within SoundPool
	@readonly
	The underlying frqstbite object-pool that hands out and takes back pooled Parts.
]=]
export type SoundPoolProperties = {
	PooledSoundsFolder: Folder,
	ObjectPool: ObjectPool.ObjectPool<PooledSound>,
}

export type SoundPool = typeof(setmetatable({} :: SoundPoolProperties, SoundPool))

--[=[
	@prop Trove Trove
	@within SoundPlayback
	Holds the wrapped signals below. It is not cleaned by `Return`; clean it yourself if you keep the handle around.
]=]
--[=[
	@prop SoundInstance Sound
	@within SoundPlayback
	@readonly
	The pooled `Sound` that is playing. Read its properties (e.g. `TimePosition`) here; prefer `UpdateConfig` for writing.
]=]
--[=[
	@prop PooledSound PooledSound
	@within SoundPlayback
	@readonly
	The borrowed Part the Sound is parented to; move it to move the sound in 3D.
]=]
--[=[
	@prop Returned boolean
	@within SoundPlayback
	@readonly
	`true` once the pooled sound has been given back to the pool.
]=]
--[=[
	@prop Ended Signal<string>
	@within SoundPlayback
	@readonly
	Wraps `Sound.Ended`: fires with the sound id when playback finishes naturally. The pool has already returned the sound when your connection runs.
]=]
--[=[
	@prop Stopped Signal<string>
	@within SoundPlayback
	@readonly
	Wraps `Sound.Stopped`: fires with the sound id after `Stop`.
]=]
--[=[
	@prop Paused Signal<string>
	@within SoundPlayback
	@readonly
	Wraps `Sound.Paused`: fires with the sound id after `Pause`.
]=]
--[=[
	@prop Resumed Signal<string>
	@within SoundPlayback
	@readonly
	Wraps `Sound.Resumed`: fires with the sound id after `Resume`.
]=]
--[=[
	@prop DidLoop Signal<string, number>
	@within SoundPlayback
	@readonly
	Wraps `Sound.DidLoop`: fires with the sound id and the loop count each time a looped sound restarts.
]=]
export type SoundPlaybackProperties = {
	Trove: Trove.Trove,
	
	SoundInstance: Sound,
	PooledSound: PooledSound,
	
	Returned: boolean,
	ReturnCallback: ()->(),
	
	Ended: Signal.Signal<string>,
	Stopped: Signal.Signal<string>,
	Paused: Signal.Signal<string>,
	Resumed: Signal.Signal<string>,
	DidLoop: Signal.Signal<string, number>,
}

export type SoundPlayback = typeof(setmetatable({} :: SoundPlaybackProperties, SoundPlayback))

--[=[
	@interface SoundConfig
	@within SoundPool
	.Volume number? -- `Sound.Volume`.
	.SoundGroup SoundGroup? -- `Sound.SoundGroup` to route the sound through.
	.PlaybackSpeed number? -- `Sound.PlaybackSpeed` (1 is normal speed).
	.TimePosition number? -- `Sound.TimePosition` in seconds to start from.
	.Looped boolean? -- `Sound.Looped`; `false` is applied too, only `nil` is skipped.
	.Position Vector3? -- World position of the pooled Part, which makes the sound 3D.
	.RollOffMinDistance number? -- `Sound.RollOffMinDistance`.
	.RollOffMaxDistance number? -- `Sound.RollOffMaxDistance`.
	.RollOffMode Enum.RollOffMode? -- `Sound.RollOffMode`.

	Optional property overrides for a playing sound, applied by `SoundPlayback:UpdateConfig`. Every
	field is optional and only the fields you set are written; the rest keep whatever value the
	pooled Sound already has from its previous use, so set everything you care about each time.
	Note that `SoundPool:PlaySound` accepts a config but this version does not apply it; call
	`UpdateConfig` on the returned playback.
]=]
export type SoundConfig = {
	--Basic Properties
	Volume: number?,
	SoundGroup: SoundGroup?,
	PlaybackSpeed: number?,
	TimePosition: number?,
	Looped: boolean?,
	
	--3D Properties
	Position: Vector3?,
	RollOffMinDistance: number?,
	RollOffMaxDistance: number?,
	RollOffMode: Enum.RollOffMode?,
}

local function formatSoundId(id: number | string): string
	local soundId: string

	local t = type(id)

	if t == "string" then
		soundId = id :: string
	elseif t == "number" then
		soundId = string.format(ID_FORMAT :: any, tostring(id))
	else
		error(`Sound id given is not a valid string or number, type given: {t}`)
	end
	
	return soundId
end

local function applySoundConfig(pooledSound: PooledSound, soundInstance: Sound, soundConfig: SoundConfig)
	if soundConfig.Position then
		pooledSound.Position = soundConfig.Position
	end

	local volume = soundConfig.Volume
	if volume then soundInstance.Volume = volume end

	local playbackSpeed = soundConfig.PlaybackSpeed
	if playbackSpeed then soundInstance.PlaybackSpeed = playbackSpeed end

	local timePosition = soundConfig.TimePosition
	if timePosition then soundInstance.TimePosition = timePosition end

	local looped = soundConfig.Looped
	if looped ~= nil then soundInstance.Looped = looped end

	local soundGroup = soundConfig.SoundGroup
	if soundGroup then soundInstance.SoundGroup = soundGroup end

	local rollOffMin = soundConfig.RollOffMinDistance
	if rollOffMin then soundInstance.RollOffMinDistance = rollOffMin end

	local rollOffMax = soundConfig.RollOffMaxDistance
	if rollOffMax then soundInstance.RollOffMaxDistance = rollOffMax end

	local rollOffMode = soundConfig.RollOffMode
	if rollOffMode then soundInstance.RollOffMode = rollOffMode end
end

--Creates a new sound playback
--[=[
	Wraps a borrowed pooled sound, connects the Sound's events as Signals, arranges for `Return` to
	be called when `Ended` fires, and starts playback with `Sound:Play()`. Created by
	`SoundPool:PlaySound`; not meant to be called directly. The `soundConfig` argument is stored
	nowhere and not applied.

	@function new
	@within SoundPlayback
	@private
	@param pooledSound PooledSound -- The borrowed Part.
	@param soundInstance Sound -- The Sound inside that Part, with `SoundId` already set.
	@param soundConfig SoundConfig? -- Accepted but unused in this version.
	@param returnCallback () -> () -- Called once by `Return` to give the Part back to the pool.
	@return SoundPlayback -- The playing handle.
]=]
function SoundPlayback.new(pooledSound: PooledSound, soundInstance: Sound, soundConfig: SoundConfig?, returnCallback: ()->()): SoundPlayback	
	local properties = {}
	
	local trove = Trove.new()
	
	properties.Trove = trove
	properties.Returned = false
	properties.ReturnCallback = function()
		assert(properties.Returned == false, "Sound has already been returned.")
		
		properties.Returned = true
		returnCallback()
	end
	
	properties.PooledSound = pooledSound
	properties.SoundInstance = soundInstance
	
	--Events
	properties.Ended = trove:Add(Signal.Wrap(soundInstance.Ended))
	properties.Stopped = trove:Add(Signal.Wrap(soundInstance.Stopped))
	properties.Paused = trove:Add(Signal.Wrap(soundInstance.Paused))
	properties.Resumed = trove:Add(Signal.Wrap(soundInstance.Resumed))
	properties.DidLoop = trove:Add(Signal.Wrap(soundInstance.DidLoop))
	
	local self: SoundPlayback = setmetatable(properties, {__index = SoundPlayback}) :: any
	
	trove:Connect(self.Ended, function()
		if not self.Returned then
			self:Return()
		end
	end)
	
	soundInstance:Play()
	
	return self
end

--Updates the sound config and applies it during runtime
--[=[
	Applies the fields set in `soundConfig` to the playing Sound (and `Position` to the pooled
	Part) immediately. Fields left `nil` are not touched. This is currently the only way to
	configure a sound, since `PlaySound` ignores its config argument.

	@method UpdateConfig
	@within SoundPlayback
	@param soundConfig SoundConfig -- The properties to change.
]=]
function SoundPlayback.UpdateConfig(self: SoundPlayback, soundConfig: SoundConfig)
	applySoundConfig(self.PooledSound, self.SoundInstance, soundConfig)
end

--Pauses the sound
--[=[
	Pauses the Sound (`Sound:Pause()`), keeping its `TimePosition`. Fires `Paused`.

	@method Pause
	@within SoundPlayback
]=]
function SoundPlayback.Pause(self: SoundPlayback)
	self.SoundInstance:Pause()
end

--Resumes the sound when paused
--[=[
	Resumes a paused Sound from where it stopped (`Sound:Resume()`). Fires `Resumed`.

	@method Resume
	@within SoundPlayback
]=]
function SoundPlayback.Resume(self: SoundPlayback)
	self.SoundInstance:Resume()
end

--Stops the sound
--[=[
	Stops the Sound (`Sound:Stop()`) and resets its `TimePosition`. Fires `Stopped`, not `Ended`,
	so the pooled sound is not returned automatically; call `Return` when you are done with it.

	@method Stop
	@within SoundPlayback
]=]
function SoundPlayback.Stop(self: SoundPlayback)
	self.SoundInstance:Stop()
end

--Returns the pooled sound to the SoundPool
--[=[
	Gives the pooled Part back to the SoundPool so it can be reused, and marks the handle as
	returned. It does not stop the Sound first, so call `Stop` before `Return` if it is still
	playing. Called automatically when the sound `Ended`. After this, indexing the handle (any
	property or method) errors, so drop your reference.

	@method Return
	@within SoundPlayback
	@error "Sound has already been returned." -- Called a second time on the same playback.
]=]
function SoundPlayback.Return(self: SoundPlayback)
	self.ReturnCallback()
	
	setmetatable(self, {__index = function()
		error("Sound has already been returned.")
	end,})
end

--Creates a new SoundPool
--[=[
	Creates a SoundPool. A Folder named `displayName` is created in `workspace` to hold the pooled
	Parts, and an object-pool is set up that generates Parts with `_GenerateSound`, creating
	`minimum` of them right away and never holding more than `maximum`.

	@function new
	@within SoundPool
	@param displayName string -- Name of the workspace Folder that holds the pooled Parts.
	@param minimum number -- How many pooled sounds to create up front.
	@param maximum number -- The most pooled sounds the pool may hold.
	@return SoundPool -- The new pool.
]=]
function SoundPool.new(displayName: string, minimum: number, maximum: number): SoundPool
	local self = setmetatable({}, SoundPool)
	
	local pooledSoundsFolder = Instance.new("Folder")
	pooledSoundsFolder.Name = displayName
	pooledSoundsFolder.Parent = workspace
	
	self.PooledSoundsFolder = pooledSoundsFolder
	
	self.ObjectPool = ObjectPool.new(function()
		return self:_GenerateSound()
	end, minimum, maximum)
	
	return self
end

--[=[
	Generator used by the object-pool: builds one pooled sound, a 1x1x1 invisible anchored Part
	(`CanCollide`, `CanQuery` and `CanTouch` off) at the origin named "PooledSound" inside
	`PooledSoundsFolder`, with a child `Sound` named "Sound" at volume 1 and an empty `SoundId`.

	@method _GenerateSound
	@within SoundPool
	@private
	@return PooledSound -- The new pooled Part.
]=]
function SoundPool._GenerateSound(self: SoundPool): PooledSound
	local pooledSound = Instance.new("Part")
	pooledSound.Size = Vector3.one
	pooledSound.Anchored = true
	pooledSound.CanCollide = false
	pooledSound.Transparency = 1
	pooledSound.Position = Vector3.zero
	pooledSound.CanQuery = false
	pooledSound.CanTouch = false
	pooledSound.Name = "PooledSound"
	pooledSound.Parent = self.PooledSoundsFolder

	local soundInstance = Instance.new("Sound")
	soundInstance.Name = "Sound"
	soundInstance.SoundId = ""
	soundInstance.Volume = 1
	soundInstance.Parent = pooledSound

	return pooledSound :: PooledSound
end

--[=[
	Borrows a pooled sound, sets its `SoundId` and starts playing it, returning a
	[SoundPlayback](/api/SoundPlayback) handle. A number `id` is formatted as
	`rbxassetid://<id>`; a string is used as-is (so any `rbxassetid://` string works). The
	pooled Part is returned to the pool automatically when the sound ends, or when you call
	`Return` on the handle.

	:::caution
	In this version `soundConfig` is accepted but never applied. Call `UpdateConfig` on the returned
	playback to set volume, position and the other properties. Pooled Sounds keep the properties
	from their previous use, so always set the ones you rely on.
	:::

	@method PlaySound
	@within SoundPool
	@param id number | string -- An asset id number, or a full sound id string.
	@param soundConfig SoundConfig? -- Intended initial properties; not applied in this version (see above).
	@return SoundPlayback -- Handle to the playing sound.
	@error "Sound id given is not a valid string or number" -- `id` is neither a number nor a string.
	@error "PooledSound is missing Sound instance." -- The borrowed Part lost its child Sound (e.g. it was destroyed externally).
]=]
function SoundPool.PlaySound(self: SoundPool, id: number | string, soundConfig: SoundConfig?): SoundPlayback
	local soundId = formatSoundId(id)
	
	local pooledSound = self.ObjectPool:Borrow(soundId)
	local sound = assert(pooledSound:FindFirstChild("Sound") :: Sound, "PooledSound is missing Sound instance.")
	
	sound.SoundId = soundId
	
	local playback = SoundPlayback.new(pooledSound, sound, soundConfig, function()
		self.ObjectPool:Return(pooledSound)
	end)
	
	return playback
end

return SoundPool