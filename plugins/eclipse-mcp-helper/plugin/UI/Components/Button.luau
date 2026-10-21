--!strict
-- A button in Eclipse's style: bold monospace capitals on its button color, outlined on hover. Accent = selected.

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
		FontFace = Theme.FontBold,
		TextSize = Theme.TextSize.Small,
		TextColor3 = Theme.get("Text"),
		Text = scope:Computed(function(use)
			return string.upper(use(props.Text))
		end),
		BackgroundColor3 = scope:Spring(
			scope:Computed(function(use)
				local base = if use(accent) then use(Theme.get("Accent")) else use(Theme.get("SurfaceLight"))
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
			scope:New "UIStroke" {
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				Color = Theme.get("Stroke"),
				Transparency = scope:Computed(function(use)
					return if use(hovering) then 0 else 1
				end),
			},
			scope:New "UIPadding" { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) },
		},
	}) :: any
end

return Button
