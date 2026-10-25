--!strict
-- Watches what Kash is doing (Studio selection, Eclipse frame, his own edits) so helpers can see him and stay off
-- the tracks he is editing. Runs twice a second; only reads.

local Codec = require(script.Parent.Codec)
local Eclipse = require(script.Parent.Eclipse)
local Ownership = require(script.Parent.Ownership)

local Watcher = {}

export type Snapshot = {
	eclipse: { found: boolean, active: boolean, version: number?, frame: number?, fps: number?, undo: number?, redo: number? },
	human: { name: string, selection: { any }, frame: number?, fps: number?, editAgoMs: number? },
}

function Watcher.start(ctx: any, userName: string, onChange: (Snapshot) -> ()): () -> ()
	local alive = true
	local lastEdit: number? = nil
	local lastSent = ""
	local Selection = game:GetService("Selection")

	local function snapshot(): Snapshot
		local e = Eclipse.pick(ctx.coreGui)
		local eclipse: any = { found = e ~= nil, active = false }
		if e then
			eclipse.version = e.version
			local okFrame, frame = e.invoke("GetCurrentFrame", {})
			if okFrame then
				eclipse.active, eclipse.frame, eclipse.fps = true, frame.Frame, frame.FPS
				if not ctx.busy then
					local okState, state = e.invoke("GetHistoryState", {})
					if okState then
						eclipse.undo, eclipse.redo = state.UndoCount, state.RedoCount
						if Ownership.observe(ctx.ownership, state.UndoCount, state.RedoCount) then
							lastEdit = os.clock()
						end
					end
				end
			end
		end
		local selection = {}
		for i, item in Selection:Get() do
			if i > 20 then
				break
			end
			table.insert(selection, Codec.encode(item, ctx.root))
		end
		return {
			eclipse = eclipse,
			human = {
				name = userName,
				selection = selection,
				frame = eclipse.frame,
				fps = eclipse.fps,
				editAgoMs = if lastEdit then math.floor((os.clock() - lastEdit) * 1000) else nil,
			},
		}
	end

	task.spawn(function()
		local lastForced = 0
		while alive do
			local ok, snap = pcall(snapshot)
			if ok then
				-- Send when something changed, and at least every 5 s so the bridge knows Studio is alive.
				local key = game:GetService("HttpService"):JSONEncode({ snap.eclipse, snap.human.selection, lastEdit } :: { any })
				if key ~= lastSent or os.clock() - lastForced > 5 then
					lastSent, lastForced = key, os.clock()
					onChange(snap)
				end
			end
			task.wait(0.5)
		end
	end)

	return function()
		alive = false
	end
end

return Watcher
