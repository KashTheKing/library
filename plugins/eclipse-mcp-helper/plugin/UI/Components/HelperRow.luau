--!strict
-- One helper in the list: its color, name, what it is doing, how many tracks it holds, and a Stop/Resume button.

local Root = script.Parent.Parent.Parent
local Fusion = require(Root.Packages.Fusion)
local Theme = require(Root.UI.Theme)
local Button = require(Root.UI.Components.Button)

local Children = Fusion.Children
type UsedAs<T> = Fusion.UsedAs<T>

export type Agent = { id: string, name: string, color: string, kind: string?, status: string?, stopped: boolean? }

export type Props = {
	Agent: UsedAs<Agent>,
	Tracks: UsedAs<number>,
	LayoutOrder: UsedAs<number>?,
	OnStop: (id: string) -> (),
	OnResume: (id: string) -> (),
}

local function HelperRow(scope: Fusion.Scope<typeof(Fusion)>, props: Props): Frame
	local agent = props.Agent
	return (scope:New "Frame" {
		Name = "HelperRow",
		Size = UDim2.new(1, 0, 0, Theme.RowHeight),
		BackgroundColor3 = Theme.get("SurfaceLight"),
		LayoutOrder = props.LayoutOrder,
		[Children] = {
			scope:New "UICorner" { CornerRadius = Theme.Corner },
			scope:New "UIPadding" { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 8) },
			scope:New "Frame" {
				Name = "Swatch",
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.fromScale(0, 0.5),
				Size = UDim2.fromOffset(12, 12),
				BackgroundColor3 = scope:Computed(function(use)
					return Theme.hex(use(agent).color)
				end),
				[Children] = scope:New "UICorner" { CornerRadius = UDim.new(1, 0) },
			},
			scope:New "TextLabel" {
				Name = "Name",
				Position = UDim2.fromOffset(22, 3),
				Size = UDim2.new(1, -110, 0, 18),
				BackgroundTransparency = 1,
				FontFace = Theme.FontBold,
				TextSize = Theme.TextSize.Body,
				TextColor3 = Theme.get("Text"),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Text = scope:Computed(function(use)
					local a: Agent = use(agent)
					return a.name .. (if a.kind == "webhook" then "  (webhook)" else "")
				end),
			},
			scope:New "TextLabel" {
				Name = "Status",
				Position = UDim2.fromOffset(22, 21),
				Size = UDim2.new(1, -110, 0, 15),
				BackgroundTransparency = 1,
				FontFace = Theme.Font,
				TextSize = Theme.TextSize.Small,
				TextColor3 = Theme.get("TextDim"),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Text = scope:Computed(function(use)
					local a = use(agent)
					local tracks = use(props.Tracks)
					local status = if a.stopped then "stopped by you" else (a.status or "idle")
					return status .. (if tracks > 0 then "  ·  holds " .. tracks .. (if tracks == 1 then " track" else " tracks") else "")
				end),
			},
			scope:New "Frame" {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.fromScale(1, 0.5),
				Size = UDim2.fromOffset(80, 26),
				BackgroundTransparency = 1,
				[Children] = {
					scope:New "UIListLayout" { HorizontalAlignment = Enum.HorizontalAlignment.Right },
					Button(scope, {
						Text = scope:Computed(function(use)
							return if use(agent).stopped then "Resume" else "Stop"
						end),
						Accent = scope:Computed(function(use)
							return use(agent).stopped == true
						end),
						OnClick = function()
							local a = Fusion.peek(agent)
							if a.stopped then
								props.OnResume(a.id)
							else
								props.OnStop(a.id)
							end
						end,
					}),
				},
			},
		},
	}) :: any
end

return HelperRow
