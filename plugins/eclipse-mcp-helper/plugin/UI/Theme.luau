--!strict
-- Colors, fonts and sizes for the helper panel. The panel wears Eclipse Animator's own theme: EclipseTheme reads the
-- colors off Eclipse's window and sets Theme.Palette, so when Kash changes his Eclipse theme the panel follows.
-- The defaults below are Eclipse's look until the first read (and what UI Labs stories show).

local Root = script.Parent.Parent
local Fusion = require(Root.Packages.Fusion)

local Theme = {}

export type Palette = {
	Background: Color3, -- Eclipse "Top" (bars)
	Surface: Color3, -- Eclipse "Pnl" (panels)
	SurfaceLight: Color3, -- Eclipse "TopBtn" (buttons, rows)
	Accent: Color3, -- Eclipse "Sel" (selected buttons)
	Text: Color3, -- Eclipse "Txt"
	TextDim: Color3, -- Eclipse "TopT" (button labels, 40% faded)
	Stroke: Color3, -- Eclipse "Strk"
	Divider: Color3, -- Eclipse "Div"
}

Theme.Defaults = {
	Background = Color3.fromHex("201c30"),
	Surface = Color3.fromHex("221e31"),
	SurfaceLight = Color3.fromHex("393148"),
	Accent = Color3.fromHex("5e4d81"),
	Text = Color3.fromHex("ece5f3"),
	TextDim = Color3.fromHex("a49db0"),
	Stroke = Color3.fromHex("746080"),
	Divider = Color3.fromHex("665477"),
} :: Palette

-- Status colors stay fixed so green/amber/red always mean the same thing.
Theme.Colors = {
	Good = Color3.fromRGB(58, 196, 105),
	Warn = Color3.fromRGB(255, 176, 32),
	Bad = Color3.fromRGB(235, 72, 84),
}

local scope = Fusion.scoped(Fusion)
Theme.Palette = scope:Value(Theme.Defaults)

local cache: { [string]: Fusion.Computed<Color3> } = {}

-- A live color from the palette, e.g. Theme.get("Text"); use it directly as a property or inside use().
function Theme.get(name: string): Fusion.Computed<Color3>
	local hit = cache[name]
	if not hit then
		hit = scope:Computed(function(use)
			return (use(Theme.Palette) :: any)[name] :: Color3
		end)
		cache[name] = hit
	end
	return hit :: Fusion.Computed<Color3>
end

-- Eclipse's UI font: RobotoMono, labels in bold capitals.
Theme.Font = Font.new("rbxasset://fonts/families/RobotoMono.json")
Theme.FontBold = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Bold)
Theme.TextSize = { Small = 12, Body = 14, Title = 14 }
Theme.Corner = UDim.new(0, 2)
Theme.Padding = 8
Theme.RowHeight = 40

function Theme.hex(hex: string): Color3
	local ok, c = pcall(Color3.fromHex, hex)
	return if ok then c else Theme.Defaults.Accent
end

function Theme.lighten(color: Color3, amount: number): Color3
	return color:Lerp(Color3.new(1, 1, 1), amount)
end

return Theme
