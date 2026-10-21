-- UI Labs story: helper rows. Click Stop/Resume; the row flips.
local Root = script.Parent.Parent
local Fusion = require(Root.Packages.Fusion)
local Theme = require(Root.UI.Theme)
local HelperRow = require(Root.UI.Components.HelperRow)
local Mock = require(script.Parent.Mock)

return {
	fusion = Fusion,
	controls = { Name = "Claude", Status = "SetKeyframe Head @12", Tracks = 2 },
	story = function(props)
		local scope = Fusion.scoped(Fusion)
		local stopped = scope:Value(false)
		local agent = scope:Computed(function(use)
			return {
				id = "a1",
				name = use(props.controls.Name),
				color = "#FF8A3D",
				status = use(props.controls.Status),
				stopped = use(stopped),
			}
		end)
		local ui = scope:New "Frame" {
			Parent = props.target,
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Theme.get("Background"),
			[Fusion.Children] = {
				scope:New "UIListLayout" { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder },
				scope:New "UIPadding" { PaddingTop = UDim.new(0, 16), PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 16) },
				HelperRow(scope, {
					Agent = agent,
					Tracks = props.controls.Tracks,
					LayoutOrder = 1,
					OnStop = function()
						stopped:set(true)
					end,
					OnResume = function()
						stopped:set(false)
					end,
				}),
				HelperRow(scope, { Agent = Mock.Agents[3], Tracks = 1, LayoutOrder = 2, OnStop = function() end, OnResume = function() end }),
				HelperRow(scope, { Agent = Mock.Agents[4], Tracks = 0, LayoutOrder = 3, OnStop = function() end, OnResume = function() end }),
			},
		}
		return function()
			Fusion.doCleanup(scope)
			ui:Destroy()
		end
	end,
}
