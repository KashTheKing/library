-- UI Labs story: status pills, one per connection state.
local Root = script.Parent.Parent
local Fusion = require(Root.Packages.Fusion)
local Theme = require(Root.UI.Theme)
local Pill = require(Root.UI.Components.Pill)

return {
	fusion = Fusion,
	controls = { Text = "Bridge connected" },
	story = function(props)
		local scope = Fusion.scoped(Fusion)
		local ui = scope:New "Frame" {
			Parent = props.target,
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Theme.Colors.Background,
			[Fusion.Children] = {
				scope:New "UIListLayout" { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder },
				scope:New "UIPadding" { PaddingTop = UDim.new(0, 16), PaddingLeft = UDim.new(0, 16) },
				Pill(scope, { Text = props.controls.Text, Color = Theme.Colors.Good, LayoutOrder = 1 }),
				Pill(scope, { Text = "Connecting to bridge", Color = Theme.Colors.Warn, LayoutOrder = 2 }),
				Pill(scope, { Text = "Bridge offline", Color = Theme.Colors.Bad, LayoutOrder = 3 }),
			},
		}
		return function()
			Fusion.doCleanup(scope)
			ui:Destroy()
		end
	end,
}
