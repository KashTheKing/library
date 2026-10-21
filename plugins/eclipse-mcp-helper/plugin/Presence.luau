--!strict
-- Helper presence in the viewport: whatever a helper touches glows in its color, with a name tag saying what it is
-- doing. Everything lives in a CoreGui folder, so nothing is ever saved into Kash's place.

local Presence = {}
Presence.__index = Presence

local SHOW_SECONDS = 6
local MAX_HIGHLIGHTS = 24 -- Roblox draws at most 31 Highlights at once; leave room for Eclipse's own.

type Mark = { highlight: Highlight, expires: number }
type Tag = { gui: BillboardGui, label: TextLabel, expires: number }

export type Presence = typeof(setmetatable(
	{} :: {
		folder: Folder,
		marks: { [string]: Mark },
		tags: { [string]: Tag },
		enabled: boolean,
		alive: boolean,
	},
	Presence
))

local function color(hex: string): Color3
	local ok, c = pcall(Color3.fromHex, hex)
	return if ok then c else Color3.fromRGB(255, 138, 61)
end

function Presence.new(parent: Instance?): Presence
	local folder = Instance.new("Folder")
	folder.Name = "EclipseMCPHelperPresence"
	folder.Archivable = false
	folder.Parent = parent or game:GetService("CoreGui")
	local self = setmetatable({ folder = folder, marks = {}, tags = {}, enabled = true, alive = true }, Presence)
	task.spawn(function()
		while self.alive do
			task.wait(0.5)
			self:sweep(os.clock())
		end
	end)
	return self
end

function Presence.sweep(self: Presence, now: number)
	for key, mark in self.marks do
		if mark.expires <= now or not mark.highlight.Adornee or not mark.highlight.Adornee.Parent then
			mark.highlight:Destroy()
			self.marks[key] = nil
		end
	end
	for key, tag in self.tags do
		if tag.expires <= now or not tag.gui.Adornee or not tag.gui.Adornee.Parent then
			tag.gui:Destroy()
			self.tags[key] = nil
		end
	end
end

local function count(t: { [string]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

local function adorneeFor(target: Instance): Instance?
	if target:IsA("BasePart") or target:IsA("Model") then
		return target
	end
	if target:IsA("Bone") or target:IsA("Attachment") then
		return target:FindFirstAncestorWhichIsA("BasePart")
	end
	return target:FindFirstAncestorWhichIsA("BasePart") or target:FindFirstAncestorWhichIsA("Model")
end

function Presence.touch(self: Presence, agent: { id: string, name: string, color: string }, targets: { Instance }, note: string)
	if not self.enabled or not self.alive then
		return
	end
	local now = os.clock()
	local c = color(agent.color)
	local last: Instance? = nil
	for _, target in targets do
		local adornee = adorneeFor(target)
		if adornee and adornee:IsDescendantOf(workspace) then
			last = adornee
			local key = agent.id .. ":" .. adornee:GetFullName()
			local mark = self.marks[key]
			if not mark and count(self.marks) < MAX_HIGHLIGHTS then
				local h = Instance.new("Highlight")
				h.Name = agent.name
				h.Adornee = adornee
				h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
				h.FillTransparency = 0.85
				h.OutlineTransparency = 0
				h.Archivable = false
				h.Parent = self.folder
				mark = { highlight = h, expires = 0 }
				self.marks[key] = mark
			end
			if mark then
				mark.highlight.FillColor = c
				mark.highlight.OutlineColor = c
				mark.expires = now + SHOW_SECONDS
			end
		end
	end
	if not last then
		return
	end
	local tag = self.tags[agent.id]
	if not tag then
		local gui = Instance.new("BillboardGui")
		gui.Name = agent.name
		gui.AlwaysOnTop = true
		gui.Size = UDim2.fromOffset(240, 26)
		gui.StudsOffsetWorldSpace = Vector3.new(0, 2.5, 0)
		gui.LightInfluence = 0
		gui.Archivable = false
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.AutomaticSize = Enum.AutomaticSize.None
		label.BackgroundColor3 = Color3.fromRGB(25, 27, 29)
		label.BackgroundTransparency = 0.15
		label.TextColor3 = Color3.new(1, 1, 1)
		label.FontFace = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.SemiBold)
		label.TextSize = 14
		label.TextTruncate = Enum.TextTruncate.AtEnd
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = label
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = label
		label.Parent = gui
		gui.Parent = self.folder
		tag = { gui = gui, label = label, expires = 0 }
		self.tags[agent.id] = tag
	end
	assert(tag)
	tag.gui.Adornee = last :: Instance
	tag.label.Text = "  " .. agent.name .. "  ·  " .. note .. "  "
	;(tag.label:FindFirstChildOfClass("UIStroke") :: UIStroke).Color = c
	tag.expires = now + SHOW_SECONDS
end

function Presence.forget(self: Presence, agentId: string)
	for key, mark in self.marks do
		if string.sub(key, 1, #agentId + 1) == agentId .. ":" then
			mark.highlight:Destroy()
			self.marks[key] = nil
		end
	end
	local tag = self.tags[agentId]
	if tag then
		tag.gui:Destroy()
		self.tags[agentId] = nil
	end
end

function Presence.setEnabled(self: Presence, on: boolean)
	self.enabled = on
	if not on then
		self:sweep(math.huge)
	end
end

function Presence.destroy(self: Presence)
	self.alive = false
	self.folder:Destroy()
end

return Presence
