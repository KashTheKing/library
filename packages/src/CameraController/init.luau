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

local CameraController = {}
CameraController.__index = CameraController

export type UpdateFunc = (camera: Camera, dt: number)->()
export type ResetFunc = (camera: Camera)->()

export type CameraControllerProperties = {
	Camera: Camera,
	Trove: Trove,
	Active: boolean,
	Locked: boolean,
	ResetFunc: ResetFunc?,
	UpdateFunc: UpdateFunc?,
}

export type CameraController = typeof(setmetatable({} :: CameraControllerProperties, CameraController))

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

--Clones the given CameraController
function CameraController.Construct(self: CameraController)
	return table.clone(self)
end

--Stops the CameraController
function CameraController.Stop(self: CameraController)
	self.Trove:Clean()
end

--Sets the render step function of the CameraController
function CameraController.SetUpdate(self: CameraController, updateFunc: UpdateFunc)
	if self.Locked then
		error("CameraController is locked", 2)
	end

	self.UpdateFunc = updateFunc
end

--Sets the reset function of the CameraController that runs when the CameraController is stopped
function CameraController.SetReset(self: CameraController, resetFunc: (camera: Camera)->())
	if self.Locked then
		error("CameraController is locked", 2)
	end

	self.ResetFunc = resetFunc
end

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

--Locks the camera controller so the UpdateFunc can't be changed
function CameraController.Lock(self: CameraController)
	self.Locked = true
end

--Unlocks the camera controller so the UpdateFunc can be changed
function CameraController.Unlock(self: CameraController)
	self.Locked = false
end

--Destroys the CameraController
function CameraController.Destroy(self: CameraController)
	self.Trove:Destroy()
end

--Returns the current active camera controller
local function GetCurrent(): CameraController?
	return Current
end

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