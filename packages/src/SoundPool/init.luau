--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ObjectPool = require(script.Parent.ObjectPool)
local Signal = require(script.Parent.Signal)
local Trove = require(script.Parent.Trove)

local ID_FORMAT: string = "rbxassetid://%s"

local SoundPlayback = {}
SoundPlayback.__index = SoundPlayback

local SoundPool = {}
SoundPool.__index = SoundPool

--Types
export type PooledSound = Part & {["Sound"]: Sound}

export type SoundPoolProperties = {
	PooledSoundsFolder: Folder,
	ObjectPool: ObjectPool.ObjectPool<PooledSound>,
}

export type SoundPool = typeof(setmetatable({} :: SoundPoolProperties, SoundPool))

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
function SoundPlayback.UpdateConfig(self: SoundPlayback, soundConfig: SoundConfig)
	applySoundConfig(self.PooledSound, self.SoundInstance, soundConfig)
end

--Pauses the sound
function SoundPlayback.Pause(self: SoundPlayback)
	self.SoundInstance:Pause()
end

--Resumes the sound when paused
function SoundPlayback.Resume(self: SoundPlayback)
	self.SoundInstance:Resume()
end

--Stops the sound
function SoundPlayback.Stop(self: SoundPlayback)
	self.SoundInstance:Stop()
end

--Returns the pooled sound to the SoundPool
function SoundPlayback.Return(self: SoundPlayback)
	self.ReturnCallback()
	
	setmetatable(self, {__index = function()
		error("Sound has already been returned.")
	end,})
end

--Creates a new SoundPool
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