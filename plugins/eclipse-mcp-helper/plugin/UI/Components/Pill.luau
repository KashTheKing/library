--!strict
-- A small rounded status label with a colored dot.

local Root = script.Parent.Parent.Parent
local Fusion = require(Root.Packages.Fusion)
local Theme = require(Root.UI.Theme)

local Children = Fusion.Children
type UsedAs<T> = Fusion.UsedAs<T>

export type Props = {
	Text: UsedAs<string>,
	Color: UsedAs<Color3>,
	LayoutOrder: UsedAs<number>?,
}

local function Pill(scope: Fusion.Scope<typeof(Fusion)>, props: Props): Frame
	return (scope:New "Frame" {
		Name = "Pill",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 24),
		BackgroundColor3 = Theme.Colors.SurfaceLight,
		LayoutOrder = props.LayoutOrder,
		[Children] = {
			scope:New "UICorner" { CornerRadius = UDim.new(1, 0) },
			scope:New "UIPadding" { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 10) },
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, 6),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			scope:New "Frame" {
				Name = "Dot",
				Size = UDim2.fromOffset(8, 8),
				BackgroundColor3 = props.Color,
				[Children] = scope:New "UICorner" { CornerRadius = UDim.new(1, 0) },
			},
			scope:New "TextLabel" {
				LayoutOrder = 2,
				AutomaticSize = Enum.AutomaticSize.X,
				Size = UDim2.fromScale(0, 1),
				BackgroundTransparency = 1,
				FontFace = Theme.Font,
				TextSize = Theme.TextSize.Small,
				TextColor3 = Theme.Colors.Text,
				Text = props.Text,
			},
		},
	}) :: any
end

return Pill
