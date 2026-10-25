--!strict
-- Eclipse Live: while Kash is in an Eclipse Live session, every helper joins that session as its own participant.
-- Each helper gets a peer entry next to the real ones (ServerStorage > Eclipse Animator Saves > EclipseAnimator_Live >
-- <room> > Peers), so everyone in the session sees "Claude" in the Live list with a playhead on the frame it is
-- working on. Helpers' edits go through Kash's Eclipse, which already syncs them to the room.
--
-- Only what Eclipse Live reads from a peer is written (name, color, "seen" heartbeat, frame). A helper peer never
-- publishes a document, never hosts and has no user id, so it can't take over a room or play anyone's timeline.

local Live = {}

local SAVES = "Eclipse Animator Saves"
local LIVE = "EclipseAnimator_Live"
local SEEN_EVERY = 5
local ALIVE = 90 -- Eclipse drops a peer whose heartbeat hasn't changed for 90 s

export type Agent = { id: string, name: string, color: string, stopped: boolean? }
export type Status = { room: string, file: string?, members: number, helpers: number }

export type Live = {
	storage: Instance,
	userId: number,
	room: Folder?,
	peers: { [string]: Folder },
	frames: { [string]: number },
	seenAt: number,
	update: (self: Live, agents: { Agent }, frame: number?, fps: number?) -> (),
	noteFrame: (self: Live, agentId: string, frame: number) -> (),
	status: (self: Live) -> Status?,
	leave: (self: Live) -> (),
}

local function finite(n: any): boolean
	return type(n) == "number" and n == n and math.abs(n) < 1e15
end

local function isHelper(peer: Instance): boolean
	return peer:GetAttribute("EclipseMCPHelper") == true
end

local function alive(peer: Instance): boolean
	local seen = peer:GetAttribute("Seen")
	return finite(seen) and (seen :: number) > 0 and math.abs(os.time() - (seen :: number)) <= ALIVE
end

-- The room Kash's own Eclipse is in right now: open, with a live peer that carries his user id.
function Live.findRoom(storage: Instance, userId: number): Folder?
	local saves = storage:FindFirstChild(SAVES)
	local found = saves and saves:FindFirstChild(LIVE)
	if not found or found:GetAttribute("EclipseLiveVersion") ~= 1 then
		return nil
	end
	local root = found :: Instance
	local best: Folder?, bestAt = nil, -math.huge
	for _, room in root:GetChildren() do
		local peers = room:FindFirstChild("Peers")
		if not room:IsA("Folder") or room:GetAttribute("Closed") or not peers then
			continue
		end
		for _, peer in (peers :: Instance):GetChildren() do
			if peer:IsA("Folder") and not isHelper(peer) and peer:GetAttribute("UserId") == userId and alive(peer) then
				local at = room:GetAttribute("StartedAt")
				local started = if finite(at) then at :: number else 0
				if started > bestAt then
					best, bestAt = room :: Folder, started
				end
				break
			end
		end
	end
	return best
end

local function hostFrame(room: Folder, userId: number): number?
	local peers = room:FindFirstChild("Peers")
	local list: { Instance } = if peers then peers:GetChildren() else {}
	for _, peer in list do
		if not isHelper(peer) and peer:GetAttribute("UserId") == userId then
			local f = peer:GetAttribute("Frame")
			return if finite(f) then f :: number else nil
		end
	end
	return nil
end

local function setIfChanged(inst: Instance, name: string, value: any)
	if inst:GetAttribute(name) ~= value then
		inst:SetAttribute(name, value)
	end
end

function Live.new(storage: Instance, userId: number): Live
	local self = {
		storage = storage,
		userId = userId,
		room = nil :: Folder?,
		peers = {} :: { [string]: Folder },
		frames = {} :: { [string]: number },
		seenAt = 0,
	}

	local function drop(id: string)
		local peer = self.peers[id]
		self.peers[id] = nil
		if peer then
			-- Eclipse treats Seen = 0 as "left"; then the entry goes away.
			peer:SetAttribute("Seen", 0)
			peer:Destroy()
		end
	end

	function self.leave(_: Live)
		for id in self.peers do
			drop(id)
		end
		self.room = nil
	end

	function self.noteFrame(_: Live, agentId: string, frame: number)
		if finite(frame) and frame >= 0 then
			self.frames[agentId] = frame
		end
	end

	function self.update(me: Live, agents: { Agent }, frame: number?, fps: number?)
		local room = Live.findRoom(self.storage, self.userId)
		if room ~= self.room then
			me:leave()
			self.room = room
		end
		if not room then
			return
		end
		local inRoom = room :: Folder
		local peers = inRoom:FindFirstChild("Peers") :: Folder
		local beat = os.clock() - self.seenAt >= SEEN_EVERY
		if beat then
			self.seenAt = os.clock()
		end
		local present: { [string]: boolean } = {}
		for _, agent in agents do
			if agent.stopped then
				continue
			end
			present[agent.id] = true
			local peer = self.peers[agent.id]
			if not peer or peer.Parent ~= peers then
				peer = Instance.new("Folder")
				local p = peer :: Folder
				p.Name = "Helper-" .. agent.id
				p.Archivable = false
				p:SetAttribute("EclipseMCPHelper", true)
				p:SetAttribute("UserId", 0)
				p:SetAttribute("Playing", false)
				p:SetAttribute("Seen", os.time())
				p.Parent = peers
				self.peers[agent.id] = p
			end
			local p = peer :: Folder
			setIfChanged(p, "UserName", agent.name)
			local okColor, color = pcall(Color3.fromHex, agent.color)
			if okColor then
				setIfChanged(p, "Color", color)
			end
			local at = self.frames[agent.id] or frame or hostFrame(inRoom, self.userId) or 0
			setIfChanged(p, "Frame", at)
			setIfChanged(p, "PlaybackEnd", at)
			setIfChanged(p, "FPS", fps or 60)
			if beat then
				p:SetAttribute("Seen", os.time())
			end
		end
		for id in self.peers do
			if not present[id] then
				drop(id)
			end
		end
		for id in self.frames do
			if not present[id] then
				self.frames[id] = nil
			end
		end
	end

	function self.status(_: Live): Status?
		local current = self.room
		if not current or not current.Parent then
			return nil
		end
		local room = current :: Folder
		local peers = room:FindFirstChild("Peers")
		local members = 0
		local list: { Instance } = if peers then peers:GetChildren() else {}
		for _, peer in list do
			if peer:IsA("Folder") and alive(peer) then
				members += 1
			end
		end
		local helpers = 0
		for _ in self.peers do
			helpers += 1
		end
		local file = room:GetAttribute("FileName")
		return { room = room.Name, file = if type(file) == "string" then file else nil, members = members, helpers = helpers }
	end

	return (self :: any) :: Live
end

return Live
