--!strict

--Services
local RunService = game:GetService("RunService")

--Dependencies
local Timer = require(script.Parent.Timer)
local Trove = require(script.Parent.Trove)

--Dependency Types
local ExTypes = require(script.ExternalTypes)

export type Trove = ExTypes.Trove

--[=[
	@class Hitbox

	Hitbox provides a way to create invisible detection parts that scan for overlapping parts
	or humanoids using `Workspace:GetPartsInPart`. It supports welding, duration-based scanning,
	and conditional callbacks for part and humanoid detection.

	You can create a Hitbox with `Hitbox.new`, or use helper constructors like `Hitbox.fromPart` or `Hitbox.fromModel`.
]=]
local Hitbox = {}
Hitbox.__index = Hitbox

--Types
type HitboxProperties = {
	Trove: Trove,
	HitboxPart: Part,
	HitboxParams: OverlapParams,
	Weld: WeldConstraint?,
}

export type Hitbox = typeof(setmetatable({} :: HitboxProperties, Hitbox))

--Signal/Connection types
type ConnectionLike = {
	Connected: boolean,
	Disconnect: (self: ConnectionLike) -> (),
}

type SignalLike = {
	Connect: (self: SignalLike, callback: (...any) -> ...any) -> ConnectionLike,
	Once: (self: SignalLike, callback: (...any) -> ...any) -> ConnectionLike,
}

--Predicate Types
type PredicateFunc = (BasePart) -> boolean
type DisconnectPredicateFunc = () -> boolean

--Callback Types
type BasePartCallback = (BasePart) -> ()
type HumanoidCallback = (Humanoid) -> ()

--[[
	@private
]]
local function weldPart(part0: BasePart, part1: BasePart): WeldConstraint
	part1.Anchored = false

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = part0
	weld.Part1 = part1
	weld.Name = part1.Name
	weld.Parent = part0

	return weld
end

--[[
	@private
]]
local function wrapCheck(self: Hitbox, predicate: PredicateFunc?, callback: BasePartCallback)
	return function()
		local parts = self:Check(predicate)
		for _, part in parts do
			task.spawn(callback, part)
		end
	end
end

--[[
	@private
]]
local function wrapCheckHumanoids(self: Hitbox, callback: HumanoidCallback)
	return function()
		local humanoids = self:CheckHumanoids()
		for _, humanoid in humanoids do
			task.spawn(callback, humanoid)
		end
	end
end

--[[
	@private
]]
local function wrapTimeCheck(startTime: number, diff: number)
	return function()
		local isLessThanDiff = math.clamp(os.clock() - startTime, 0, math.huge) < diff
		return isLessThanDiff
	end
end

--[[
	@private
]]
local function createHitboxPart(
	cframe: CFrame,
	size: Vector3,
	shape: Enum.PartType,
	parent: Instance?,
	visible: boolean?
): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CastShadow = false
	part.Massless = true
	
	part.CFrame = cframe
	part.Size = size
	part.Shape = shape
	part.Color = Color3.new(1, 0, 0)
	part.Transparency = visible and 0.5 or 1
	part.Parent = parent or game

	return part
end

--[=[
	@within Hitbox
	@function new
	@tag Constructor
	@param cframe CFrame -- Position of the hitbox part
	@param size Vector3 -- Size of the hitbox part
	@param shape Enum.PartType -- Shape of the hitbox part
	@param hitboxParams OverlapParams -- Overlap parameters for detection
	@param parent Instance? -- Optional parent to assign the hitbox part to
	@param visible boolean? -- Whether to show the part visibly
	@param weldTo BasePart? -- Optionally weld to another part
	@return Hitbox
	Creates a new hitbox part from shape and position data
]=]
function Hitbox.new(
	cframe: CFrame,
	size: Vector3,
	shape: Enum.PartType,
	hitboxParams: OverlapParams,
	parent: Instance?,
	visible: boolean?,
	weldTo: BasePart?
): Hitbox
	assert(typeof(cframe) == "CFrame", "CFrame must be a CFrame")
	assert(typeof(size) == "Vector3", "Size must be a Vector3")
	assert(typeof(shape) == "EnumItem", "Shape must be an Enum.PartType item")
	assert(typeof(hitboxParams) == "OverlapParams", "HitboxParams must be an OverlapParams")

	local trove = (Trove.new() :: any) :: Trove

	local properties: HitboxProperties = {
		Trove = trove,
		HitboxParams = hitboxParams,
		HitboxPart = createHitboxPart(cframe, size, shape, parent, visible),
	}

	trove:Add(properties.HitboxPart)
	trove:AttachToInstance(properties.HitboxPart)

	local self: Hitbox = setmetatable(properties, Hitbox)

	if weldTo then
		self:WeldTo(weldTo)
	end

	return self
end

--[=[
	@within Hitbox
	@method fromPart
	@param part BasePart -- The part to use as reference
	@param hitboxParams OverlapParams
	@param parent Instance?
	@param visible boolean?
	@param weldTo BasePart?
	@return Hitbox
	Creates a hitbox using the size and shape of an existing BasePart.
]=]
function Hitbox.fromPart(part: BasePart, hitboxParams: OverlapParams, parent: Instance?, visible: boolean?, weldTo: BasePart?): Hitbox
	local shape = part:IsA("Part") and part.Shape or Enum.PartType.Block
	return Hitbox.new(part.CFrame, part.Size, shape, hitboxParams, parent, visible, weldTo)
end

--[=[
	@within Hitbox
	@method fromModel
	@param model Model
	@param hitboxParams OverlapParams
	@param parent Instance?
	@param visible boolean?
	@param weldTo BasePart?
	@return Hitbox
	Creates a hitbox using the size and position of a model's bounding box.
]=]
function Hitbox.fromModel(model: Model, hitboxParams: OverlapParams, parent: Instance?, visible: boolean?, weldTo: BasePart?): Hitbox
	local cframe = model:GetBoundingBox()
	local size = model:GetExtentsSize()
	local shape = Enum.PartType.Block
	return Hitbox.new(cframe, size, shape, hitboxParams, parent, visible, weldTo)
end

--[=[
	@within Hitbox
	@method convert
	@param instanceToConvert Model | BasePart
	@param hitboxParams OverlapParams
	@param parent Instance?
	@param visible boolean?
	@param weldTo BasePart?
	@return Hitbox
	Converts a model or part into a hitbox and destroys the original part.
]=]
function Hitbox.convert(instanceToConvert: Model | BasePart, hitboxParams: OverlapParams, parent: Instance?, visible: boolean?, weldTo: BasePart?): Hitbox
	local self: Hitbox
	
	if instanceToConvert:IsA("BasePart") then
		self = Hitbox.fromPart(instanceToConvert, hitboxParams, parent, visible, weldTo)
	elseif instanceToConvert:IsA("Model") then
		self = Hitbox.fromModel(instanceToConvert, hitboxParams, parent, visible, weldTo)
	else
		error(`Unable to convert class {instanceToConvert.ClassName} to hitbox, must be Class Model or BasePart`, 2)
	end
	
	instanceToConvert:Destroy()
	
	return self
end

--[=[
	@within Hitbox
	@method Check
	@param predicate ((BasePart) -> boolean)?
	@return {BasePart}
	Returns parts inside the hitbox, optionally filtering with a predicate.
]=]
function Hitbox.Check(self: Hitbox, predicate: PredicateFunc?): {BasePart}
	local parts = workspace:GetPartsInPart(self.HitboxPart, self.HitboxParams)

	if predicate then
		for index, part in pairs(parts) do
			local noError, result = pcall(predicate, part)
			if not noError or not result then
				table.remove(parts, index)
			end
		end
	end

	return parts
end

--[=[
	@within Hitbox
	@method CheckHumanoids
	@return {Humanoid}
	Returns all humanoids inside the hitbox that are alive.
]=]
function Hitbox.CheckHumanoids(self: Hitbox): {Humanoid}
	local humanoids = {}
	local parts = self:Check()
	
	for _, part in pairs(parts) do
		local model = part:FindFirstAncestorWhichIsA("Model")
		if model then
			local humanoid = model:FindFirstChildWhichIsA("Humanoid", true)
			if humanoid and humanoid.Health > 0 then
				table.insert(humanoids, humanoid)
			end
		end
	end

	return humanoids
end

--[=[
	@within Hitbox
	@method ScanWithEvent
	@param interval number | SignalLike
	@param callback (BasePart) -> ()
	@param predicate ((BasePart) -> boolean)?
	@param disconnectPredicate (() -> boolean)?
	@return ConnectionLike
	Continuously scans with an event or interval.
]=]
function Hitbox.ScanWithEvent(self: Hitbox, interval: (number | SignalLike), callback: BasePartCallback, predicate: PredicateFunc?, disconnectPredicate: DisconnectPredicateFunc?): ConnectionLike
	local checkFunc = wrapCheck(self, predicate, callback)

	local connection: ConnectionLike

	local function check()
		if disconnectPredicate and not disconnectPredicate() then
			connection:Disconnect()
		else
			checkFunc()
		end
	end

	if type(interval) == "number" then
		local scanTimer = self.Trove:Construct(Timer, interval)
		connection = scanTimer.Tick:Connect(check)
		scanTimer:Start()
	else
		connection = self.Trove:Connect(interval, check)
	end

	return connection
end

--[=[
	@within Hitbox
	@method Scan
	@param duration number -- How long the hitbox should scan for
	@param callback (BasePart) -> () -- Callback when a part is found
	@param predicate ((BasePart) -> boolean)? -- Optional filter
	@return ConnectionLike
	Scans for parts for a given duration and runs a callback.
]=]
function Hitbox.Scan(self: Hitbox, duration: number, callback: BasePartCallback, predicate: PredicateFunc?): ConnectionLike
	local timeCheckPredicate = wrapTimeCheck(os.clock(), duration)
	return self:ScanWithEvent(RunService.Heartbeat, callback, predicate, timeCheckPredicate)
end

--[=[
	@within Hitbox
	@method ScanHumanoidsWithEvent
	@param interval number | SignalLike
	@param callback (Humanoid) -> ()
	@param disconnectPredicate (() -> boolean)?
	@return ConnectionLike
	Continuously scans for humanoids using an interval or event.
]=]
function Hitbox.ScanHumanoidsWithEvent(self: Hitbox, interval: (number | SignalLike), callback: HumanoidCallback, disconnectPredicate: DisconnectPredicateFunc?): ConnectionLike
	local checkFunc = wrapCheckHumanoids(self, callback)

	local connection: ConnectionLike

	local function check()
		if disconnectPredicate and not disconnectPredicate() then
			connection:Disconnect()
		else
			checkFunc()
		end
	end

	if type(interval) == "number" then
		local scanTimer = self.Trove:Construct(Timer, interval)
		connection = scanTimer.Tick:Connect(check)
		scanTimer:Start()
	else
		connection = self.Trove:Connect(interval, check)
	end

	return connection
end

--[=[
	@within Hitbox
	@method ScanHumanoids
	@param duration number
	@param callback (Humanoid) -> ()
	@return ConnectionLike
	Scans for humanoids for a given duration and runs a callback.
]=]
function Hitbox.ScanHumanoids(self: Hitbox, duration: number, callback: HumanoidCallback): ConnectionLike
	local timeCheckPredicate = wrapTimeCheck(os.clock(), duration)
	return self:ScanHumanoidsWithEvent(RunService.Heartbeat, callback, timeCheckPredicate)
end

--[=[
	@within Hitbox
	@method WeldTo
	@param part BasePart
	Welds the hitbox part to the given part. Replaces previous weld if it exists.
]=]
function Hitbox.WeldTo(self: Hitbox, part: BasePart)
	if self.Weld then
		self.Weld:Destroy()
	end

	local weld = self.Trove:Add(
		weldPart(part, self.HitboxPart)
	)
	
	self.Weld = weld
end

--[=[
	@within Hitbox
	@method Destroy
	Cleans up the hitbox and destroys the internal Trove and part.
]=]
function Hitbox.Destroy(self: Hitbox)
	self.Trove:Destroy()
end

return Hitbox