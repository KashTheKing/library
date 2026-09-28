-- Draws a share of the wave mesh in parallel (see Draw.luau). The Renderer clones this script into
-- each of its worker Actors; this copy, next to the module, does nothing.
local actor = script:GetActor()
if not actor then
	return
end
local RunService = game:GetService("RunService")

local draw: any = nil
local published: SharedTable? = nil
local lastFrame = -1
local steps, stepMs, writeMs = 0, 0, 0

actor:BindToMessage("Load", function(ocean: ModuleScript, frame: SharedTable, share: number, shares: number, data)
	if not draw then
		-- this Actor's own copies of the modules: the same settings and weather, so the same waves
		require(ocean:FindFirstChild("Waves") :: ModuleScript).Init()
		require(ocean:FindFirstChild("Regions") :: ModuleScript).Init()
		require(ocean:FindFirstChild("Zones") :: ModuleScript).Init()
		draw = require(ocean:FindFirstChild("Draw") :: ModuleScript)
	end
	published = frame
	draw.Load(data, share, shares)
end)

-- the Renderer's client-local setting overrides (a zone's look), so the waves here match
actor:BindToMessage("Override", function(ocean: ModuleScript, name: string, value: any)
	require(ocean:FindFirstChild("Settings") :: ModuleScript).SetLocalOverride(name, value)
end)

RunService.PreRender:ConnectParallel(function()
	local frame = published
	if not (draw and frame) or frame.Frame == lastFrame then
		return
	end
	lastFrame = frame.Frame
	local started = os.clock()
	if draw.Step(draw.ReadFrame(frame)) then
		local stepped = os.clock()
		task.synchronize()
		local synced = os.clock()
		draw.Write()
		-- what this share costs, for the Renderer's stats: in parallel, and on the main thread
		steps += 1
		stepMs += stepped - started
		writeMs += os.clock() - synced
		if steps >= 30 then
			actor:SetAttribute("StepMs", stepMs / steps * 1000)
			actor:SetAttribute("WriteMs", writeMs / steps * 1000)
			steps, stepMs, writeMs = 0, 0, 0
		end
	end
end)

actor:SetAttribute("Ready", true)
