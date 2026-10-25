--!strict
-- One line of the live activity feed: "Claude  SetKeyframe Head @12", in the helper's color.

local Root = script.Parent.Parent.Parent
local Fusion = require(Root.Packages.Fusion)
local Theme = require(Root.UI.Theme)

local Children = Fusion.Children
type UsedAs<T> = Fusion.UsedAs<T>

export type Event = {
	type: string,
	at: string?,
	agent: any?,
	color: string?,
	op: string?,
	ok: boolean?,
	summary: string?,
	error: string?,
	keys: { string }?,
}

local function describe(e: Event): (string, string, string?)
	local who = if type(e.agent) == "table" then e.agent.name else e.agent
	local color = e.color or (if type(e.agent) == "table" then e.agent.color else nil)
	if e.type == "call" then
		local text = e.summary or e.op or "call"
		if e.ok == false then
			text = text .. "  failed: " .. tostring(e.error)
		end
		return who or "?", text, color
	elseif e.type == "joined" then
		return who or "?", "joined", color
	elseif e.type == "left" then
		return who or "?", "left", color
	elseif e.type == "claim" then
		return who or "?", "claimed " .. table.concat(e.keys or {}, ", "), color
	elseif e.type == "stopped" or e.type == "resumed" then
		return who or "?", e.type .. " by you", color
	elseif e.type == "paused" then
		return "You", "changed pause", nil
	end
	return who or "Bridge", e.type, color
end

export type Props = { Event: UsedAs<Event>, LayoutOrder: UsedAs<number>? }

local function ActivityRow(scope: Fusion.Scope<typeof(Fusion)>, props: Props): Frame
	local parts = scope:Computed(function(use)
		local who, text, color = describe(use(props.Event))
		return { who = who, text = text, color = color }
	end)
	return (scope:New "Frame" {
		Name = "ActivityRow",
		Size = UDim2.new(1, 0, 0, 20),
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
		[Children] = {
			scope:New "TextLabel" {
				Name = "Who",
				Size = UDim2.new(0, 84, 1, 0),
				BackgroundTransparency = 1,
				FontFace = Theme.FontBold,
				TextSize = Theme.TextSize.Small,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = scope:Computed(function(use)
					local c = use(parts).color
					return if c then Theme.hex(c) else use(Theme.get("TextDim"))
				end),
				Text = scope:Computed(function(use)
					return use(parts).who
				end),
			},
			scope:New "TextLabel" {
				Name = "What",
				Position = UDim2.fromOffset(88, 0),
				Size = UDim2.new(1, -88, 1, 0),
				BackgroundTransparency = 1,
				FontFace = Theme.Font,
				TextSize = Theme.TextSize.Small,
				TextColor3 = Theme.get("TextDim"),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Text = scope:Computed(function(use)
					return use(parts).text
				end),
			},
		},
	}) :: any
end

return ActivityRow
