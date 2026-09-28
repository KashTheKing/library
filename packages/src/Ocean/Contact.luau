--[=[
	@class Contact

	Client-only. Foam where things cross the water: the FFT sea foams around every pillar, hull, rock and
	buoy standing in it, in its own surface.

	A slow scan (a few times a second) finds the parts the water actually passes through near the camera and
	hands them to the FFT surface as foam masks (Spectral.SetAutoFoam). The foam is then vertex foam in the
	water mesh, lit like the rest of the sea, and it joins the part it touches: no separate objects, particles
	or textures move about on top of the water.

	Only the FFT sea does this (WaveMode = FFT): the Gerstner sea's 8 stud mesh cannot draw a foam ring that
	small, so it has none.

	Left out on purpose: parts wider than MAX_EXTENT (islands, the seafloor slab), invisible parts, characters,
	and a part the water does not reach (a deck above the swell). Opt a part or model out with the attribute
	OceanContactFoam = false.
]=]
local RunService = game:GetService("RunService")

local Settings = require(script.Parent.Settings)
local Spectral = require(script.Parent.Spectral)
local Waves = require(script.Parent.Waves)

local Contact = {}

local SCAN_EVERY = 0.4 -- s between looks for parts crossing the surface
local REACH = 150 -- studs from the camera
local MAX_FOAM_PARTS = 32 -- the nearest this many parts get foam
local MAX_EXTENT = 90 -- studs: a wider waterline (an island, a slab) gets none
local ATTRIBUTE = "OceanContactFoam"

local parent: Instance? = nil
local connection: RBXScriptConnection? = nil
local params = OverlapParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
local sinceScan = math.huge
local suspended = false -- the renderer is short of frame time: no foam

local function optedOut(part: BasePart): boolean
	if part:GetAttribute(ATTRIBUTE) == false then
		return true
	end
	local model = part:FindFirstAncestorOfClass("Model")
	if model and (model:GetAttribute(ATTRIBUTE) == false or model:FindFirstChildOfClass("Humanoid")) then
		return true
	end
	return false
end

-- Whether the surface passes through the part right now (not just near it: a deck above the swell has none)
local function touchesWater(part: BasePart): boolean
	local cf, size = part.CFrame, part.Size
	local right, up, look = cf.RightVector, cf.UpVector, cf.LookVector
	local half = (math.abs(right.Y) * size.X + math.abs(up.Y) * size.Y + math.abs(look.Y) * size.Z) / 2
	local surface = Waves.Height(cf.X, cf.Z)
	return cf.Y - half <= surface + 0.5 and cf.Y + half >= surface - 0.5
end

-- Finds the parts the surface passes through near the camera and gives the nearest ones foam.
local function scan(camera: Vector3)
	local sea = Waves.SeaLevel
	local band = Waves.LookNumber("MaxAmp", camera.X, camera.Z) + 1.5
	local surface = if parent then parent:FindFirstChild("OceanSurface") else nil
	params.FilterDescendantsInstances = { surface }
	local found = workspace:GetPartBoundsInBox(
		CFrame.new(camera.X, sea, camera.Z),
		Vector3.new(REACH * 2, band * 2, REACH * 2),
		params
	)

	local candidates = {}
	for _, part in found do
		local size = part.Size
		-- two big dimensions = a wall or slab whose waterline is too long for foam
		local second = math.min(math.max(size.X, size.Y), math.max(size.Y, size.Z), math.max(size.X, size.Z))
		if part.Transparency <= 0.9 and second <= MAX_EXTENT and not optedOut(part) then
			table.insert(candidates, part)
		end
	end
	table.sort(candidates, function(a, b)
		return (a.Position - camera).Magnitude < (b.Position - camera).Magnitude
	end)

	local touching = {}
	for _, part in candidates do
		if touchesWater(part) then
			table.insert(touching, part)
			if #touching >= MAX_FOAM_PARTS then
				break
			end
		end
	end
	Spectral.SetAutoFoam(touching, Settings.Get("ContactFoamWidth"), Settings.Get("ContactFoamOpacity"))
end

local function step(dt: number)
	if suspended or not Settings.Get("ContactFoam") or not Spectral.Rendering() then
		if sinceScan ~= math.huge then
			Spectral.SetAutoFoam({}, 0, 0)
			sinceScan = math.huge
		end
		return
	end
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	sinceScan += dt
	if sinceScan >= SCAN_EVERY then
		sinceScan = 0
		scan(camera.CFrame.Position)
	end
end

--[=[
	@within Contact
	The renderer's adaptive quality switches the foam off while it is saving frames.
]=]
function Contact.SetSuspended(on: boolean)
	suspended = on
end

function Contact.Init(into: Instance)
	if connection then
		return
	end
	parent = into
	connection = RunService.PreRender:Connect(step)
end

function Contact.Stop()
	if connection then
		connection:Disconnect()
		connection = nil
	end
	if Spectral.Rendering() then
		Spectral.SetAutoFoam({}, 0, 0)
	end
	parent = nil
	sinceScan = math.huge
end

return Contact
