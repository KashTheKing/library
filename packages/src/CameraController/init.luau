--!strict
local RunService = game:GetService("RunService")
assert(RunService:IsClient(), "CameraController is only for the client")

--Dependencies
local Trove = require(script.Parent.Trove)

--Dependency Types
local ExTypes = require(script.ExternalTypes)
export type Trove = ExTypes.Trove

--Camera Controller
local Current: CameraController? = nil

local PRIORITY = Enum.RenderPriority.Input.Value

--[=[
	@class CameraController
	@client

	A small object-oriented wrapper around a custom camera loop. A CameraController holds an
	update function that runs once per frame while the controller is active (bound with
	`RunService:BindToRenderStep` at `Enum.RenderPriority.Input` priority) and an optional reset
	function that puts the camera back the way you want it when the controller is cleaned up.
	Only one controller can be active at a time; the module tracks it so other scripts can find it
	with `GetCurrent` or tear it down with `DestroyCurrent`.

	Everything is tracked with a [Trove](https://sleitnick.github.io/RbxUtil/api/Trove/) that is
	attached to `workspace.CurrentCamera`, so a controller is destroyed automatically if the camera
	it drives is destroyed.

	The module requires the client and errors when required on the server. It returns a table with
	`new`, `GetCurrent` and `DestroyCurrent`; methods are called on the object returned by `new`.

	```lua
	local Players = game:GetService("Players")
	local CameraController = require(path.to.CameraController)

	local player = Players.LocalPlayer
	local character = player.Character or player.CharacterAdded:Wait()
	local root = character:WaitForChild("HumanoidRootPart") :: BasePart

	-- Top-down camera that follows the character
	local controller = CameraController.new(function(camera, dt)
		camera.CameraType = Enum.CameraType.Scriptable
		local target = root.Position
		camera.CFrame = CFrame.lookAt(target + Vector3.new(0, 40, 20), target)
	end, function(camera)
		-- Runs when the controller is cleaned up: hand control back to Roblox
		camera.CameraType = Enum.CameraType.Custom
	end)

	controller:Start()

	-- Later, from anywhere on the client:
	CameraController.DestroyCurrent()
	```

	:::caution Lifecycle
	`Start` calls `Stop` first, and `Stop` cleans the whole Trove. The bookkeeping hook that `new`
	registers (which calls `ResetFunc`, resets `Active` and clears the current controller) is part
	of that Trove, so it runs during `Start`, before the update loop begins, and is not re-added.
	After a `Start`, a later `Stop` or `Destroy` only unbinds the update function: `ResetFunc` is
	not called again and `Active` stays `true`. When you are finished with a controller, prefer
	`CameraController.DestroyCurrent()` (which also clears the tracked controller so a new one can
	be started) and create a fresh controller with `new` rather than restarting the same object.
	:::

	**Credits:** cleanup is handled by [Trove](https://sleitnick.github.io/RbxUtil/api/Trove/), by [sleitnick](https://github.com/Sleitnick) ([sleitnick's RbxUtil](https://sleitnick.github.io/RbxUtil/)). Wally installs it.

	Installation and guide: [CameraController package page](/docs/packages/camera-controller).
]=]
local CameraController = {}
CameraController.__index = CameraController

--[=[
	@type UpdateFunc (camera: Camera, dt: number) -> ()
	@within CameraController
	Runs every frame while the controller is active, at `Enum.RenderPriority.Input` priority (before
	Roblox's own camera scripts). Receives the controller's `Camera` and the frame delta time. Set
	it in `new` or with `SetUpdate`.
]=]
export type UpdateFunc = (camera: Camera, dt: number)->()

--[=[
	@type ResetFunc (camera: Camera) -> ()
	@within CameraController
	Runs when the controller's Trove is cleaned (see the class description for exactly when that
	happens). Use it to restore `CameraType`, field of view or anything else the update function
	changed. Set it in `new` or with `SetReset`.
]=]
export type ResetFunc = (camera: Camera)->()

--[=[
	@prop Camera Camera
	@within CameraController
	@readonly
	The camera this controller drives: `workspace.CurrentCamera` at the time `new` was called. It is
	passed to `UpdateFunc` and `ResetFunc`. The Trove is attached to it, so destroying the camera
	destroys the controller.
]=]

--[=[
	@prop Trove Trove
	@within CameraController
	@readonly
	The [Trove](https://sleitnick.github.io/RbxUtil/api/Trove/) holding the render-step binding and
	the controller's cleanup hook. `Stop` cleans it, `Destroy` destroys it. You may add your own
	objects (connections, instances) so they are released together with the controller.
]=]

--[=[
	@prop Active boolean
	@within CameraController
	@readonly
	`true` once `Start` has bound the update function. `Start` errors while this is `true`.
]=]

--[=[
	@prop Locked boolean
	@within CameraController
	@readonly
	`true` between `Lock` and `Unlock`. While locked, `SetUpdate` and `SetReset` error instead of
	replacing the functions.
]=]

--[=[
	@prop UpdateFunc UpdateFunc?
	@within CameraController
	The per-frame function. `nil` until set by `new` or `SetUpdate`; `Start` errors if it is `nil`.
]=]

--[=[
	@prop ResetFunc ResetFunc?
	@within CameraController
	The optional reset function called when the controller's Trove is cleaned.
]=]

export type CameraControllerProperties = {
	Camera: Camera,
	Trove: Trove,
	Active: boolean,
	Locked: boolean,
	ResetFunc: ResetFunc?,
	UpdateFunc: UpdateFunc?,
}

export type CameraController = typeof(setmetatable({} :: CameraControllerProperties, CameraController))

--[=[
	Creates a controller for `workspace.CurrentCamera`. Nothing runs until you call `Start`.

	Both functions are optional here and can be supplied later with `SetUpdate` / `SetReset`, but
	`Start` requires an update function. The constructor also registers a cleanup hook in the
	controller's Trove that calls `resetFunc`, resets `Active` and clears the current controller
	when the Trove is cleaned, and attaches the Trove to the camera so the controller is destroyed
	with it.

	@function new
	@within CameraController
	@param updateFunc UpdateFunc? -- Function to run every frame while active.
	@param resetFunc ResetFunc? -- Function to run when the controller is cleaned up.
	@return CameraController -- The new, inactive controller.
]=]
--Creates a new CameraController object
function CameraController.new(updateFunc: UpdateFunc?, resetFunc: ResetFunc?)
	local properties: CameraControllerProperties = {
		Camera = workspace.CurrentCamera,
		Trove = (Trove.new() :: any) :: Trove,
		Active = false,
		Locked = false,
		ResetFunc = resetFunc,
		UpdateFunc = updateFunc,
	}

	local self = setmetatable(properties, CameraController)

	--This prevents GetCurrent from malfunctioning and self.Active
	self.Trove:Add(function()		
		if self.Active == true then
			self.Active = false
		end

		if Current == self then
			Current = nil
		end

		if self.ResetFunc and self.Camera then
			self.ResetFunc(self.Camera)
		end
	end)

	--This prevents errors that can occur when the current camera is destroyed
	self.Trove:AttachToInstance(self.Camera)

	return self
end

--[=[
	Returns a shallow copy of this controller made with `table.clone`. The copy has the same
	metatable and starts with the same `UpdateFunc`, `ResetFunc`, `Active` and `Locked` values, but
	it **shares** the original's `Trove` and `Camera`: stopping or destroying either object cleans
	the shared Trove. Treat it as a way to derive a variant with a different update function via
	`SetUpdate`, not as an independent controller.

	@method Construct
	@within CameraController
	@return CameraController -- A shallow clone of this controller.
]=]
--Clones the given CameraController
function CameraController.Construct(self: CameraController)
	return table.clone(self)
end

--[=[
	Cleans the controller's Trove. This unbinds the render-step update added by `Start`, so the
	update function stops running, and releases anything else you added to the Trove. `Start`
	calls this itself before binding, which is when the cleanup hook from `new` (and therefore
	`ResetFunc`) runs; see the class description for the consequences.

	@method Stop
	@within CameraController
]=]
--Stops the CameraController
function CameraController.Stop(self: CameraController)
	self.Trove:Clean()
end

--[=[
	Replaces the per-frame update function. Takes effect on the next frame if the controller is
	already active, since the bound render step reads `UpdateFunc` each frame.

	@method SetUpdate
	@within CameraController
	@param updateFunc UpdateFunc -- The new per-frame function.
	@error "CameraController is locked" -- `Lock` was called and `Unlock` has not been.
]=]
--Sets the render step function of the CameraController
function CameraController.SetUpdate(self: CameraController, updateFunc: UpdateFunc)
	if self.Locked then
		error("CameraController is locked", 2)
	end

	self.UpdateFunc = updateFunc
end

--[=[
	Replaces the reset function that the Trove cleanup hook calls with the controller's camera.

	@method SetReset
	@within CameraController
	@param resetFunc ResetFunc -- The new reset function.
	@error "CameraController is locked" -- `Lock` was called and `Unlock` has not been.
]=]
--Sets the reset function of the CameraController that runs when the CameraController is stopped
function CameraController.SetReset(self: CameraController, resetFunc: (camera: Camera)->())
	if self.Locked then
		error("CameraController is locked", 2)
	end

	self.ResetFunc = resetFunc
end

--[=[
	Activates the controller. After validating that an update function is set and that neither
	this nor any other controller is active, it calls `Stop` (cleaning the Trove), binds the update
	function with `Trove:BindToRenderStep("CameraController", Enum.RenderPriority.Input.Value, ...)`,
	sets `Active` to `true` and makes this the controller returned by `GetCurrent`.

	Each frame the bound function calls `UpdateFunc(Camera, dt)`; if `UpdateFunc` has somehow
	become `nil` the controller stops itself instead.

	@method Start
	@within CameraController
	@error "There is no update function set in the CameraController" -- `UpdateFunc` is `nil`.
	@error "This CameraController is already active" -- `Active` is already `true`.
	@error "An existing CameraController is already active" -- Another controller is current and active; destroy it (for example with `DestroyCurrent`) first.
]=]
--Starts the CameraController with the set update function
function CameraController.Start(self: CameraController)
	if not self.UpdateFunc then
		error("There is no update function set in the CameraController", 2)
	end

	if self.Active then
		error("This CameraController is already active", 2)
	end

	if Current ~= nil and Current.Active then
		error("An existing CameraController is already active", 2)
	end

	self:Stop()

	self.Trove:BindToRenderStep("CameraController", PRIORITY, function(dt: number)
		if self.UpdateFunc then
			self.UpdateFunc(self.Camera, dt)
		else
			self:Stop()
		end
	end)

	self.Active = true

	Current = self
end

--[=[
	Sets `Locked` to `true`, making `SetUpdate` and `SetReset` error until `Unlock` is called. Use
	it to stop other scripts from hijacking a camera mode (a cutscene, for example) while it runs.
	Locking does not affect `Start`, `Stop` or `Destroy`.

	@method Lock
	@within CameraController
]=]
--Locks the camera controller so the UpdateFunc can't be changed
function CameraController.Lock(self: CameraController)
	self.Locked = true
end

--[=[
	Sets `Locked` back to `false` so `SetUpdate` and `SetReset` work again.

	@method Unlock
	@within CameraController
]=]
--Unlocks the camera controller so the UpdateFunc can be changed
function CameraController.Unlock(self: CameraController)
	self.Locked = false
end

--[=[
	Destroys the controller's Trove, unbinding the update function and releasing everything the
	Trove holds. The object should not be used afterwards. Note that this does not clear the
	module's tracked current controller by itself; `DestroyCurrent` does both.

	@method Destroy
	@within CameraController
]=]
--Destroys the CameraController
function CameraController.Destroy(self: CameraController)
	self.Trove:Destroy()
end

--[=[
	Returns the controller most recently activated with `Start`, or `nil` if none has been started
	or the current one was cleared (by its cleanup hook or by `DestroyCurrent`). Lets scripts that
	did not create the controller inspect or destroy it.

	```lua
	local current = CameraController.GetCurrent()
	if current and current.Active then
		print("A custom camera is running")
	end
	```

	@function GetCurrent
	@within CameraController
	@return CameraController? -- The tracked controller, if any.
]=]
--Returns the current active camera controller
local function GetCurrent(): CameraController?
	return Current
end

--[=[
	Destroys the tracked current controller (if there is one) and clears the module's reference to
	it, so a new controller can be started without hitting "An existing CameraController is already
	active". Safe to call when nothing is active. This is the recommended way to end a custom camera
	mode.

	@function DestroyCurrent
	@within CameraController
]=]
--Destroys the current active camera controller if it exists
local function DestroyCurrent()
	if Current ~= nil then
		Current:Destroy()
	end
	
	Current = nil
end

return {
	new = CameraController.new,
	GetCurrent = GetCurrent,
	DestroyCurrent = DestroyCurrent
}