--!strict
-- Ties the helper into Eclipse Animator's own window, without touching Eclipse's code:
--   * reads the theme colors off Eclipse's UI (the elements Eclipse tags ThemeBg/ThemeTxt/ThemeStrk), so the helper
--     panel matches whatever theme Kash picked;
--   * puts a HELPERS button in Eclipse's top bar, next to RECOVERY and SETTINGS, that opens the helper panel. It is
--     a copy of Eclipse's own bar button, so Eclipse re-themes it with the rest of the bar.
-- Everything here is runtime UI in Studio; nothing is saved into Eclipse or the place.

local EclipseWindow = {}

local TITLE = "Eclipse Animator"
local BUTTON = "EclipseMCPHelperButton"

-- Eclipse theme token -> which property holds its color.
local TOKENS: { [string]: { attr: string, prop: string } } = {
	Top = { attr = "ThemeBg", prop = "BackgroundColor3" },
	Pnl = { attr = "ThemeBg", prop = "BackgroundColor3" },
	TopBtn = { attr = "ThemeBg", prop = "BackgroundColor3" },
	Div = { attr = "ThemeBg", prop = "BackgroundColor3" },
	MenuSel = { attr = "ThemeBg", prop = "BackgroundColor3" },
	Sel = { attr = "ThemeBg", prop = "BackgroundColor3" },
	Txt = { attr = "ThemeTxt", prop = "TextColor3" },
	TopT = { attr = "ThemeTxt", prop = "TextColor3" },
	Strk = { attr = "ThemeStrk", prop = "Color" },
}

-- Eclipse's main window: a plugin widget titled "Eclipse Animator ..." that has the top bar's MenuButtons.
function EclipseWindow.find(service: Instance?): (Instance?, Instance?)
	local ok, children = pcall(function()
		return (service or game:GetService("PluginGuiService")):GetChildren()
	end)
	if not ok then
		return nil, nil
	end
	for _, widget in children do
		if widget:IsA("PluginGui") and string.sub(widget.Title, 1, #TITLE) == TITLE then
			local menu = widget:FindFirstChild("MenuButtons", true)
			if menu then
				return widget, menu
			end
		end
	end
	return nil, nil
end

-- One sample element per token (the first Eclipse tagged with it), skipping our own button.
function EclipseWindow.samples(widget: Instance): { [string]: Instance }
	local found: { [string]: Instance } = {}
	for _, d in widget:GetDescendants() do
		if d:FindFirstAncestor(BUTTON) or d.Name == BUTTON then
			continue
		end
		for token, spec in TOKENS do
			if not found[token] and d:GetAttribute(spec.attr) == token then
				found[token] = d
			end
		end
	end
	return found
end

local function read(samples: { [string]: Instance }, token: string): Color3?
	local inst = samples[token]
	if not inst or not inst.Parent then
		return nil
	end
	local ok, value = pcall(function()
		return (inst :: any)[TOKENS[token].prop]
	end)
	return if ok and typeof(value) == "Color3" then value else nil
end

-- Eclipse tokens -> the panel's palette. TopT is drawn 40% faded in Eclipse, so it is mixed toward the bar color.
function EclipseWindow.palette(samples: { [string]: Instance }, defaults: { [string]: Color3 }): { [string]: Color3 }
	local top = read(samples, "Top") or defaults.Background
	local topT = read(samples, "TopT")
	return {
		Background = top,
		Surface = read(samples, "Pnl") or defaults.Surface,
		SurfaceLight = read(samples, "TopBtn") or defaults.SurfaceLight,
		Accent = read(samples, "Sel") or read(samples, "MenuSel") or defaults.Accent,
		Text = read(samples, "Txt") or defaults.Text,
		TextDim = if topT then topT:Lerp(top, 0.4) else defaults.TextDim,
		Stroke = read(samples, "Strk") or defaults.Stroke,
		Divider = read(samples, "Div") or defaults.Divider,
	}
end

local function same(a: { [string]: Color3 }?, b: { [string]: Color3 }): boolean
	if not a then
		return false
	end
	local prev = a :: { [string]: Color3 }
	for k, v in b do
		local w = prev[k]
		if not w or math.abs(w.R - v.R) + math.abs(w.G - v.G) + math.abs(w.B - v.B) > 1e-3 then
			return false
		end
	end
	return true
end

-- Copies Eclipse's RECOVERY (or SETTINGS) button into the bar as HELPERS. Returns the new button, or nil.
function EclipseWindow.inject(menu: Instance, onClick: () -> ()): TextButton?
	local existing = menu:FindFirstChild(BUTTON)
	if existing then
		return existing :: TextButton
	end
	local found = menu:FindFirstChild("RecoveryButton") or menu:FindFirstChild("SettingsButton")
	if not found or not found:IsA("TextButton") then
		return nil
	end
	local template = found :: TextButton
	local button = template:Clone()
	for _, d in button:GetDescendants() do
		if d:IsA("LuaSourceContainer") then
			d:Destroy()
		end
	end
	button.Name = BUTTON
	button.Archivable = false
	button.LayoutOrder = template.LayoutOrder - 1
	local label = button:FindFirstChildWhichIsA("TextLabel")
	if label then
		label.Text = "HELPERS"
		label.Size = UDim2.fromOffset(75, label.Size.Y.Offset)
	end
	local stroke = button:FindFirstChild("HoverStroke")
	if stroke and stroke:IsA("UIStroke") then
		stroke.Transparency = 1
	end
	-- pcall: the button still appears where GUI events don't exist (the Lune tests).
	pcall(function()
		if stroke and stroke:IsA("UIStroke") then
			button.MouseEnter:Connect(function()
				stroke.Transparency = 0
			end)
			button.MouseLeave:Connect(function()
				stroke.Transparency = 1
			end)
		end
		button.Activated:Connect(onClick)
	end)
	button.Parent = menu
	return button
end

export type Watch = { stop: () -> (), setOpen: (open: boolean) -> () }

-- Keeps the theme and the bar button up to date: Eclipse can be opened, closed, rebuilt or re-themed any time.
function EclipseWindow.watch(options: {
	defaults: { [string]: Color3 },
	onPalette: ({ [string]: Color3 }) -> (),
	onClick: () -> (),
	service: Instance?,
	interval: number?,
}): Watch
	local alive = true
	local open = false
	local widget: Instance?, samples: { [string]: Instance } = nil, {}
	local button: TextButton? = nil
	local last: { [string]: Color3 }? = nil
	local scannedAt = -math.huge

	local function paintButton()
		local b = button
		if b and b.Parent and last then
			-- While the panel is open the button shows Eclipse's "selected" color, like its other toggles.
			b:SetAttribute("ThemeBg", if open then "Sel" else "TopBtn")
			b.BackgroundColor3 = if open then last.Accent else last.SurfaceLight
		end
	end

	local function step()
		local w, menu = EclipseWindow.find(options.service)
		if w ~= widget or os.clock() - scannedAt > 10 then
			widget, samples, scannedAt = w, if w then EclipseWindow.samples(w :: Instance) else {}, os.clock()
		end
		if not w or not menu then
			button = nil
			return
		end
		local palette = EclipseWindow.palette(samples, options.defaults)
		if not same(last, palette) then
			last = palette
			options.onPalette(palette)
		end
		if not button or button.Parent ~= menu then
			button = EclipseWindow.inject(menu :: Instance, options.onClick)
		end
		paintButton()
	end

	task.spawn(function()
		while alive do
			pcall(step)
			task.wait(options.interval or 1)
		end
	end)

	return {
		stop = function()
			alive = false
			local b = button
			if b then
				b:Destroy()
			end
			button = nil
		end,
		setOpen = function(isOpen: boolean)
			open = isOpen
			pcall(paintButton)
		end,
	}
end

return EclipseWindow
