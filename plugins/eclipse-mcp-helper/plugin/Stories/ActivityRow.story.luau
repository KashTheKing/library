-- UI Labs story: the activity feed lines (joins, edits, a conflict, a claim).
local Root = script.Parent.Parent
local Fusion = require(Root.Packages.Fusion)
local Theme = require(Root.UI.Theme)
local ActivityRow = require(Root.UI.Components.ActivityRow)
local Mock = require(script.Parent.Mock)

return {
	fusion = Fusion,
	story = function(props)
		local scope = Fusion.scoped(Fusion)
		local rows = {}
		for i, event in Mock.Activity do
			table.insert(rows, ActivityRow(scope, { Event = event, LayoutOrder = i }))
		end
		local ui = scope:New "Frame" {
			Parent = props.target,
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Theme.Colors.Surface,
			[Fusion.Children] = {
				scope:New "UIListLayout" { SortOrder = Enum.SortOrder.LayoutOrder },
				scope:New "UIPadding" { PaddingTop = UDim.new(0, 12), PaddingLeft = UDim.new(0, 12) },
				rows,
			},
		}
		return function()
			Fusion.doCleanup(scope)
			ui:Destroy()
		end
	end,
}
