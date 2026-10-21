--!strict
-- A flat Studio-style button. Accent buttons use the blue fill with white text; hover lightens.

local Root = script.Parent.Parent.Parent
local Fusion = require(Root.Packages.Fusion)
local Theme = require(Root.UI.Theme)

local Children, OnEvent = Fusion.Children, Fusion.OnEvent
type UsedAs<T> = Fusion.UsedAs<T>

export type Props = {
	Text: UsedAs<string>,
	Accent: UsedAs<boolean>?,
	Size: UsedAs<UDim2>?,
	LayoutOrder: UsedAs<number>?,
	OnClick: () -> (),
}

local function Button(scope: Fusion.Scope<typeof(Fusion)>, props: Props): TextButton
	local hovering = scope:Value(false)
	local accent: UsedAs<boolean> = props.Accent or false
	return (scope:New "TextButton" {
		Name = "Button",
		AutoButtonColor = false,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = props.Size or UDim2.fromOffset(0, 26),
		LayoutOrder = props.LayoutOrder,
		FontFace = Theme.Font,
		TextSize = Theme.TextSize.Small,
		TextColor3 = Theme.Colors.Text,
		Text = props.Text,
		BackgroundColor3 = scope:Spring(
			scope:Computed(function(use)
				local base = if use(accent) then Theme.Colors.Accent else Theme.Colors.SurfaceLight
				return if use(hovering) then Theme.lighten(base, 0.12) else base
			end),
			40,
			1
		),
		[OnEvent "MouseEnter"] = function()
			hovering:set(true)
		end,
		[OnEvent "MouseLeave"] = function()
			hovering:set(false)
		end,
		[OnEvent "Activated"] = props.OnClick,
		[Children] = {
			scope:New "UICorner" { CornerRadius = Theme.Corner },
			scope:New "UIPadding" { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) },
		},
	}) :: any
end

return Button
