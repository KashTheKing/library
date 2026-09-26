--[[
	Water events for tagged instances and player characters, on whichever side you connect from
	(server scripts get server-side events, LocalScripts get client-side ones; same wave function).

	Tracked: anything tagged "OceanFloat" or "OceanTrack", plus every player's character.
	For each, every frame:
		Touching  - its bottom is below the surface (any part of it is wet)
		Under     - its top is below the surface (fully submerged)
	and the transitions fire:
		EnteredWater(instance)    dry -> touching
		ExitedWater(instance)     touching -> dry
		WentUnderWater(instance)  -> fully under
		WentAboveWater(instance)  fully under -> not
	`instance` is the tagged part/model, or the character Model. Inside an "OceanDry" region nothing
	counts as water.
]]
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Regions = require(script.Parent.Regions)
local Settings = require(script.Parent.Settings)
local Waves = require(script.Parent.Waves)

--[=[
	@class Tracker

	Water state for tagged instances (`OceanFloat`, `OceanTrack`) and every player character, updated
	each frame on whichever side you ask from. The transitions fire the signals on [Ocean]:
	`EnteredWater`, `ExitedWater`, `WentUnderWater`, `WentAboveWater`. Inside an `OceanDry` region
	nothing counts as water.
]=]
--[=[
	@interface State
	@within Tracker
	.Touching boolean -- its bottom is below the surface
	.Under boolean -- its top is below the surface
	.Depth number -- studs below the surface (negative above)
	.Surface number -- world Y of the surface there
]=]
local Tracker = {}

export type State = { Touching: boolean, Under: boolean, Depth: number, Surface: number }

local events = {}
for _, name in { "EnteredWater", "ExitedWater", "WentUnderWater", "WentAboveWater" } do
	local bindable = Instance.new("BindableEvent")
	bindable.Name = name
	events[name] = bindable
	Tracker[name] = bindable.Event
end

local states: { [Instance]: State } = {}

-- world-space top/bottom of the thing, and where to sample the surface
local function extent(instance: Instance): (number?, number, number, number)
	if instance:IsA("Model") then
		local root = instance:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then -- a character: feet to head
			local p = root.Position
			return p.X, p.Z, p.Y - 3, p.Y + 1.5
		end
		local cframe, size = instance:GetBoundingBox()
		local p = cframe.Position
		return p.X, p.Z, p.Y - size.Y / 2, p.Y + size.Y / 2
	elseif instance:IsA("BasePart") then
		local cf, size = instance.CFrame, instance.Size
		local ey = (
			math.abs(cf.RightVector.Y) * size.X
			+ math.abs(cf.UpVector.Y) * size.Y
			+ math.abs(cf.LookVector.Y) * size.Z
		) / 2
		local p = cf.Position
		return p.X, p.Z, p.Y - ey, p.Y + ey
	end
	return nil, 0, 0, 0
end

local function step()
	local seen: { [Instance]: boolean } = {}
	local list: { Instance } = {}
	for _, instance in CollectionService:GetTagged(Settings.Get("FloatTag")) do
		if instance:IsDescendantOf(workspace) then
			seen[instance] = true
			table.insert(list, instance)
		end
	end
	for _, instance in CollectionService:GetTagged(Settings.Get("TrackTag")) do
		if not seen[instance] and instance:IsDescendantOf(workspace) then
			seen[instance] = true
			table.insert(list, instance)
		end
	end
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character and character:IsDescendantOf(workspace) and not seen[character] then
			seen[character] = true
			table.insert(list, character)
		end
	end

	for _, instance in list do
		local x, z, bottom, top = extent(instance)
		if x == nil then
			continue
		end
		local surface = Waves.Height(x, z)
		local touching = bottom < surface and not Regions.IsDryFor(Vector3.new(x, math.min(surface, top), z), instance)
		local under = touching and top < surface
		local state = states[instance]
		if not state then
			state = { Touching = false, Under = false, Depth = 0, Surface = surface }
			states[instance] = state
		end
		state.Depth = surface - bottom
		state.Surface = surface
		if touching ~= state.Touching then
			state.Touching = touching
			events[if touching then "EnteredWater" else "ExitedWater"]:Fire(instance)
		end
		if under ~= state.Under then
			state.Under = under
			events[if under then "WentUnderWater" else "WentAboveWater"]:Fire(instance)
		end
	end
	for instance, state in states do
		if not seen[instance] then
			states[instance] = nil
			if state.Under then
				events.WentAboveWater:Fire(instance)
			end
			if state.Touching then
				events.ExitedWater:Fire(instance)
			end
		end
	end
end

--[=[
	@within Tracker
	The state of a tracked instance, or nil.
	@param instance Instance
	@return State?
]=]
function Tracker.GetState(instance: Instance): State?
	return states[instance]
end

--[=[
	@within Tracker
	Every tracked instance touching the water.
	@return { Instance }
]=]
function Tracker.GetInWater(): { Instance }
	local list = {}
	for instance, state in states do
		if state.Touching then
			table.insert(list, instance)
		end
	end
	return list
end

--[=[
	@within Tracker
	@private
]=]
function Tracker.Init()
	RunService.Heartbeat:Connect(step)
end

return Tracker
