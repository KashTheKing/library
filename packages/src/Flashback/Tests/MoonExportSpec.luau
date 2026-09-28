--!strict
local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(script.Parent.Assert)
local MoonExport = require(script.Parent.Parent.MoonExport)
local Player = require(script.Parent.Parent.Player)
local Recorder = require(script.Parent.Parent.Recorder)

return {
	writesCFrameTrackAndWorkspaceCopy = function(t: Assert.T)
		local folder = Instance.new("Folder")
		folder.Parent = workspace
		local part = Instance.new("Part")
		part.Anchored = true
		part.Parent = folder
		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:start()
		rec:track(part)
		for i = 1, 10 do
			part.CFrame = CFrame.new(if i <= 5 then 0 else i, 0, 0)
			if i == 8 then
				part.Transparency = 0.5
			end
			rec:snapshot()
		end
		local blob = rec:stop()
		folder:Destroy()

		local container = Instance.new("Folder")
		container.Parent = workspace
		local player = Player.new(blob, { container = container :: Instance, autoStep = false })
		local save = MoonExport.export(player, "FlashbackMoonTest")
		local copy = workspace:FindFirstChild("FlashbackMoonTest_E1")
		local data = HttpService:JSONDecode(save.Value)
		local track = (save:FindFirstChild("1") :: Instance):FindFirstChild("CFrame") :: Folder
		local keys = {}
		for _, child in track:GetChildren() do
			if tonumber(child.Name) then
				local value = (child:FindFirstChild("Values") :: Instance):FindFirstChild("0") :: CFrameValue
				keys[tonumber(child.Name) :: number] = value.Value
			end
		end
		local default = track:FindFirstChild("default") :: CFrameValue
		local propItem = save:FindFirstChild("2") :: Instance
		local transparency = propItem:FindFirstChild("Transparency") :: Instance
		local function keyValue(frame: string): number
			local key = transparency:FindFirstChild(frame) :: Instance
			return ((key:FindFirstChild("Values") :: Instance):FindFirstChild("0") :: NumberValue).Value
		end
		local transparencyDefault = (transparency:FindFirstChild("default") :: NumberValue).Value
		local holdValue, changeValue = keyValue("41"), keyValue("42")
		player:destroy()
		container:Destroy()
		if copy then
			copy:Destroy()
		end
		save:Destroy()

		t.ok(copy and copy:IsA("Part"), "copy in workspace")
		t.eq(data.Items[1].Path.ItemType, "Part")
		t.eq(data.Items[1].Path.InstanceNames[3], "FlashbackMoonTest_E1")
		t.eq(data.Information.Length, 60)
		t.ok(save.Parent == nil or save.Parent == ServerStorage:FindFirstChild("MoonAnimator2Saves"))
		t.near(default.Value.X, 0, 1e-3, "default")
		t.near(keys[0].X, 0, 1e-3, "frame 0")
		t.near(keys[24].X, 4.8, 1e-3, "tick 5 interpolated across the idle gap, as the player renders it")
		t.near(keys[30].X, 6, 1e-3, "first move at tick 6")
		t.near(keys[54].X, 10, 1e-3, "last tick")
		t.eq(data.Items[2].Path.ItemType, "Part", "property item")
		t.eq(data.Items[2].Path.InstanceNames[3], "FlashbackMoonTest_E1")
		t.eq(transparencyDefault, 0, "transparency default")
		t.eq(holdValue, 0, "hold before change")
		t.eq(changeValue, 0.5, "change at tick 8")
	end,

	hidesEntitiesOutsideTheirLifetime = function(t: Assert.T)
		local folder = Instance.new("Folder")
		folder.Parent = workspace
		local part = Instance.new("Part")
		part.Anchored = true
		part.Transparency = 0.25
		part.Parent = folder
		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:start()
		rec:snapshot()
		rec:snapshot()
		rec:track(part)
		for _ = 1, 5 do
			rec:snapshot()
		end
		rec:untrack(part)
		rec:snapshot()
		rec:snapshot()
		rec:snapshot()
		local blob = rec:stop()
		folder:Destroy()

		local container = Instance.new("Folder")
		container.Parent = workspace
		local player = Player.new(blob, { container = container :: Instance, autoStep = false })
		local save = MoonExport.export(player, "FlashbackMoonLifetime")
		local data = HttpService:JSONDecode(save.Value)
		local track = (save:FindFirstChild("2") :: Instance):FindFirstChild("Transparency") :: Instance
		local function keyValue(frame: string): number?
			local key = track:FindFirstChild(frame)
			return if key
				then ((key:FindFirstChild("Values") :: Instance):FindFirstChild("0") :: NumberValue).Value
				else nil
		end
		local ease = ((track:FindFirstChild("0") :: Instance):FindFirstChild("Eases") :: Instance):FindFirstChild(
				"0"
			) :: Instance
		local easeType = (ease:FindFirstChild("Type") :: StringValue).Value
		local spawn, despawn = player:getEntities()[1].spawnTick, player:getEntities()[1].despawnTick :: number
		local hidden, shown, hiddenAgain =
			keyValue("0"), keyValue(tostring((spawn - 1) * 6)), keyValue(tostring((despawn - 1) * 6))
		local defaultValue = (track:FindFirstChild("default") :: NumberValue).Value
		player:destroy()
		container:Destroy()
		local copy = workspace:FindFirstChild("FlashbackMoonLifetime_E1")
		if copy then
			copy:Destroy()
		end
		save:Destroy()

		t.eq(data.Items[2].Path.ItemType, "Part")
		t.eq(easeType, "Constant")
		t.eq(defaultValue, 1, "hidden by default")
		t.eq(hidden, 1, "hidden at frame 0")
		t.near(shown :: number, 0.25, 1e-2, "shown at spawn")
		t.eq(hiddenAgain, 1, "hidden at despawn")
	end,
}
