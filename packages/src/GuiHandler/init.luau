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

--[=[
	@class GuiHandler
	@client

	Gives each `ScreenGui` a handler that shows and hides it with a tween instead of a hard
	`Enabled` toggle. A handler owns a **main container** (the top-level frame of the gui) and an
	animation config that says what the container's properties should be when shown, what they
	should be when hidden, and which `TweenInfo` to use for each direction. By default the
	container tweens between the centre of the screen (`UDim2.fromScale(0.5, 0.5)`) and a position
	above the screen (`UDim2.fromScale(0.5, -0.5)`) over 0.25 seconds.

	`Show` enables the gui and tweens the container to its shown properties; `Hide` tweens the
	container to its hidden properties and then disables the gui. Both accept an `instant` flag
	that sets the properties immediately instead of tweening, and both fire the `Shown` / `Hidden`
	/ `Toggled` signals so other scripts can react. Every handler is registered in a module-level
	list, so `ShowAll`, `HideAll`, `GetGuiHandler` and `WaitForGuiHandler` let any client script
	work with guis it did not create.

	`GetOffScreenPosition` computes a scale position just outside a given edge of the screen for a
	`GuiObject`, which makes it easy to build slide-in/slide-out configs with
	`newAnimationConfig`.

	The module requires the client and errors when required on the server. It returns a table with
	the functions listed on this page plus `new` (the constructor), `DefaultAnimationConfig`,
	`GuiHandlers` and `GuiHandlerAdded`.

	```lua
	local Players = game:GetService("Players")
	local GuiHandler = require(path.to.GuiHandler)

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local shopGui = playerGui:WaitForChild("Shop") :: ScreenGui
	local shopFrame = shopGui:WaitForChild("Main") :: Frame

	-- Slide the shop in from the right and hide it again by sliding out to the right
	local config = GuiHandler.newAnimationConfig({
		ShowProperties = { Position = UDim2.fromScale(0.5, 0.5) },
		HideProperties = { Position = GuiHandler.GetOffScreenPosition(shopFrame, Vector2.new(1, 0)) },
		ShowTweenInfo = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		HideTweenInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
	} :: any)

	-- Start hidden; toggling ShopGui.Enabled from elsewhere will animate too
	local shop = GuiHandler.new(shopGui, shopFrame, false, true, config)

	shop.Toggled:Connect(function(isShowing)
		print("Shop is now", isShowing and "open" or "closed")
	end)

	local openButton = playerGui:WaitForChild("Hud"):WaitForChild("OpenShop") :: TextButton
	openButton.Activated:Connect(function()
		if shop.IsShowing then
			shop:Hide()
		else
			shop:Show()
		end
	end)
	```

	**Credits:** [Trove](https://sleitnick.github.io/RbxUtil/api/Trove/) and [Signal](https://sleitnick.github.io/RbxUtil/api/Signal/) are by [sleitnick](https://github.com/Sleitnick) ([sleitnick's RbxUtil](https://sleitnick.github.io/RbxUtil/)). Wally installs both.

	Installation and guide: [GuiHandler package page](/docs/packages/gui-handler).
]=]
local GuiHandler = {}
GuiHandler.__index = GuiHandler

local DEFAULT_ANIMATION_CONFIG = {
	ShowProperties = {Position = UDim2.fromScale(0.5, 0.5)},
	HideProperties = {Position = UDim2.fromScale(0.5, -0.5)},
	ShowTweenInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut),
	HideTweenInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut),
}

--[=[
	@interface GuiAnimationConfig
	@within GuiHandler
	.ShowProperties { [string]: any } -- Property values applied to the main container when showing (tween target, or set directly when instant). Default `{ Position = UDim2.fromScale(0.5, 0.5) }`.
	.HideProperties { [string]: any } -- Property values applied to the main container when hiding. Default `{ Position = UDim2.fromScale(0.5, -0.5) }`, just above the top of the screen.
	.ShowTweenInfo TweenInfo -- `TweenInfo` used for the show tween. Default `TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut)`.
	.HideTweenInfo TweenInfo -- `TweenInfo` used for the hide tween. Default `TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut)`.

	Describes how a handler animates its main container. The property tables are passed straight
	to `TweenService:Create`, so any tweenable property of the container works (`Position`, `Size`,
	`BackgroundTransparency`, `Rotation`, ...). Build one with `newAnimationConfig` to fall back to
	the defaults for fields you leave out, or read `DefaultAnimationConfig` for the stock values.
]=]
export type GuiAnimationConfig = typeof(DEFAULT_ANIMATION_CONFIG)

--[=[
	@prop Gui ScreenGui
	@within GuiHandler
	@readonly
	The `ScreenGui` this handler manages. `Show` sets its `Enabled` to `true` before animating and
	`Hide` sets it to `false` after animating.
]=]

--[=[
	@prop IsShowing boolean
	@within GuiHandler
	@readonly
	Whether the handler considers the gui shown. Initialised from `Gui.Enabled` in `new`, set to
	`true` at the start of `Show` and `false` at the start of `Hide` (before the tween plays).
	`Show`/`Hide` are no-ops when this already matches.
]=]

--[=[
	@prop AnimationConfig GuiAnimationConfig
	@within GuiHandler
	The config used by `Animate`. Defaults to `DefaultAnimationConfig`; replace it with
	`SetAnimationConfig`.
]=]

--[=[
	@prop MainContainer GuiObject?
	@within GuiHandler
	@readonly
	The `GuiObject` that is tweened. `new` requires one, but if it is ever missing `Animate` warns
	and skips the animation (the gui is still enabled/disabled).
]=]

--[=[
	@prop Trove Trove
	@within GuiHandler
	@readonly
	The [Trove](https://sleitnick.github.io/RbxUtil/api/Trove/) holding the handler's tweens and the
	`Enabled` listener. It is attached to `Gui` and `MainContainer`, so destroying either cleans it.
	`Destroy` cleans it as well.
]=]

--[=[
	@prop Shown Signal<>
	@within GuiHandler
	@readonly
	Fires after `Show` has finished (after the show tween completes, or immediately when instant).
]=]

--[=[
	@prop Hidden Signal<>
	@within GuiHandler
	@readonly
	Fires after `Hide` has finished and the gui has been disabled.
]=]

--[=[
	@prop Toggled Signal<boolean>
	@within GuiHandler
	@readonly
	Fires with `true` whenever `Shown` fires and `false` whenever `Hidden` fires, so you can watch
	both transitions with one connection.
]=]

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

--[=[
	Calls `Show(instant)` on every registered handler, one after another in registration order.
	Because an animated `Show` waits for its tween to finish, the guis appear sequentially and this
	function yields until the last one is done; pass `instant = true` to show everything at once
	without yielding.

	@function ShowAll
	@within GuiHandler
	@yields
	@param instant true? -- Skip the tweens and snap every gui to its shown state.
]=]
-- Shows every registered Gui using their GuiHandlers
-- @param instant if true, skips tweening/animation and shows instantly
function Interface.ShowAll(instant: true?)
	for _, v in GuiHandlers do
		local handler = v :: GuiHandler
		handler:Show(instant)
	end
end

--[=[
	Calls `Hide(instant)` on every registered handler, one after another in registration order.
	Animated hides run sequentially and this function yields until the last tween completes; pass
	`instant = true` to hide everything immediately without yielding. Handy for cutscenes or a
	"hide HUD" setting.

	@function HideAll
	@within GuiHandler
	@yields
	@param instant true? -- Skip the tweens and snap every gui to its hidden state.
]=]
-- Hides every registered Gui using their GuiHandlers
-- @param instant if true, skips tweening/animation and hides instantly
function Interface.HideAll(instant: true?)
	for _, v in GuiHandlers do
		local handler = v :: GuiHandler
		handler:Hide(instant)
	end
end

--[=[
	Returns the handler registered for `gui`, yielding until one is created with `new` if it does
	not exist yet. Use this from scripts that run before the script that constructs the handler.
	There is no timeout: if no handler is ever created for that gui, the call never returns.

	```lua
	local hud = GuiHandler.WaitForGuiHandler(playerGui:WaitForChild("Hud"))
	hud:Hide()
	```

	@function WaitForGuiHandler
	@within GuiHandler
	@yields
	@param gui ScreenGui -- The gui whose handler you want.
	@return GuiHandler -- The handler for `gui`.
]=]
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

--[=[
	Returns the handler registered for `gui`, or `nil` if none has been created (or it has been
	destroyed). Does not yield; use `WaitForGuiHandler` if the handler may not exist yet.

	@function GetGuiHandler
	@within GuiHandler
	@param gui ScreenGui -- The gui to look up.
	@return GuiHandler? -- The handler for `gui`, if one is registered.
]=]
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

--[=[
	Computes a `UDim2` (scale only) that places `guiObject` fully outside the screen on the side
	given by `direction`, taking the object's `Size` scale and `AnchorPoint` into account. The
	direction is normalised and each axis rounded to -1, 0 or 1, so `Vector2.new(-1, 0)` means off
	the left edge, `Vector2.new(0, 1)` off the bottom, and `Vector2.new(1, 1)` off the bottom-right
	corner. An axis whose direction is 0 keeps the object's current position scale.

	The result is meant to be used as the `Position` in a `HideProperties` (or `ShowProperties`)
	table for slide-in/slide-out animations. Only the `Scale` components of `Size` and `Position`
	are considered; pixel offsets are ignored.

	```lua
	local offLeft = GuiHandler.GetOffScreenPosition(frame, Vector2.new(-1, 0))
	```

	:::note
	`offset` is validated but not applied in the current version; the returned position is the same
	with or without it.
	:::

	@function GetOffScreenPosition
	@within GuiHandler
	@param guiObject GuiObject -- The object to position; its `Size`, `Position` and `AnchorPoint` are read.
	@param direction Vector2 -- Which way to push the object off screen; normalised and rounded per axis.
	@param offset Vector2? -- Reserved for extra scale distance; currently unused.
	@return UDim2 -- Scale position just outside the chosen edge(s) of the screen.
	@error "Parameter passed is not a valid GuiObject" -- `guiObject` is not a `GuiObject`.
	@error "direction must be a Vector2" -- `direction` is not a Vector2.
	@error "offset must be a Vector2 or nil" -- `offset` is given but is not a Vector2.
]=]
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

--[=[
	Builds a complete `GuiAnimationConfig` from a partial one: every field that is `nil` in
	`config` is filled with the value from `DefaultAnimationConfig`. Returns a new table; the
	argument is not modified. Pass the result to `new` or `SetAnimationConfig`.

	The parameter is typed as a full `GuiAnimationConfig`, so under `--!strict` you may need to
	cast a partial table (`{ ... } :: any`) when omitting fields.

	```lua
	local config = GuiHandler.newAnimationConfig({
		HideProperties = { Position = UDim2.fromScale(0.5, 1.5) }, -- slide out the bottom
	} :: any)
	```

	@function newAnimationConfig
	@within GuiHandler
	@param config GuiAnimationConfig -- Fields to override; missing fields use the defaults.
	@return GuiAnimationConfig -- A new config with every field set.
]=]
function Interface.newAnimationConfig(config: GuiAnimationConfig)
	local newConfig: GuiAnimationConfig = {
		ShowProperties = config.ShowProperties or DEFAULT_ANIMATION_CONFIG.ShowProperties,
		HideProperties = config.HideProperties or DEFAULT_ANIMATION_CONFIG.HideProperties,
		HideTweenInfo = config.HideTweenInfo or DEFAULT_ANIMATION_CONFIG.HideTweenInfo,
		ShowTweenInfo = config.ShowTweenInfo or DEFAULT_ANIMATION_CONFIG.ShowTweenInfo,
	}
	
	return newConfig
end

--[=[
	Creates a handler for `Gui`, registers it so `GetGuiHandler` / `WaitForGuiHandler` / `ShowAll`
	/ `HideAll` can find it, and fires `GuiHandlerAdded`. Exposed on the module as
	`GuiHandler.new`.

	- `IsShowing` starts as `Gui.Enabled`.
	- `ShowByDefault`: `true` calls `Show(true)` and `false` calls `Hide(true)` right away (both
	  instant); `nil` leaves the gui as it is. Note that `Show`/`Hide` are no-ops when `IsShowing`
	  already matches, so the container is only snapped into place when the state actually changes.
	- `RunAutomatically`: when `true`, changing `Gui.Enabled` from anywhere (another script, the
	  Studio explorer) triggers an animated `Show`/`Hide` to match. This lets you drive the gui with
	  the plain `Enabled` property and still get tweens.
	- The handler's Trove is attached to both `Gui` and `MainContainer`, so destroying either
	  cleans up the tweens and listener. Call `Destroy` to also remove the handler from the
	  registry.

	@function new
	@within GuiHandler
	@param Gui ScreenGui -- The gui to manage.
	@param MainContainer GuiObject -- The frame that is tweened; required despite being stored as optional.
	@param ShowByDefault boolean? -- `true` to show instantly, `false` to hide instantly, `nil` to leave as is.
	@param RunAutomatically boolean? -- Animate whenever `Gui.Enabled` changes externally.
	@param AnimationConfig GuiAnimationConfig? -- Animation config; defaults to `DefaultAnimationConfig`.
	@return GuiHandler -- The registered handler.
	@error "Invalid gui parameter, must be ScreenGui" -- `Gui` is not a `ScreenGui`.
	@error "Invalid MainContainer parameter, must be GuiObject" -- `MainContainer` is not a `GuiObject`.
]=]
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

--[=[
	Replaces the handler's `AnimationConfig`. Takes effect on the next `Show`/`Hide`; a tween that is
	already playing is not affected. Use `newAnimationConfig` to build a config that falls back to
	the defaults.

	@method SetAnimationConfig
	@within GuiHandler
	@param newConfig GuiAnimationConfig -- The config to use from now on.
]=]
function GuiHandler.SetAnimationConfig(self: GuiHandler, newConfig: GuiAnimationConfig)
	self.AnimationConfig = newConfig
end

--[=[
	Applies the shown or hidden properties to `MainContainer`. `Show` and `Hide` call this for you;
	call it directly only when you want to replay the animation without changing `IsShowing` or
	`Gui.Enabled`.

	- Does nothing while `Gui.Enabled` is `false` (a disabled gui cannot be animated).
	- Warns and does nothing if there is no `MainContainer` or no `AnimationConfig`.
	- With `instant`, each property in `ShowProperties`/`HideProperties` is assigned directly (a
	  failed assignment is warned about, not raised).
	- Otherwise a tween is created with the matching `TweenInfo`, added to the Trove, played, and
	  this method **yields until the tween completes**.

	@method Animate
	@within GuiHandler
	@yields
	@param showing boolean -- `true` to apply `ShowProperties`, `false` to apply `HideProperties`.
	@param instant true? -- Set the properties immediately instead of tweening.
]=]
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

--[=[
	Shows the gui: sets `IsShowing` to `true`, enables `Gui`, runs `Animate(true, instant)` to move
	the container to its shown properties, then fires `Shown` (and therefore `Toggled(true)`).
	Does nothing if `IsShowing` is already `true`.

	When not instant this yields for the duration of `ShowTweenInfo` before `Shown` fires.

	@method Show
	@within GuiHandler
	@yields
	@param instant true? -- Snap to the shown properties instead of tweening.
]=]
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

--[=[
	Hides the gui: sets `IsShowing` to `false`, runs `Animate(false, instant)` to move the container
	to its hidden properties, disables `Gui` once that is done, then fires `Hidden` (and therefore
	`Toggled(false)`). Does nothing if `IsShowing` is already `false`.

	When not instant this yields for the duration of `HideTweenInfo` before the gui is disabled and
	`Hidden` fires.

	@method Hide
	@within GuiHandler
	@yields
	@param instant true? -- Snap to the hidden properties instead of tweening.
]=]
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

--[=[
	Unregisters the handler (so `GetGuiHandler`, `ShowAll` and `HideAll` no longer see it) and
	cleans its Trove, cancelling in-flight tweens and disconnecting the `RunAutomatically`
	listener. The `ScreenGui` itself is not destroyed or hidden, and the handler's signals are not
	destroyed.

	@method Destroy
	@within GuiHandler
]=]
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

--[=[
	@prop DefaultAnimationConfig GuiAnimationConfig
	@within GuiHandler
	@readonly
	@tag Module
	Available on the module table (`GuiHandler.DefaultAnimationConfig`). The config used when `new`
	is given no `AnimationConfig` and the source of fallback values for `newAnimationConfig`: tween
	`Position` between `UDim2.fromScale(0.5, 0.5)` and `UDim2.fromScale(0.5, -0.5)` over 0.25 s with
	`Quint`/`InOut` easing. Do not mutate it; build your own with `newAnimationConfig`.
]=]
Interface.DefaultAnimationConfig = DEFAULT_ANIMATION_CONFIG

--[=[
	@prop GuiHandlers { GuiHandler }
	@within GuiHandler
	@readonly
	@tag Module
	Available on the module table (`GuiHandler.GuiHandlers`). The live registry of every handler
	created with `new` and not yet destroyed, in creation order. Iterate it to inspect all guis; do
	not insert or remove entries yourself.
]=]
Interface.GuiHandlers = GuiHandlers

--[=[
	@prop GuiHandlerAdded Signal<GuiHandler>
	@within GuiHandler
	@readonly
	@tag Module
	Available on the module table (`GuiHandler.GuiHandlerAdded`). Fires with the new handler at the
	end of every `new` call. `WaitForGuiHandler` is built on it.
]=]
Interface.GuiHandlerAdded = GuiHandlerAdded

return Interface