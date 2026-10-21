--!strict
-- The helper panel (a Studio dock widget): bridge and Eclipse status, every helper working with Kash, a live
-- activity feed, and his controls (pause all, show/hide viewport presence, stop one helper).

local Root = script.Parent.Parent
local Fusion = require(Root.Packages.Fusion)
local Theme = require(Root.UI.Theme)
local Pill = require(Root.UI.Components.Pill)
local Button = require(Root.UI.Components.Button)
local HelperRow = require(Root.UI.Components.HelperRow)
local ActivityRow = require(Root.UI.Components.ActivityRow)

local Children = Fusion.Children
type Value<T> = Fusion.Value<T>

export type State = {
	Connection: Value<string>, -- connecting | connected | offline | blocked
	Detail: Value<string?>,
	Eclipse: Value<{ found: boolean, active: boolean, version: number?, frame: number?, fps: number? }>,
	Agents: Value<{ any }>,
	Leases: Value<{ any }>,
	Activity: Value<{ any }>,
	Paused: Value<boolean>,
	ShowPresence: Value<boolean>,
}

export type Props = {
	State: State,
	Parent: Instance?,
	OnPause: (paused: boolean) -> (),
	OnShowPresence: (on: boolean) -> (),
	OnStop: (id: string) -> (),
	OnResume: (id: string) -> (),
}

local CONNECTION: { [string]: { any } } = {
	connecting = { "Connecting to bridge", Theme.Colors.Warn },
	connected = { "Bridge connected", Theme.Colors.Good },
	offline = { "Bridge offline", Theme.Colors.Bad },
	blocked = { "HTTP permission needed", Theme.Colors.Bad },
}

local function heading(scope: Fusion.Scope<typeof(Fusion)>, text: string, order: number)
	return scope:New "TextLabel" {
		Name = text,
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 1,
		FontFace = Theme.FontBold,
		TextSize = Theme.TextSize.Body,
		TextColor3 = Theme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = text,
	}
end

local function App(scope: Fusion.Scope<typeof(Fusion)>, props: Props): Frame
	local s = props.State
	local leaseCounts = scope:Computed(function(use)
		local counts = {}
		for _, l in use(s.Leases) do
			counts[l.agentId] = (counts[l.agentId] or 0) + 1
		end
		return counts
	end)

	return (scope:New "Frame" {
		Name = "EclipseMCPHelper",
		Parent = props.Parent,
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Colors.Background,
		[Children] = {
			scope:New "UIPadding" {
				PaddingTop = UDim.new(0, Theme.Padding),
				PaddingBottom = UDim.new(0, Theme.Padding),
				PaddingLeft = UDim.new(0, Theme.Padding),
				PaddingRight = UDim.new(0, Theme.Padding),
			},
			scope:New "UIListLayout" { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8) },

			scope:New "Frame" {
				Name = "Status",
				LayoutOrder = 1,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.fromScale(1, 0),
				BackgroundTransparency = 1,
				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Wraps = true,
						Padding = UDim.new(0, 6),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					Pill(scope, {
						LayoutOrder = 1,
						Text = scope:Computed(function(use)
							return (CONNECTION[use(s.Connection)] or CONNECTION.offline)[1]
						end),
						Color = scope:Computed(function(use)
							return (CONNECTION[use(s.Connection)] or CONNECTION.offline)[2]
						end),
					}),
					Pill(scope, {
						LayoutOrder = 2,
						Text = scope:Computed(function(use)
							local e = use(s.Eclipse)
							if not e.found then
								return "Eclipse not open"
							elseif not e.active then
								return "Eclipse: open an animation"
							end
							return "Eclipse v" .. tostring(e.version) .. "  ·  frame " .. tostring(e.frame) .. " @ " .. tostring(e.fps) .. " fps"
						end),
						Color = scope:Computed(function(use)
							local e = use(s.Eclipse)
							return if e.active then Theme.Colors.Good elseif e.found then Theme.Colors.Warn else Theme.Colors.Bad
						end),
					}),
				},
			},
			scope:New "TextLabel" {
				Name = "Detail",
				LayoutOrder = 2,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.fromScale(1, 0),
				BackgroundTransparency = 1,
				FontFace = Theme.Font,
				TextSize = Theme.TextSize.Small,
				TextColor3 = Theme.Colors.TextDim,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				Visible = scope:Computed(function(use)
					return use(s.Detail) ~= nil and use(s.Connection) ~= "connected"
				end),
				Text = scope:Computed(function(use)
					return use(s.Detail) or ""
				end),
			},
			scope:New "Frame" {
				Name = "Controls",
				LayoutOrder = 3,
				Size = UDim2.new(1, 0, 0, 26),
				BackgroundTransparency = 1,
				[Children] = {
					scope:New "UIListLayout" { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) },
					Button(scope, {
						Text = scope:Computed(function(use)
							return if use(s.Paused) then "Resume all helpers" else "Pause all helpers"
						end),
						Accent = s.Paused,
						OnClick = function()
							props.OnPause(not Fusion.peek(s.Paused))
						end,
					}),
					Button(scope, {
						Text = scope:Computed(function(use)
							return if use(s.ShowPresence) then "Hide outlines" else "Show outlines"
						end),
						OnClick = function()
							props.OnShowPresence(not Fusion.peek(s.ShowPresence))
						end,
					}),
				},
			},

			heading(scope, "Helpers", 4),
			scope:New "Frame" {
				Name = "Helpers",
				LayoutOrder = 5,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.fromScale(1, 0),
				BackgroundTransparency = 1,
				[Children] = {
					scope:New "UIListLayout" { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) },
					scope:New "TextLabel" {
						Name = "Empty",
						Size = UDim2.new(1, 0, 0, 34),
						BackgroundTransparency = 1,
						FontFace = Theme.Font,
						TextSize = Theme.TextSize.Small,
						TextColor3 = Theme.Colors.TextDim,
						TextWrapped = true,
						TextXAlignment = Enum.TextXAlignment.Left,
						Visible = scope:Computed(function(use)
							return #use(s.Agents) == 0
						end),
						Text = "No helpers yet. Add the eclipse MCP server to Claude Code, or run deploy.js to start several.",
					},
					scope:ForPairs(s.Agents, function(_use, inner, index: number, agent: any)
						return index, HelperRow(inner, {
							Agent = agent,
							LayoutOrder = index,
							Tracks = inner:Computed(function(use2)
								return use2(leaseCounts)[agent.id] or 0
							end),
							OnStop = props.OnStop,
							OnResume = props.OnResume,
						})
					end) :: any,
				},
			},

			heading(scope, "Live activity", 6),
			scope:New "ScrollingFrame" {
				Name = "Activity",
				LayoutOrder = 7,
				Size = UDim2.new(1, 0, 1, -240),
				BackgroundColor3 = Theme.Colors.Surface,
				BorderSizePixel = 0,
				ScrollBarThickness = 4,
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				CanvasSize = UDim2.new(),
				[Children] = {
					scope:New "UICorner" { CornerRadius = Theme.Corner },
					scope:New "UIPadding" {
						PaddingTop = UDim.new(0, 6),
						PaddingLeft = UDim.new(0, 8),
						PaddingRight = UDim.new(0, 8),
					},
					scope:New "UIListLayout" { SortOrder = Enum.SortOrder.LayoutOrder },
					scope:ForPairs(s.Activity, function(_use, inner, index: number, event: any)
						-- Newest first.
						return index, ActivityRow(inner, { Event = event, LayoutOrder = -index })
					end) :: any,
				},
			},
		},
	}) :: any
end

return App
