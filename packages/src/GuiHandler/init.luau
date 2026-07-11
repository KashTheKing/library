--!strict
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

assert(RunService:IsClient(), "Must be on the client to use this")

-- This uses Trove for cleaning up animations/tweens/etc
local Trove = require(script.Parent.Trove)
type Trove = typeof(Trove.new())

-- This uses Signal for a nicer interface
local Signal = require(script.Parent.Signal)
type SignalNoParams = typeof(Signal.new())
type ToggledSignal = typeof(Signal.new())

local GuiHandler = {}
GuiHandler.__index = GuiHandler

local DEFAULT_ANIMATION_CONFIG = {
	ShowProperties = {Position = UDim2.fromScale(0.5, 0.5)},
	HideProperties = {Position = UDim2.fromScale(0.5, -0.5)},
	ShowTweenInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut),
	HideTweenInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut),
}

export type GuiAnimationConfig = typeof(DEFAULT_ANIMATION_CONFIG)

local self = {} :: {
	Gui: ScreenGui,
	IsShowing: boolean,
	AnimationConfig: GuiAnimationConfig,
	MainContainer: GuiObject?,
	Trove: Trove,
	Hidden: SignalNoParams,
	Shown: SignalNoParams,
	Toggled: ToggledSignal,
}

export type GuiHandler = typeof(setmetatable(self, GuiHandler))

-- Internal storage for gui handlers
local GuiHandlerAdded = Signal.new()
local GuiHandlers = {} :: { GuiHandler }

-- Interface exposed to other scripts
local Interface = {}

-- Shows every registered Gui using their GuiHandlers
-- @param instant if true, skips tweening/animation and shows instantly
function Interface.ShowAll(instant: true?)
	for _, v in GuiHandlers do
		local handler = v :: GuiHandler
		handler:Show(instant)
	end
end

-- Hides every registered Gui using their GuiHandlers
-- @param instant if true, skips tweening/animation and hides instantly
function Interface.HideAll(instant: true?)
	for _, v in GuiHandlers do
		local handler = v :: GuiHandler
		handler:Hide(instant)
	end
end

-- Returns a Gui's stored GuiHandler and waits for it to be added if it doesn't exist
-- @param gui the ScreenGui to get the handler for
-- @returns GuiHandler for the given gui
function Interface.WaitForGuiHandler(gui: ScreenGui): GuiHandler
	local existing = Interface.GetGuiHandler(gui)

	if existing then
		return existing :: GuiHandler
	end

	while true do
		local addedHandler = GuiHandlerAdded:Wait()
		if addedHandler.Gui == gui then
			return addedHandler
		end
	end
end

-- Returns a Gui's stored GuiHandler if it exists
-- @param gui the ScreenGui to look up
-- @returns GuiHandler or nil if not found
function Interface.GetGuiHandler(gui: ScreenGui): GuiHandler?
	for _, handler in GuiHandlers do
		if handler.Gui == gui then
			return handler :: GuiHandler
		end
	end

	return nil
end

-- Returns a GuiObject's off screen position in scale based on a given direction (the direction will be normalized)
-- Example: If direction is (-1, 0) the off screen position will be off the left side of the screen
-- @param offset if given, adds extra distance to the off-screen position (in-scale) (useful for UIStrokes)
function Interface.GetOffScreenPosition(guiObject: GuiObject, direction: Vector2, offset: Vector2?): UDim2
	assert(typeof(guiObject) == "Instance" and guiObject:IsA("GuiObject"), "Parameter passed is not a valid GuiObject")
	assert(typeof(direction) == "Vector2", "direction must be a Vector2")
	assert(offset == nil or typeof(offset) == "Vector2", "offset must be a Vector2 or nil")

	local unitDirection = direction.Unit
	
	local roundedDirection = Vector2.new(
		math.round(unitDirection.X),
		math.round(unitDirection.Y)
	)
	
	local anchor = guiObject.AnchorPoint
	
	local size = guiObject.Size
	local xSize = size.X.Scale
	local ySize = size.Y.Scale
	
	local x = guiObject.Position.X.Scale
	local y = guiObject.Position.Y.Scale
	
	if roundedDirection.X < 0 then
		x = 0 - xSize - anchor.X
	elseif roundedDirection.X > 0 then
		x = 1 + xSize + anchor.X
	end

	if roundedDirection.Y < 0 then
		y = 0 - xSize - anchor.Y
	elseif roundedDirection.Y > 0 then
		y = 1 + ySize + anchor.Y
	end
	
	local offscreenPosition = UDim2.fromScale(x, y)
	
	return offscreenPosition
end

function Interface.newAnimationConfig(config: GuiAnimationConfig)
	local newConfig: GuiAnimationConfig = {
		ShowProperties = config.ShowProperties or DEFAULT_ANIMATION_CONFIG.ShowProperties,
		HideProperties = config.HideProperties or DEFAULT_ANIMATION_CONFIG.HideProperties,
		HideTweenInfo = config.HideTweenInfo or DEFAULT_ANIMATION_CONFIG.HideTweenInfo,
		ShowTweenInfo = config.ShowTweenInfo or DEFAULT_ANIMATION_CONFIG.ShowTweenInfo,
	}
	
	return newConfig
end

-- Creates a new GuiHandler and stores it for later access
-- @param Gui the ScreenGui this handler manages
-- @param MainContainer optional container for tweening/animations (not used yet)
-- @param ShowByDefault if true, shows by default; if false, hides; if nil, skips
-- @param RunAutomatically if true, the Gui will run :Show() and :Hide() when the Enabled property is changed
-- @returns GuiHandler object
function GuiHandler.new(Gui: ScreenGui, MainContainer: GuiObject, ShowByDefault: boolean?, RunAutomatically: boolean?, AnimationConfig: GuiAnimationConfig?): GuiHandler
	assert(typeof(Gui) == "Instance" and Gui:IsA("ScreenGui"), "Invalid gui parameter, must be ScreenGui")
	assert(typeof(MainContainer) == "Instance" and MainContainer:IsA("GuiObject"), "Invalid MainContainer parameter, must be GuiObject")

	local self: GuiHandler = setmetatable({
		Gui = Gui,
		IsShowing = Gui.Enabled,
		MainContainer = MainContainer,
		AnimationConfig = AnimationConfig or DEFAULT_ANIMATION_CONFIG,
		Trove = Trove.new(),
		Hidden = Signal.new(),
		Shown = Signal.new(),
		Toggled = Signal.new()
	}, GuiHandler)

	--Connect toggled events to fire when gui is hidden/shown
	self.Hidden:Connect(function()
		self.Toggled:Fire(false)
	end)
	
	self.Shown:Connect(function()
		self.Toggled:Fire(true)
	end)

	--ShowByDefault stuff (to show/hide the gui when the GuiHandler is constructed)
	if ShowByDefault == true then
		self:Show(true)
	elseif ShowByDefault == false then
		self:Hide(true)
	end
	
	if RunAutomatically == true then
		self.Trove:Connect(Gui:GetPropertyChangedSignal("Enabled"), function()
			local enabled = self.Gui.Enabled

			if self.IsShowing == enabled then
				return
			end

			if enabled then
				self:Show()
			else
				self:Hide()
			end
		end)
	end
	
	--This is for easy cleanup if the gui is destroyed while the game is running
	self.Trove:AttachToInstance(Gui)
	
	if MainContainer then
		self.Trove:AttachToInstance(MainContainer)
	end
	
	--Finalize GuiHandler's registration
	table.insert(GuiHandlers, self)
	GuiHandlerAdded:Fire(self)

	return self
end

function GuiHandler.SetAnimationConfig(self: GuiHandler, newConfig: GuiAnimationConfig)
	self.AnimationConfig = newConfig
end

-- Animates the gui in/out using TweenService
-- @param showing if true, animates the gui in; otherwise, animates it out
-- @param instant if true, skips the animations but instantly sets the animation properties
function GuiHandler.Animate(self: GuiHandler, showing: boolean, instant: true?)
	if not self.Gui.Enabled then
		return --Disabled UIs cant be animated
	end
	
	local mainContainer = self.MainContainer
	
	--Skip animation if there isn't a container to animate
	if not mainContainer then
		warn(`"{self.Gui.Name}" gui properties and animations will be skipped because it's missing a main container. Check GuiHandler.new() or use the instant parameter to skip animations.`)
		return
	end
	
	local animationConfig = self.AnimationConfig
	--Skip animation if there isn't an animation config to animate with
	if not animationConfig then
		warn(`"{self.Gui.Name}" gui properties and animations will be skipped because it's missing an animation config.`)
		return
	end

	if instant then
		local properties = if showing then self.AnimationConfig.ShowProperties else self.AnimationConfig.HideProperties
		
		local grabber = mainContainer :: any
		
		for property, value in pairs(properties) do
			local success, err = pcall(function()
				grabber[property] = value
			end)
			
			if not success then
				warn(err)
			end
		end
	else
		if showing then
			-- TODO: Add tweening logic for showing
			local tween = TweenService:Create(mainContainer, animationConfig.ShowTweenInfo, animationConfig.ShowProperties)
			self.Trove:Add(tween)

			tween:Play()

			tween.Completed:Wait()
		else
			-- TODO: Add tweening logic for hiding
			local tween = TweenService:Create(mainContainer, animationConfig.HideTweenInfo, animationConfig.HideProperties)
			self.Trove:Add(tween)
			tween:Play()

			tween.Completed:Wait()
		end
	end
end

-- Shows the gui with an optional parameter to skip effects/tweens/animations
-- @param instant if true, shows the GUI instantly with no animation
function GuiHandler.Show(self: GuiHandler, instant: true?)
	if self.IsShowing then
		return --No need to show gui again if it's already showing
	end
	
	self.IsShowing = true
	
	if instant then
		self.Gui.Enabled = true
		self:Animate(true, true)
	else
		self.Gui.Enabled = true
		self:Animate(true)
	end

	self.Shown:Fire()
end

-- Hides the gui with an optional parameter to skip effects/tweens/animations
-- @param instant if true, hides the GUI instantly with no animation
function GuiHandler.Hide(self: GuiHandler, instant: true?)
	if not self.IsShowing then
		return --No need to hide gui again if it's already hidden
	end
	
	self.IsShowing = false
	
	if instant then
		self:Animate(false, true)
		self.Gui.Enabled = false
	else
		self:Animate(false)
		self.Gui.Enabled = false
	end

	self.Hidden:Fire()
end

-- Cleans up the GuiHandler and removes it from the internal storage
-- @remarks Also cleans up any Trove-managed resources
function GuiHandler.Destroy(self: GuiHandler)
	local index = table.find(GuiHandlers, self)

	if index then
		table.remove(GuiHandlers, index)
	end

	self.Trove:Clean()
end

Interface.new = GuiHandler.new
Interface.DefaultAnimationConfig = DEFAULT_ANIMATION_CONFIG
Interface.GuiHandlers = GuiHandlers
Interface.GuiHandlerAdded = GuiHandlerAdded

return Interface