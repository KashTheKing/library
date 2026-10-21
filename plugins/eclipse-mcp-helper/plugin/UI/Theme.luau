--!strict
-- Colors, fonts and sizes for the helper panel: Studio's dark greys with one blue accent (never blue text).

local Theme = {}

Theme.Colors = {
	Background = Color3.fromRGB(37, 38, 41),
	Surface = Color3.fromRGB(46, 47, 51),
	SurfaceLight = Color3.fromRGB(60, 62, 67),
	Accent = Color3.fromRGB(51, 95, 255),
	Good = Color3.fromRGB(58, 196, 105),
	Warn = Color3.fromRGB(255, 176, 32),
	Bad = Color3.fromRGB(235, 72, 84),
	Text = Color3.fromRGB(240, 240, 240),
	TextDim = Color3.fromRGB(170, 172, 178),
	Stroke = Color3.fromRGB(26, 27, 29),
}

Theme.Font = Font.new("rbxasset://fonts/families/BuilderSans.json")
Theme.FontBold = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold)
Theme.TextSize = { Small = 13, Body = 15, Title = 18 }
Theme.Corner = UDim.new(0, 6)
Theme.Padding = 8
Theme.RowHeight = 40

function Theme.hex(hex: string): Color3
	local ok, c = pcall(Color3.fromHex, hex)
	return if ok then c else Theme.Colors.Accent
end

function Theme.lighten(color: Color3, amount: number): Color3
	return color:Lerp(Color3.new(1, 1, 1), amount)
end

return Theme
