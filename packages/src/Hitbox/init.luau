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

	Hitbox wraps an invisible, non-colliding `Part` and uses `Workspace:GetPartsInPart` to find
	what is overlapping it. Use it for melee swings, area-of-effect abilities, trigger zones or
	anything else where you want to know which parts or humanoids are inside a volume right now,
	or for a period of time.

	A Hitbox can be queried once (`Check`, `CheckHumanoids`), scanned for a fixed duration on
	`Heartbeat` (`Scan`, `ScanHumanoids`) or scanned on your own schedule using a repeat interval
	or any signal (`ScanWithEvent`, `ScanHumanoidsWithEvent`). The hitbox part can be welded to
	another part so it follows a character or weapon. Everything the hitbox creates (the part,
	welds, timers and connections) is tracked by a [Trove](https://sleitnick.github.io/RbxUtil/api/Trove/)
	and released by `Destroy`; destroying the hitbox part also destroys the hitbox.

	Create one with `Hitbox.new`, or from existing geometry with `Hitbox.fromPart`,
	`Hitbox.fromModel` or `Hitbox.convert`.

	```lua
	local Hitbox = require(path.to.Hitbox)

	local function swing(character: Model)
		local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { character }

		-- A 4x4x4 block one stud in front of the character, welded to the root so it follows them
		local hitbox = Hitbox.new(
			rootPart.CFrame * CFrame.new(0, 0, -3),
			Vector3.new(4, 4, 4),
			Enum.PartType.Block,
			params,
			workspace,
			false,
			rootPart
		)

		-- Scan every frame for half a second and damage each humanoid once
		local alreadyHit: { [Humanoid]: boolean } = {}
		hitbox:ScanHumanoids(0.5, function(humanoid)
			if alreadyHit[humanoid] then
				return
			end
			alreadyHit[humanoid] = true
			humanoid:TakeDamage(10)
		end)

		task.delay(0.5, function()
			hitbox:Destroy()
		end)
	end
	```

	**Credits:** [Trove](https://sleitnick.github.io/RbxUtil/api/Trove/) and [Timer](https://sleitnick.github.io/RbxUtil/api/Timer/) are by [sleitnick](https://github.com/Sleitnick) ([sleitnick's RbxUtil](https://sleitnick.github.io/RbxUtil/)). Wally installs both.

	Installation and guide: [Hitbox package page](/docs/packages/hitbox).
]=]
local Hitbox = {}
Hitbox.__index = Hitbox

--[=[
	@prop Trove Trove
	@within Hitbox
	@readonly
	The [Trove](https://sleitnick.github.io/RbxUtil/api/Trove/) that owns everything the hitbox
	creates: the hitbox part, the weld, scan timers and scan connections. `Destroy` destroys it.
	You can add your own objects to it so they are cleaned up with the hitbox.
]=]

--[=[
	@prop HitboxPart Part
	@within Hitbox
	@readonly
	The physical part used for `Workspace:GetPartsInPart`. It is anchored (until welded), has
	`CanCollide`, `CastShadow` off and `Massless` on. Move it with `CFrame`/`PivotTo` if you want to
	reposition an unwelded hitbox. The Trove is attached to this instance, so destroying the part
	destroys the hitbox.
]=]

--[=[
	@prop HitboxParams OverlapParams
	@within Hitbox
	The `OverlapParams` passed to every `GetPartsInPart` call. Change its filter list at any time
	to include or exclude instances from future checks.
]=]

--[=[
	@prop Weld WeldConstraint?
	@within Hitbox
	@readonly
	The `WeldConstraint` created by `WeldTo`, or `nil` if the hitbox is not welded to anything.
	It is parented to the part the hitbox was welded to.
]=]

--Types
type HitboxProperties = {
	Trove: Trove,
	HitboxPart: Part,
	HitboxParams: OverlapParams,
	Weld: WeldConstraint?,
}

export type Hitbox = typeof(setmetatable({} :: HitboxProperties, Hitbox))

--Signal/Connection types
--[=[
	@interface ConnectionLike
	@within Hitbox
	.Connected boolean -- Whether the connection is still active.
	.Disconnect (self: ConnectionLike) -> () -- Stops the scan this connection belongs to.

	The object returned by every `Scan*` method. It is the connection returned by the signal (or
	internal Timer) that drives the scan; call `Disconnect` to stop scanning early. The hitbox's
	Trove also disconnects it when the hitbox is destroyed.
]=]
type ConnectionLike = {
	Connected: boolean,
	Disconnect: (self: ConnectionLike) -> (),
}

--[=[
	@interface SignalLike
	@within Hitbox
	.Connect (self: SignalLike, callback: (...any) -> ...any) -> ConnectionLike -- Connects a callback and returns its connection.
	.Once (self: SignalLike, callback: (...any) -> ...any) -> ConnectionLike -- Connects a callback that runs once.

	Anything with a `Connect` method can drive a scan: `RBXScriptSignal`s such as
	`RunService.Heartbeat`, or custom signals like sleitnick's Signal. The arguments the signal
	fires with are ignored; each firing simply triggers one check.
]=]
type SignalLike = {
	Connect: (self: SignalLike, callback: (...any) -> ...any) -> ConnectionLike,
	Once: (self: SignalLike, callback: (...any) -> ...any) -> ConnectionLike,
}

--Predicate Types
--[=[
	@type PredicateFunc (part: BasePart) -> boolean
	@within Hitbox
	Filter applied to each overlapping part. Return `true` to keep the part. The predicate is
	called inside `pcall`, so a part is also dropped if the predicate errors.
]=]
type PredicateFunc = (BasePart) -> boolean

--[=[
	@type DisconnectPredicateFunc () -> boolean
	@within Hitbox
	Called before every check of an event-driven scan. Return `true` to keep scanning; returning
	`false` disconnects the scan instead of performing that check. `Scan` and `ScanHumanoids` use
	one of these internally to stop after their duration.
]=]
type DisconnectPredicateFunc = () -> boolean

--Callback Types
--[=[
	@type BasePartCallback (part: BasePart) -> ()
	@within Hitbox
	Receives one overlapping part. Called in its own thread (`task.spawn`) for every part found on
	every check, so a part that stays inside the hitbox is reported once per check.
]=]
type BasePartCallback = (BasePart) -> ()

--[=[
	@type HumanoidCallback (humanoid: Humanoid) -> ()
	@within Hitbox
	Receives one living humanoid. Called in its own thread (`task.spawn`) for every humanoid found
	on every check, so the same humanoid is reported repeatedly while it stays inside the hitbox.
]=]
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
	Creates a hitbox by building a new part from a position, size and shape.

	The part is anchored, non-colliding, massless and casts no shadow. When `visible` is true it is
	drawn as a red, half-transparent part (handy while tuning a hitbox); otherwise it is fully
	invisible. When `weldTo` is given, `WeldTo` is called immediately so the hitbox part follows
	that part and keeps the offset described by `cframe`.

	:::caution
	`parent` defaults to `game` (the DataModel) when omitted. Pass `workspace` or a folder inside
	it so the part is actually in the world.
	:::

	@function new
	@within Hitbox
	@tag Constructor
	@param cframe CFrame -- World position and rotation of the hitbox part.
	@param size Vector3 -- Size of the hitbox part in studs.
	@param shape Enum.PartType -- Shape of the hitbox part (`Block`, `Ball`, `Cylinder`, ...).
	@param hitboxParams OverlapParams -- Filter used for every `GetPartsInPart` query; stored as `HitboxParams`.
	@param parent Instance? -- Where to parent the hitbox part; defaults to `game`.
	@param visible boolean? -- Show the part as red and half transparent instead of invisible.
	@param weldTo BasePart? -- If given, the hitbox part is welded to this part right away.
	@return Hitbox -- The new hitbox.
	@error "CFrame must be a CFrame" -- `cframe` is not a CFrame.
	@error "Size must be a Vector3" -- `size` is not a Vector3.
	@error "Shape must be an Enum.PartType item" -- `shape` is not an EnumItem.
	@error "HitboxParams must be an OverlapParams" -- `hitboxParams` is not an OverlapParams.
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
	Creates a hitbox that copies the `CFrame`, `Size` and shape of an existing part. The shape is
	only copied when `part` is a `Part`; other `BasePart`s (meshes, unions, wedges) produce a
	`Block`. The original part is left untouched; use `convert` if you want it removed.

	The `parent`, `visible` and `weldTo` arguments behave exactly as in `new`.

	@function fromPart
	@within Hitbox
	@tag Constructor
	@param part BasePart -- Part whose position, size and shape are copied.
	@param hitboxParams OverlapParams -- Filter used for every `GetPartsInPart` query.
	@param parent Instance? -- Where to parent the hitbox part; defaults to `game`.
	@param visible boolean? -- Show the part as red and half transparent instead of invisible.
	@param weldTo BasePart? -- If given, the hitbox part is welded to this part right away.
	@return Hitbox -- The new hitbox.
]=]
function Hitbox.fromPart(part: BasePart, hitboxParams: OverlapParams, parent: Instance?, visible: boolean?, weldTo: BasePart?): Hitbox
	local shape = part:IsA("Part") and part.Shape or Enum.PartType.Block
	return Hitbox.new(part.CFrame, part.Size, shape, hitboxParams, parent, visible, weldTo)
end

--[=[
	Creates a `Block` hitbox that covers a model's bounding box, using `Model:GetBoundingBox()`
	for the CFrame and `Model:GetExtentsSize()` for the size. The model itself is left untouched;
	use `convert` if you want it removed.

	The `parent`, `visible` and `weldTo` arguments behave exactly as in `new`.

	@function fromModel
	@within Hitbox
	@tag Constructor
	@param model Model -- Model whose bounding box defines the hitbox.
	@param hitboxParams OverlapParams -- Filter used for every `GetPartsInPart` query.
	@param parent Instance? -- Where to parent the hitbox part; defaults to `game`.
	@param visible boolean? -- Show the part as red and half transparent instead of invisible.
	@param weldTo BasePart? -- If given, the hitbox part is welded to this part right away.
	@return Hitbox -- The new hitbox.
]=]
function Hitbox.fromModel(model: Model, hitboxParams: OverlapParams, parent: Instance?, visible: boolean?, weldTo: BasePart?): Hitbox
	local cframe = model:GetBoundingBox()
	local size = model:GetExtentsSize()
	local shape = Enum.PartType.Block
	return Hitbox.new(cframe, size, shape, hitboxParams, parent, visible, weldTo)
end

--[=[
	Replaces a placeholder part or model with a hitbox. Behaves like `fromPart` for a `BasePart`
	and `fromModel` for a `Model`, then **destroys the original instance**. Useful when you lay
	out hitbox volumes in Studio and want them swapped for real hitboxes at runtime.

	The `parent`, `visible` and `weldTo` arguments behave exactly as in `new`.

	@function convert
	@within Hitbox
	@tag Constructor
	@param instanceToConvert Model | BasePart -- The part or model to turn into a hitbox; it is destroyed afterwards.
	@param hitboxParams OverlapParams -- Filter used for every `GetPartsInPart` query.
	@param parent Instance? -- Where to parent the hitbox part; defaults to `game`.
	@param visible boolean? -- Show the part as red and half transparent instead of invisible.
	@param weldTo BasePart? -- If given, the hitbox part is welded to this part right away.
	@return Hitbox -- The new hitbox.
	@error "Unable to convert class ..." -- `instanceToConvert` is neither a `BasePart` nor a `Model`.
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
	Performs one `Workspace:GetPartsInPart(HitboxPart, HitboxParams)` query and returns the
	overlapping parts. When a `predicate` is given, only parts it returns `true` for are kept; the
	predicate is wrapped in `pcall`, so a part is also dropped if the predicate errors.

	This is the raw building block. Use `CheckHumanoids` when you care about characters rather
	than individual parts, and the `Scan*` methods to run checks repeatedly.

	```lua
	local parts = hitbox:Check(function(part)
		return part:HasTag("Breakable")
	end)
	```

	@method Check
	@within Hitbox
	@param predicate PredicateFunc? -- Optional filter; return `true` to keep a part.
	@return { BasePart } -- The parts currently inside the hitbox that passed the filter.
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
	Performs one check and resolves the overlapping parts to living humanoids. For each part found
	by `Check`, the nearest `Model` ancestor is looked up and the first `Humanoid` descendant of
	that model with `Health > 0` is collected. Dead humanoids and parts that are not inside a model
	with a humanoid are ignored.

	:::caution
	The list is not de-duplicated: a character with several parts inside the hitbox appears once
	per part. Track humanoids you have already handled if you need one hit per character.
	:::

	@method CheckHumanoids
	@within Hitbox
	@return { Humanoid } -- Living humanoids whose character parts are inside the hitbox.
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
	Repeatedly runs `Check(predicate)` and calls `callback` for every part found, driven either by
	a fixed interval or by a signal:

	- If `interval` is a **number**, a [Timer](https://sleitnick.github.io/RbxUtil/api/Timer/) is
	  constructed inside the hitbox's Trove with that many seconds between ticks, started, and its
	  `Tick` signal drives the checks.
	- If `interval` is a **signal** (`RunService.Heartbeat`, a custom Signal, ...), one check runs
	  every time the signal fires. The signal's arguments are ignored.

	Before each check `disconnectPredicate` is called (if given); when it returns `false` the scan
	disconnects itself instead of checking. `Scan` uses this to stop after a duration. Without a
	disconnect predicate the scan runs until you call `Disconnect` on the returned connection or
	destroy the hitbox.

	Each callback is spawned in its own thread, and a part that stays inside the hitbox is reported
	on every check, so de-duplicate in the callback if you only want to react once per part.

	```lua
	-- Scan every 0.1s while the ability is active
	local connection = hitbox:ScanWithEvent(0.1, function(part)
		print("Touching", part:GetFullName())
	end, nil, function()
		return ability.Active
	end)
	```

	@method ScanWithEvent
	@within Hitbox
	@param interval number | SignalLike -- Seconds between checks, or a signal whose firings trigger checks.
	@param callback BasePartCallback -- Called with each part found on each check.
	@param predicate PredicateFunc? -- Optional filter passed to `Check`.
	@param disconnectPredicate DisconnectPredicateFunc? -- Return `false` to stop the scan before the next check.
	@return ConnectionLike -- Connection driving the scan; `Disconnect` it to stop early.
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
	Scans for parts on every `RunService.Heartbeat` for `duration` seconds, then stops on its own.
	This is `ScanWithEvent(RunService.Heartbeat, callback, predicate, ...)` with a disconnect
	predicate that compares `os.clock()` against the start time. The callback runs for every part
	on every frame it is inside the hitbox.

	Returns immediately; the scan happens in the background. Use `ScanWithEvent` if you need a
	slower interval or a different signal.

	@method Scan
	@within Hitbox
	@param duration number -- How many seconds to keep scanning.
	@param callback BasePartCallback -- Called with each part found on each frame.
	@param predicate PredicateFunc? -- Optional filter passed to `Check`.
	@return ConnectionLike -- Connection driving the scan; `Disconnect` it to stop early.
]=]
function Hitbox.Scan(self: Hitbox, duration: number, callback: BasePartCallback, predicate: PredicateFunc?): ConnectionLike
	local timeCheckPredicate = wrapTimeCheck(os.clock(), duration)
	return self:ScanWithEvent(RunService.Heartbeat, callback, predicate, timeCheckPredicate)
end

--[=[
	Humanoid version of `ScanWithEvent`: repeatedly runs `CheckHumanoids` and calls `callback` for
	every living humanoid found. `interval` is either a number of seconds (an internal Timer is
	created and started in the Trove) or a signal that triggers a check each time it fires.
	`disconnectPredicate` is called before each check and stops the scan when it returns `false`.

	Each callback is spawned in its own thread. Because `CheckHumanoids` does not de-duplicate,
	the same humanoid can be reported several times per check and again on every following check
	while it stays inside the hitbox.

	@method ScanHumanoidsWithEvent
	@within Hitbox
	@param interval number | SignalLike -- Seconds between checks, or a signal whose firings trigger checks.
	@param callback HumanoidCallback -- Called with each living humanoid found on each check.
	@param disconnectPredicate DisconnectPredicateFunc? -- Return `false` to stop the scan before the next check.
	@return ConnectionLike -- Connection driving the scan; `Disconnect` it to stop early.
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
	Scans for living humanoids on every `RunService.Heartbeat` for `duration` seconds, then stops
	on its own. Equivalent to `ScanHumanoidsWithEvent(RunService.Heartbeat, callback, ...)` with a
	time-based disconnect predicate. Returns immediately; the scan runs in the background.

	```lua
	local hit = {}
	hitbox:ScanHumanoids(0.4, function(humanoid)
		if not hit[humanoid] then
			hit[humanoid] = true
			humanoid:TakeDamage(25)
		end
	end)
	```

	@method ScanHumanoids
	@within Hitbox
	@param duration number -- How many seconds to keep scanning.
	@param callback HumanoidCallback -- Called with each living humanoid found on each frame.
	@return ConnectionLike -- Connection driving the scan; `Disconnect` it to stop early.
]=]
function Hitbox.ScanHumanoids(self: Hitbox, duration: number, callback: HumanoidCallback): ConnectionLike
	local timeCheckPredicate = wrapTimeCheck(os.clock(), duration)
	return self:ScanHumanoidsWithEvent(RunService.Heartbeat, callback, timeCheckPredicate)
end

--[=[
	Attaches the hitbox part to `part` with a `WeldConstraint` so it moves with it, keeping the
	current relative offset between the two. The hitbox part is unanchored, and the constraint is
	parented to `part` (named after the hitbox part) and stored in `Weld`. Any previous weld is
	destroyed first, so calling this again re-parents the hitbox to a different part.

	The weld is added to the Trove and removed when the hitbox is destroyed. Position the hitbox
	part where you want it relative to `part` **before** welding.

	@method WeldTo
	@within Hitbox
	@param part BasePart -- The part the hitbox should follow (becomes `Part0` of the weld).
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
	Destroys the hitbox: the Trove is destroyed, which removes the hitbox part and weld, stops any
	running scan timers and disconnects every scan connection. Always call this (or destroy
	`HitboxPart`, which has the same effect) when you are done, otherwise the part and its scans
	keep running.

	@method Destroy
	@within Hitbox
]=]
function Hitbox.Destroy(self: Hitbox)
	self.Trove:Destroy()
end

return Hitbox