--!strict
local Assert = require(script.Parent.Assert)
local Player = require(script.Parent.Parent.Player)
local Recorder = require(script.Parent.Parent.Recorder)
local Serializer = require(script.Parent.Parent.Serializer)
local Snapshot = require(script.Parent.Parent.Snapshot)

local function scene(): (Folder, Part)
	local folder = Instance.new("Folder")
	folder.Name = "FlashbackTestScene"
	folder.Parent = workspace
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = Vector3.new(2, 3, 4)
	part.CFrame = CFrame.new(0, 10, 0)
	part.Color = Color3.fromRGB(10, 20, 30)
	part.Parent = folder
	return folder, part
end

local function playerFor(blob: buffer): (Player.Player, Folder)
	local container = Instance.new("Folder")
	container.Name = "FlashbackTestProxies"
	container.Parent = workspace
	return Player.new(blob, { container = container :: Instance, autoStep = false }), container
end

local function hatFor(proxy: Instance): BasePart?
	for _, d in proxy:GetDescendants() do
		if d.Name == "Handle" and d:IsA("BasePart") and d:FindFirstChildWhichIsA("Weld") then
			return d
		end
	end
	return nil
end

local function proxyOf(player: Player.Player, id: number): BasePart
	local e = player:getEntities()[id]
	return assert(e and e.proxy, `no proxy for entity {id}`) :: BasePart
end

return {
	headerRoundTrips = function(t: Assert.T)
		local rec = Recorder.new({ tickRate = 20, trackCharacters = false })
		rec:start()
		rec:snapshot()
		rec:snapshot()
		local blob = rec:stop()
		local h = Player.readHeader(blob)
		t.eq(h.tickRate, 20)
		t.eq(h.tickCount, 2)
		t.eq(h.placeVersion, game.PlaceVersion)
		t.ok(h.startUnix > 0)
	end,

	rejectsForeignBuffers = function(t: Assert.T)
		t.fails(function()
			Player.readHeader(buffer.fromstring("not a replay at all"))
		end)
	end,

	recordsAndReplaysMovement = function(t: Assert.T)
		local folder, part = scene()
		local rec = Recorder.new({ tickRate = 10, keyframeEvery = 3, trackCharacters = false })
		rec:start()
		rec:track(part)
		for i = 1, 10 do
			part.CFrame = CFrame.new(i * 5, 10, 0) * CFrame.Angles(0, i * 0.2, 0)
			rec:snapshot()
		end
		local blob = rec:stop()
		folder:Destroy()

		local player, container = playerFor(blob)
		t.eq(player:tickCount(), 10)
		t.near(player:duration(), 1, 1e-9)

		player:seek(1)
		local proxy = proxyOf(player, 1)
		t.ok(proxy:IsA("Part"), "proxy is a Part")
		t.near(proxy.Position.X, 5, 1e-3, "tick 1 x")

		player:seek(5.5)
		t.near(proxy.Position.X, 27.5, 1e-3, "interpolated x")
		local _, yaw = proxy.CFrame:ToEulerAnglesYXZ()
		t.near(yaw, 5.5 * 0.2, math.rad(1), "interpolated yaw")

		player:seek(10)
		t.near(proxy.Position.X, 50, 1e-3, "final x")

		player:destroy()
		container:Destroy()
	end,

	skipsRedundantTransforms = function(t: Assert.T)
		local folder, part = scene()
		local rec = Recorder.new({ tickRate = 10, keyframeEvery = 1000, trackCharacters = false })
		rec:start()
		rec:track(part)
		rec:snapshot()
		local afterFirst = rec.ops.pos
		for _ = 1, 19 do
			rec:snapshot()
		end
		local idleBytes = rec.ops.pos - afterFirst
		for i = 1, 20 do
			part.CFrame = CFrame.new(i, 10, 0)
			rec:snapshot()
		end
		local movingBytes = rec.ops.pos - afterFirst - idleBytes
		rec:stop()
		folder:Destroy()
		t.eq(idleBytes, 0, "idle ticks write nothing")
		t.ok(movingBytes > 100, `moving ticks write data, got {movingBytes}`)
	end,

	spawnsAndDespawnsProxies = function(t: Assert.T)
		local folder, part = scene()
		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:start()
		rec:snapshot()
		rec:snapshot()
		rec:track(part)
		rec:snapshot()
		rec:snapshot()
		rec:untrack(part)
		rec:snapshot()
		rec:snapshot()
		local blob = rec:stop()
		folder:Destroy()

		local player, container = playerFor(blob)
		local e = player:getEntities()[1]
		t.eq(e.spawnTick, 2)
		t.eq(e.despawnTick, 4)
		player:seek(1)
		t.eq(e.proxy, nil, "not spawned yet")
		player:seek(3)
		t.ok(e.proxy, "spawned")
		t.eq(container:FindFirstChild("E1"), e.proxy)
		player:seek(5)
		t.eq(e.proxy, nil, "despawned")
		player:destroy()
		container:Destroy()
	end,

	tracksTaggedInstancesAndAttributeDescriptors = function(t: Assert.T)
		local folder, part = scene()
		part:AddTag(Recorder.TAG)
		part:SetAttribute(Recorder.DESCRIPTOR_ATTRIBUTE, "part:Ball")
		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:start()
		rec:snapshot()
		local blob = rec:stop()
		folder:Destroy()

		local player, container = playerFor(blob)
		local e = player:getEntities()[1]
		t.ok(e, "tagged part tracked")
		t.eq(e.descriptor, "part:Ball")
		player:seek(1)
		t.eq((proxyOf(player, 1) :: Part).Shape, Enum.PartType.Ball)
		player:destroy()
		container:Destroy()
	end,

	replaysWatchedProperties = function(t: Assert.T)
		local folder, part = scene()
		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:watchProperties("BasePart", { "Color", "Transparency", "Size", "Material", "CanCollide", "Name" })
		rec:start()
		rec:track(part)
		rec:snapshot()
		part.Color = Color3.fromRGB(200, 100, 50)
		part.Transparency = 0.5
		part.Material = Enum.Material.Neon
		part.CanCollide = false
		part.Name = "Renamed"
		rec:snapshot()
		part.Size = Vector3.new(1, 1, 1)
		rec:snapshot()
		local blob = rec:stop()
		folder:Destroy()

		local player, container = playerFor(blob)
		player:seek(1)
		local proxy = proxyOf(player, 1)
		t.eq(proxy.Color, Color3.fromRGB(10, 20, 30), "initial color")
		t.eq(proxy.Size, Vector3.new(2, 3, 4), "initial size")
		t.eq(proxy.Material, Enum.Material.Plastic)
		player:seek(2)
		t.eq(proxy.Color, Color3.fromRGB(200, 100, 50), "changed color")
		t.eq(proxy.Transparency, 0.5)
		t.eq(proxy.Material, Enum.Material.Neon)
		t.eq(proxy.CanCollide, false)
		t.eq(proxy.Name, "Renamed")
		player:seek(3)
		t.eq(proxy.Size, Vector3.new(1, 1, 1), "changed size")
		player:seek(1)
		t.eq(proxyOf(player, 1).Color, Color3.fromRGB(10, 20, 30), "rewound color")
		player:destroy()
		container:Destroy()
	end,

	deliversEventsAndChannels = function(t: Assert.T)
		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:registerChannel("Scores", function(w, tick)
			if tick % 2 == 0 then
				w:u16(tick * 100)
			end
		end)
		rec:start()
		rec:snapshot()
		rec:event("Kill", { killer = 1, victim = 2 })
		rec:snapshot()
		local custom = Serializer.newWriter(4)
		custom:u32(0xDEADBEEF)
		rec:custom("Raw", custom:finish())
		rec:snapshot()
		rec:snapshot()
		local blob = rec:stop()

		local player, container = playerFor(blob)
		local kills: { any } = {}
		local scores: { number } = {}
		local raw: number? = nil
		player:onEvent("Kill", function(payload, tick)
			table.insert(kills, { payload = payload, tick = tick })
		end)
		player:onChannel("Scores", function(r)
			table.insert(scores, r:u16())
		end)
		player:onChannel("Raw", function(r)
			raw = r:u32()
		end)

		player:play()
		player:step(0.05)
		t.eq(#kills, 0, "nothing before tick 1")
		player:step(0.35)
		t.eq(#kills, 1)
		t.eq(kills[1].tick, 2)
		t.eq(kills[1].payload.killer, 1)
		t.eq(kills[1].payload.victim, 2)
		t.eq(#scores, 2)
		t.eq(scores[1], 200)
		t.eq(scores[2], 400)
		t.eq(raw, 0xDEADBEEF)
		t.eq(player:isPlaying(), false, "stops at end")

		player:seek(0)
		player:play()
		player:step(1)
		t.eq(#kills, 2, "events refire after rewind")
		player:destroy()
		container:Destroy()
	end,

	speedAndPauseAffectClock = function(t: Assert.T)
		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:start()
		for _ = 1, 100 do
			rec:snapshot()
		end
		local blob = rec:stop()
		local player, container = playerFor(blob)
		player:play()
		player:setSpeed(2)
		player:step(1)
		t.near(player:currentTick(), 20, 1e-6)
		t.near(player:currentSeconds(), 2, 1e-6)
		player:pause()
		player:step(1)
		t.near(player:currentTick(), 20, 1e-6)
		player:seekSeconds(5)
		t.near(player:currentTick(), 50, 1e-6)
		player:destroy()
		container:Destroy()
	end,

	stepEmitsTicksAtTickRate = function(t: Assert.T)
		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:start()
		rec:step(0.05)
		t.eq(rec.tick, 0)
		rec:step(0.06)
		t.eq(rec.tick, 1)
		rec:step(1)
		t.eq(rec.tick, 11)
		rec:stop()
	end,

	parentsChildEntitiesUnderParentProxy = function(t: Assert.T)
		local folder, part = scene()
		local child = Instance.new("Part")
		child.Anchored = true
		child.CFrame = CFrame.new(0, 12, 0)
		child.Parent = part
		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:start()
		rec:track(part)
		rec:track(child)
		rec:snapshot()
		local blob = rec:stop()
		folder:Destroy()

		local player, container = playerFor(blob)
		t.eq(player:getEntities()[2].descriptor, "sub:Part")
		player:seek(1)
		local childProxy = proxyOf(player, 2)
		t.eq(childProxy.Parent, proxyOf(player, 1))
		t.near(childProxy.Position.Y, 12, 1e-3)
		player:destroy()
		container:Destroy()
	end,

	drivesExistingLimbsForSubEntities = function(t: Assert.T)
		local folder = Instance.new("Folder")
		folder.Name = "FlashbackTestScene"
		folder.Parent = workspace
		local model = Instance.new("Model")
		model.Name = "Rig"
		local root = Instance.new("Part")
		root.Name = "Root"
		root.Anchored = true
		root.CFrame = CFrame.new(0, 5, 0)
		root.Parent = model
		local limb = Instance.new("Part")
		limb.Name = "Limb"
		limb.Anchored = true
		limb.CFrame = CFrame.new(0, 7, 0)
		limb.Parent = model
		model.PrimaryPart = root
		model.Parent = folder
		local protos = Instance.new("Folder")
		local proto = model:Clone()
		proto.Parent = protos

		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:start()
		rec:track(model)
		rec:track(limb)
		rec:snapshot()
		limb.CFrame = CFrame.new(3, 7, 0)
		rec:snapshot()
		local blob = rec:stop()
		folder:Destroy()

		local container = Instance.new("Folder")
		container.Parent = workspace
		local player =
			Player.new(blob, { container = container :: Instance, prototypes = protos :: Instance, autoStep = false })
		player:seek(2)
		local rig = proxyOf(player, 1) :: Instance
		t.ok(rig:IsA("Model"), "prototype cloned")
		local limbProxy = proxyOf(player, 2)
		t.eq(limbProxy, rig:FindFirstChild("Limb"), "existing limb reused")
		t.near(limbProxy.Position.X, 3, 1e-3, "limb driven")
		player:seek(0)
		local rebuilt = proxyOf(player, 1) :: Instance
		t.ok(rebuilt ~= rig, "rig rebuilt after rewind")
		t.eq(proxyOf(player, 2), rebuilt:FindFirstChild("Limb"), "limb reused after rewind")
		player:destroy()
		container:Destroy()
		protos:Destroy()
	end,

	jointedLimbsAreSpawnedNotSampled = function(t: Assert.T)
		local folder = Instance.new("Folder")
		folder.Name = "FlashbackTestScene"
		folder.Parent = workspace
		local model = Instance.new("Model")
		local root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.Anchored = true
		root.CFrame = CFrame.new(0, 5, 0)
		root.Parent = model
		local limb = Instance.new("Part")
		limb.Name = "LeftArm"
		limb.CFrame = CFrame.new(1, 5, 0)
		limb.Parent = model
		local motor = Instance.new("Motor6D")
		motor.Part0 = root
		motor.Part1 = limb
		motor.Parent = limb
		local hand = Instance.new("Part")
		hand.Name = "LeftHand"
		hand.Parent = model
		local a0 = Instance.new("Attachment")
		a0.Parent = limb
		local a1 = Instance.new("Attachment")
		a1.Parent = hand
		local animated = Instance.new("AnimationConstraint")
		animated.Attachment0 = a0
		animated.Attachment1 = a1
		animated.Parent = hand
		model.PrimaryPart = root
		model.Parent = folder

		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:watchProperties("BasePart", { "Color" })
		rec:start()
		rec:track(model)
		rec:track(root)
		rec:track(limb)
		rec:track(hand)
		for i = 1, 30 do
			model:PivotTo(CFrame.new(i, 5, 0))
			rec:snapshot()
		end
		local blob = rec:stop()
		folder:Destroy()

		local player, container = playerFor(blob)
		local ents = player:getEntities()
		t.eq(ents[2], nil, "jointed parts are not written")
		t.eq(#ents[1].xforms, 30, "model sampled")
		t.ok(buffer.len(blob) < 900, `30 ticks of a rig plus its snapshot should be tiny, got {buffer.len(blob)}`)
		player:destroy()
		container:Destroy()
	end,

	deltaTransformsStayAccurate = function(t: Assert.T)
		local folder, part = scene()
		local rec = Recorder.new({ tickRate = 15, keyframeEvery = 1000, trackCharacters = false })
		rec:start()
		rec:track(part)
		local expected = {}
		for i = 1, 60 do
			local cf = CFrame.new(i * 0.37, 10 + math.sin(i / 5), i * 0.11) * CFrame.Angles(0, i * 0.05, 0)
			part.CFrame = cf
			rec:snapshot()
			expected[i] = cf
		end
		local blob = rec:stop()
		folder:Destroy()
		local player, container = playerFor(blob)
		for i = 1, 60, 7 do
			player:seek(i)
			local proxy = proxyOf(player, 1)
			t.ok((proxy.Position - expected[i].Position).Magnitude < 0.05, `position drift at {i}`)
			local _, err = (expected[i].Rotation:Inverse() * proxy.CFrame.Rotation):ToAxisAngle()
			t.ok(err < math.rad(1.5), `rotation drift at {i}: {math.deg(err)}`)
		end
		player:destroy()
		container:Destroy()
	end,

	tiltedRotationsFallBackToFullSamples = function(t: Assert.T)
		local folder, part = scene()
		local rec = Recorder.new({ tickRate = 15, keyframeEvery = 1000, trackCharacters = false })
		rec:start()
		rec:track(part)
		part.CFrame = CFrame.new(0, 10, 0) * CFrame.Angles(0.4, 0.2, 0.1)
		rec:snapshot()
		part.CFrame = CFrame.new(1, 10, 0) * CFrame.Angles(0.5, 0.2, 0.1)
		rec:snapshot()
		local blob = rec:stop()
		folder:Destroy()
		local player, container = playerFor(blob)
		player:seek(2)
		local _, err = (CFrame.Angles(0.5, 0.2, 0.1):Inverse() * proxyOf(player, 1).CFrame.Rotation):ToAxisAngle()
		t.ok(err < math.rad(0.5), `tilted rotation error {math.deg(err)}`)
		player:destroy()
		container:Destroy()
	end,

	characterSessionFitsBudget = function(t: Assert.T)
		local limbNames = {
			"Head",
			"UpperTorso",
			"LowerTorso",
			"LeftUpperArm",
			"LeftLowerArm",
			"LeftHand",
			"RightUpperArm",
			"RightLowerArm",
			"RightHand",
			"LeftUpperLeg",
			"LeftLowerLeg",
			"LeftFoot",
			"RightUpperLeg",
			"RightLowerLeg",
			"RightFoot",
		}
		local function simulate(tickRate: number, seconds: number): number
			local folder = Instance.new("Folder")
			folder.Parent = workspace
			local model = Instance.new("Model")
			local root = Instance.new("Part")
			root.Name = "HumanoidRootPart"
			root.Anchored = true
			root.Parent = model
			for _, name in limbNames do
				local limb = Instance.new("Part")
				limb.Name = name
				limb.Parent = model
				local motor = Instance.new("Motor6D")
				motor.Part0 = root
				motor.Part1 = limb
				motor.Parent = limb
			end
			model.PrimaryPart = root
			model:SetAttribute(Recorder.DESCRIPTOR_ATTRIBUTE, "char:1")
			model.Parent = folder

			local rec = Recorder.new({ tickRate = tickRate, trackCharacters = false })
			rec:watchProperties("BasePart", { "Color", "Transparency", "Size", "Material" })
			rec:watchProperties("Humanoid", { "Health", "MaxHealth" })
			rec:start()
			rec:track(model)
			for _, c in model:GetChildren() do
				if c:IsA("BasePart") then
					rec:track(c)
				end
			end
			local ticks = tickRate * seconds
			local pos = Vector3.new(0, 3, 0)
			for i = 1, ticks do
				local time = i / tickRate
				local yaw = math.sin(time * 0.7) * 1.2
				local speed = if time < 9 then 16 else 0
				local jump = if time > 3 and time < 4.2 then math.sin((time - 3) * math.pi / 1.2) * 7 else 0
				pos += CFrame.Angles(0, yaw, 0).LookVector * (speed / tickRate)
				model:PivotTo(CFrame.new(pos.X, 3 + jump, pos.Z) * CFrame.Angles(0, yaw, 0))
				rec:snapshot()
			end
			local blob = rec:stop()
			folder:Destroy()
			local player, container = playerFor(blob)
			player:seek(ticks)
			player:destroy()
			container:Destroy()
			return buffer.len(blob)
		end
		local base = simulate(10, 0)
		local at15 = simulate(15, 12) - base
		local at10 = simulate(10, 12) - base
		print(`Flashback 12s run/jump/idle rig: {at15} bytes @15Hz, {at10} bytes @10Hz (+{base} B rig snapshot)`)
		t.ok(at10 < 1024, `10Hz session should be under 1 KB, got {at10}`)
		t.ok(at15 < 1536, `15Hz session should be under 1.5 KB, got {at15}`)
	end,

	snapshotsRebuildModelsWithoutPrototypes = function(t: Assert.T)
		local folder = Instance.new("Folder")
		folder.Name = "FlashbackTestScene"
		folder.Parent = workspace
		local car = Instance.new("Model")
		car.Name = "Car"
		local body = Instance.new("Part")
		body.Name = "Body"
		body.Anchored = true
		body.Size = Vector3.new(8, 2, 4)
		body.Color = Color3.fromRGB(200, 30, 30)
		body.Material = Enum.Material.Metal
		body.CFrame = CFrame.new(0, 3, 0)
		body.Parent = car
		local wheel = Instance.new("Part")
		wheel.Name = "Wheel"
		wheel.Shape = Enum.PartType.Cylinder
		wheel.Anchored = true
		wheel.Size = Vector3.new(1, 2, 2)
		wheel.Transparency = 0.25
		wheel.CFrame = CFrame.new(3, 2, 2) * CFrame.Angles(0, 0, math.pi / 2)
		wheel.Parent = car
		local wedge = Instance.new("WedgePart")
		wedge.Name = "Hood"
		wedge.Anchored = true
		wedge.Size = Vector3.new(4, 1, 2)
		wedge.CFrame = CFrame.new(-4, 4, 0)
		wedge.Parent = car
		car.PrimaryPart = body
		car.Parent = folder

		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:start()
		rec:track(car)
		rec:snapshot()
		car:PivotTo(CFrame.new(20, 3, 0) * CFrame.Angles(0, 1, 0))
		rec:snapshot()
		local blob = rec:stop()
		folder:Destroy()

		local player, container = playerFor(blob)
		local e = player:getEntities()[1]
		t.ok(e.snapshot ~= nil, "snapshot recorded")
		player:seek(2)
		local proxy = proxyOf(player, 1) :: Instance
		t.ok(proxy:IsA("Model"), "rebuilt as a model")
		local parts = {}
		for _, d in proxy:GetDescendants() do
			if d:IsA("BasePart") then
				parts[d.Name] = d
			end
		end
		t.ok(parts.Body and parts.Wheel and parts.Hood, "all parts rebuilt")
		t.eq(parts.Body.Size, Vector3.new(8, 2, 4))
		t.eq(parts.Body.Material, Enum.Material.Metal)
		t.eq((parts.Wheel :: Part).Shape, Enum.PartType.Cylinder)
		t.near(parts.Wheel.Transparency, 0.25, 0.01)
		t.ok(parts.Hood:IsA("WedgePart"), "wedge kept its class")
		local pivot = (proxy :: Model):GetPivot()
		t.ok((pivot.Position - Vector3.new(20, 3, 0)).Magnitude < 0.1, "model moved to recorded pivot")
		local expectedWheel = pivot * CFrame.new(3, -1, 2) * CFrame.Angles(0, 0, math.pi / 2)
		t.ok((parts.Wheel.Position - expectedWheel.Position).Magnitude < 0.1, "wheel keeps its offset")
		t.ok(parts.Body.Anchored and not parts.Body.CanCollide, "proxy is inert")
		player:destroy()
		container:Destroy()
	end,

	snapshotsKeepSurfacesDecalsMeshesAndClothing = function(t: Assert.T)
		local folder = Instance.new("Folder")
		folder.Name = "FlashbackTestScene"
		folder.Parent = workspace
		local npc = Instance.new("Model")
		npc.Name = "Npc"
		local torso = Instance.new("Part")
		torso.Name = "Torso"
		torso.Anchored = true
		torso.TopSurface = Enum.SurfaceType.Weld
		torso.FrontSurface = Enum.SurfaceType.Studs
		torso.Reflectance = 0.4
		torso.Parent = npc
		local decal = Instance.new("Decal")
		decal.Face = Enum.NormalId.Front
		decal.Texture = "rbxassetid://12345"
		decal.Transparency = 0.5
		decal.Parent = torso
		local texture = Instance.new("Texture")
		texture.Face = Enum.NormalId.Top
		texture.Texture = "rbxassetid://777"
		texture.StudsPerTileU = 3
		texture.StudsPerTileV = 5
		texture.Parent = torso
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.FileMesh
		mesh.MeshId = "rbxassetid://424242"
		mesh.TextureId = "rbxassetid://434343"
		mesh.Scale = Vector3.new(2, 2, 2)
		mesh.Parent = torso
		local humanoid = Instance.new("Humanoid")
		humanoid.RigType = Enum.HumanoidRigType.R15
		humanoid.Parent = npc
		local shirt = Instance.new("Shirt")
		shirt.ShirtTemplate = "rbxassetid://111"
		shirt.Parent = npc
		local pants = Instance.new("Pants")
		pants.PantsTemplate = "rbxassetid://222"
		pants.Parent = npc
		local colors = Instance.new("BodyColors")
		colors.TorsoColor3 = Color3.fromRGB(10, 200, 30)
		colors.Parent = npc
		npc.PrimaryPart = torso
		npc.Parent = folder

		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:start()
		rec:track(npc)
		rec:snapshot()
		local blob = rec:stop()
		folder:Destroy()

		local player, container = playerFor(blob)
		player:seek(1)
		local proxy = proxyOf(player, 1) :: Instance
		local part = proxy:FindFirstChild("Torso") :: Part
		t.ok(part, "torso rebuilt")
		t.eq(part.TopSurface, Enum.SurfaceType.Weld)
		t.eq(part.FrontSurface, Enum.SurfaceType.Studs)
		t.near(part.Reflectance, 0.4, 0.01)
		local rebuiltDecal, rebuiltTexture, rebuiltMesh
		for _, child in part:GetChildren() do
			if child:IsA("Texture") then
				rebuiltTexture = child
			elseif child:IsA("Decal") then
				rebuiltDecal = child
			elseif child:IsA("SpecialMesh") then
				rebuiltMesh = child
			end
		end
		t.ok(rebuiltDecal, "decal rebuilt")
		t.eq(rebuiltDecal.Texture, "rbxassetid://12345")
		t.eq(rebuiltDecal.Face, Enum.NormalId.Front)
		t.near(rebuiltDecal.Transparency, 0.5, 0.01)
		t.ok(rebuiltTexture, "texture rebuilt")
		t.eq(rebuiltTexture.StudsPerTileU, 3)
		t.eq(rebuiltTexture.StudsPerTileV, 5)
		t.ok(rebuiltMesh, "special mesh rebuilt")
		t.eq(rebuiltMesh.MeshId, "rbxassetid://424242")
		t.eq(rebuiltMesh.TextureId, "rbxassetid://434343")
		t.eq(rebuiltMesh.Scale, Vector3.new(2, 2, 2))
		local rebuiltHumanoid = proxy:FindFirstChildWhichIsA("Humanoid")
		t.ok(rebuiltHumanoid, "humanoid rebuilt")
		t.eq((rebuiltHumanoid :: Humanoid).RigType, Enum.HumanoidRigType.R15)
		t.eq((proxy:FindFirstChildWhichIsA("Shirt") :: Shirt).ShirtTemplate, "rbxassetid://111")
		t.eq((proxy:FindFirstChildWhichIsA("Pants") :: Pants).PantsTemplate, "rbxassetid://222")
		t.eq((proxy:FindFirstChildWhichIsA("BodyColors") :: BodyColors).TorsoColor3, Color3.fromRGB(10, 200, 30))
		player:destroy()
		container:Destroy()
	end,

	charactersRebuildFromSnapshotWithJointsAndAccessories = function(t: Assert.T)
		local folder = Instance.new("Folder")
		folder.Name = "FlashbackTestScene"
		folder.Parent = workspace
		local char = Instance.new("Model")
		char.Name = "Rig"
		local root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.Anchored = true
		root.Parent = char
		local head = Instance.new("Part")
		head.Name = "Head"
		head.Color = Color3.fromRGB(240, 200, 160)
		head.CFrame = CFrame.new(0, 2, 0)
		head.Parent = char
		local neck = Instance.new("Motor6D")
		neck.Name = "Neck"
		neck.Part0 = root
		neck.Part1 = head
		neck.C0 = CFrame.new(0, 1, 0)
		neck.C1 = CFrame.new(0, -1, 0)
		neck.Parent = head
		local hat = Instance.new("Accessory")
		hat.Name = "Hat"
		local handle = Instance.new("MeshPart")
		handle.Name = "Handle"
		handle.CFrame = CFrame.new(0, 3, 0)
		handle.Parent = hat
		local weld = Instance.new("Weld")
		weld.Name = "AccessoryWeld"
		weld.Part0 = handle
		weld.Part1 = head
		weld.Parent = handle
		hat.Parent = char
		local torso = Instance.new("Part")
		torso.Name = "UpperTorso"
		torso.CFrame = CFrame.new(0, 1, 0)
		torso.Parent = char
		local rootAtt = Instance.new("Attachment")
		rootAtt.Name = "WaistRigAttachment"
		rootAtt.Position = Vector3.new(0, 0.5, 0)
		rootAtt.Parent = root
		local torsoAtt = Instance.new("Attachment")
		torsoAtt.Name = "WaistRigAttachment"
		torsoAtt.Position = Vector3.new(0, -0.5, 0)
		torsoAtt.Parent = torso
		local waist = Instance.new("AnimationConstraint")
		waist.Name = "Waist"
		waist.Attachment0 = rootAtt
		waist.Attachment1 = torsoAtt
		waist.Parent = torso
		local cape = Instance.new("Accessory")
		cape.Name = "Cape"
		local capeHandle = Instance.new("Part")
		capeHandle.Name = "Handle"
		capeHandle.Parent = cape
		local capeAtt = Instance.new("Attachment")
		capeAtt.Name = "BodyBackAttachment"
		capeAtt.Parent = capeHandle
		local torsoBack = Instance.new("Attachment")
		torsoBack.Name = "BodyBackAttachment"
		torsoBack.Parent = torso
		local rigid = Instance.new("RigidConstraint")
		rigid.Name = "AccessoryConstraint"
		rigid.Attachment0 = capeAtt
		rigid.Attachment1 = torsoBack
		rigid.Parent = capeHandle
		cape.Parent = char
		Instance.new("Humanoid").Parent = char
		char.PrimaryPart = root
		char:SetAttribute(Recorder.DESCRIPTOR_ATTRIBUTE, "char:1")
		char.Parent = folder

		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:start()
		rec:track(char)
		rec:snapshot()
		local blob = rec:stop()
		folder:Destroy()

		local player, container = playerFor(blob)
		player:seek(1)
		local proxy = proxyOf(player, 1) :: Instance
		t.ok(proxy:IsA("Model"), "character rebuilt from snapshot without the avatar service")
		t.eq((proxy :: Model).PrimaryPart, proxy:FindFirstChild("HumanoidRootPart"), "root part is written first")
		local rebuiltHead = proxy:FindFirstChild("Head") :: Part
		t.ok(rebuiltHead, "head rebuilt")
		t.eq(rebuiltHead.Color, Color3.fromRGB(240, 200, 160))
		t.eq(rebuiltHead.Anchored, false, "rig limbs stay unanchored so joints move them")
		local rebuiltHumanoid = proxy:FindFirstChildWhichIsA("Humanoid") :: Humanoid
		t.eq(rebuiltHumanoid.RequiresNeck, false, "proxy humanoids never die from a missing neck")
		t.eq(rebuiltHumanoid.BreakJointsOnDeath, false, "proxy humanoids never break joints")
		local rebuiltNeck = rebuiltHead:FindFirstChild("Neck") :: Motor6D
		t.ok(rebuiltNeck and rebuiltNeck:IsA("Motor6D"), "motor rebuilt")
		t.eq(rebuiltNeck.Part0, proxy:FindFirstChild("HumanoidRootPart"))
		t.near((rebuiltNeck.C0.Position - Vector3.new(0, 1, 0)).Magnitude, 0, 0.01)
		local rebuiltTorso = proxy:FindFirstChild("UpperTorso") :: BasePart
		local rebuiltWaist = rebuiltTorso:FindFirstChild("Waist") :: Motor6D
		t.ok(rebuiltWaist and rebuiltWaist:IsA("Motor6D"), "animation constraint rebuilt as a motor")
		t.eq(rebuiltWaist.Part0, proxy:FindFirstChild("HumanoidRootPart"))
		t.eq(rebuiltWaist.Part1, rebuiltTorso)
		t.near((rebuiltWaist.C0.Position - Vector3.new(0, 0.5, 0)).Magnitude, 0, 0.01, "motor C0 from attachment")
		t.near((rebuiltWaist.C1.Position - Vector3.new(0, -0.5, 0)).Magnitude, 0, 0.01, "motor C1 from attachment")
		local capeWeld = proxy:FindFirstChild("AccessoryConstraint", true) :: Weld
		t.ok(capeWeld and capeWeld:IsA("Weld"), "rigid constraint rebuilt as a weld")
		t.eq(capeWeld.Part1, rebuiltTorso)
		local rebuiltHandle = hatFor(proxy) :: BasePart
		t.ok(rebuiltHandle, "accessory handle rebuilt")
		local rebuiltWeld = rebuiltHandle:FindFirstChildWhichIsA("Weld")
		t.ok(rebuiltWeld and rebuiltWeld.Part1 == rebuiltHead, "accessory weld rebuilt next to the neck motor")
		t.eq(#rebuiltHead:GetChildren(), 1, "the accessory weld does not replace the head's motor")
		player:destroy()
		container:Destroy()
	end,

	effectsAreCapturedWithTheirState = function(t: Assert.T)
		local folder = Instance.new("Folder")
		folder.Name = "FlashbackTestScene"
		folder.Parent = workspace
		local car = Instance.new("Model")
		car.Name = "Car"
		local body = Instance.new("Part")
		body.Name = "Body"
		body.Anchored = true
		body.Parent = car
		local a0 = Instance.new("Attachment")
		a0.Name = "A0"
		a0.Position = Vector3.new(1, 0, 0)
		a0.Parent = body
		local a1 = Instance.new("Attachment")
		a1.Name = "A1"
		a1.Position = Vector3.new(-1, 0, 0)
		a1.Parent = body
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "Exhaust"
		emitter.Texture = "rbxassetid://5"
		emitter.Rate = 40
		emitter.Enabled = false
		emitter.Color = ColorSequence.new(Color3.new(1, 0, 0), Color3.new(0, 0, 1))
		emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 3) })
		emitter.Lifetime = NumberRange.new(2, 4)
		emitter.Parent = a0
		local beam = Instance.new("Beam")
		beam.Attachment0 = a0
		beam.Attachment1 = a1
		beam.Width0 = 2
		beam.Parent = body
		local fire = Instance.new("Fire")
		fire.Size = 7
		fire.Parent = body
		local sound = Instance.new("Sound")
		sound.Name = "Engine"
		sound.SoundId = "rbxassetid://9"
		sound.Volume = 0.3
		sound.Looped = true
		sound.Parent = body
		local light = Instance.new("PointLight")
		light.Range = 12
		light.Parent = body
		car.PrimaryPart = body
		car.Parent = folder

		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:start()
		rec:track(car)
		rec:snapshot()
		emitter.Enabled = true
		fire.Size = 3
		sound.Volume = 0.9
		rec:snapshot()
		local blob = rec:stop()
		folder:Destroy()

		local player, container = playerFor(blob)
		player:seek(1)
		local proxy = proxyOf(player, 1) :: Instance
		local rebuiltBody = proxy:FindFirstChild("Body") :: BasePart
		local rebuiltA0 = rebuiltBody:FindFirstChild("A0") :: Attachment
		t.ok(rebuiltA0, "attachment rebuilt")
		t.eq(rebuiltA0.Position, Vector3.new(1, 0, 0))
		local rebuiltEmitter = rebuiltA0:FindFirstChild("Exhaust") :: ParticleEmitter
		t.ok(rebuiltEmitter, "emitter rebuilt under its attachment")
		t.eq(rebuiltEmitter.Texture, "rbxassetid://5")
		t.eq(rebuiltEmitter.Rate, 40)
		t.eq(rebuiltEmitter.Enabled, false, "initial emitting state")
		t.eq(rebuiltEmitter.Lifetime, NumberRange.new(2, 4))
		t.eq(#rebuiltEmitter.Color.Keypoints, 2)
		t.near(rebuiltEmitter.Size.Keypoints[2].Value, 3, 0.001)
		local rebuiltBeam = rebuiltBody:FindFirstChildWhichIsA("Beam") :: Beam
		t.ok(rebuiltBeam, "beam rebuilt")
		t.eq(rebuiltBeam.Attachment0, rebuiltA0)
		t.eq(rebuiltBeam.Attachment1, rebuiltBody:FindFirstChild("A1"))
		t.eq(rebuiltBeam.Width0, 2)
		local rebuiltFire = rebuiltBody:FindFirstChildWhichIsA("Fire") :: Fire
		t.eq(rebuiltFire.Size, 7)
		local rebuiltSound = rebuiltBody:FindFirstChild("Engine") :: Sound
		t.eq(rebuiltSound.SoundId, "rbxassetid://9")
		t.eq(rebuiltSound.Looped, true)
		t.near(rebuiltSound.Volume, 0.3, 0.001)
		t.eq((rebuiltBody:FindFirstChildWhichIsA("PointLight") :: PointLight).Range, 12)

		player:seek(2)
		t.eq(rebuiltEmitter.Enabled, true, "emitting state follows the recording")
		t.eq(rebuiltFire.Size, 3)
		t.near(rebuiltSound.Volume, 0.9, 0.001)
		player:seek(1)
		local rewound = (proxyOf(player, 1) :: Instance):FindFirstChild("Exhaust", true) :: ParticleEmitter
		t.eq(rewound.Enabled, false, "rewind restores the earlier state")
		player:destroy()
		container:Destroy()
	end,

	modelsCloneLinkedPrefabs = function(t: Assert.T)
		local folder = Instance.new("Folder")
		folder.Name = "FlashbackTestScene"
		folder.Parent = workspace
		local car = Instance.new("Model")
		car.Name = "Car"
		local body = Instance.new("Part")
		body.Name = "Body"
		body.Anchored = true
		body.CFrame = CFrame.new(4, 3, 0)
		body.Parent = car
		car.PrimaryPart = body
		car.Parent = folder
		local key = car:GetFullName()

		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:start()
		rec:track(car)
		rec:snapshot()
		car:PivotTo(CFrame.new(10, 3, 0))
		rec:snapshot()
		local blob = rec:stop()
		folder:Destroy()

		local prefab = Instance.new("Model")
		prefab.Name = "CarPrefab"
		local chassis = Instance.new("Part")
		chassis.Name = "Chassis"
		chassis.Anchored = true
		chassis.Parent = prefab
		local spoiler = Instance.new("Part")
		spoiler.Name = "Spoiler"
		spoiler.CFrame = CFrame.new(0, 2, 0)
		spoiler.Parent = prefab
		local prefabBody = Instance.new("Part")
		prefabBody.Name = "Body"
		prefabBody.CFrame = CFrame.new(0, 0, 0)
		prefabBody.PivotOffset = CFrame.new(3, 3, 3)
		prefabBody.Parent = prefab
		prefab.PrimaryPart = chassis
		local prefabs = Instance.new("Folder")
		prefabs.Name = "FlashbackTestPrefabs"
		prefabs.Parent = workspace
		prefab.Parent = prefabs

		local player, container = playerFor(blob)
		local link = player:links()[1]
		t.eq(link.kind, "model")
		t.eq(link.key, key)
		t.eq(link.resolved, false, "models never resolve by path on their own")
		player:seek(1)
		t.eq((proxyOf(player, 1) :: Instance):FindFirstChild("Spoiler"), nil, "unlinked model rebuilds from snapshot")
		player:destroy()
		container:Destroy()

		prefab.Archivable = false
		Snapshot.link(key, prefab)
		player, container = playerFor(blob)
		player:seek(1)
		t.eq(
			(proxyOf(player, 1) :: Instance):FindFirstChild("Spoiler"),
			nil,
			"unclonable prefab falls back to the snapshot"
		)
		player:destroy()
		container:Destroy()
		prefab.Archivable = true

		player, container = playerFor(blob)
		t.ok(player:links()[1].resolved, "linked model resolves")
		player:seek(2)
		local proxy = (proxyOf(player, 1) :: Instance) :: Model
		t.ok(proxy:FindFirstChild("Spoiler"), "linked model clones the prefab")
		t.eq(proxy.PrimaryPart, proxy:FindFirstChild("Body"), "pivot moves to the part named like the recorded root")
		t.near((proxy:GetPivot().Position - Vector3.new(10, 3, 0)).Magnitude, 0, 0.05, "clone follows the recording")
		t.near(
			((proxy:FindFirstChild("Spoiler") :: BasePart).Position - Vector3.new(10, 5, 0)).Magnitude,
			0,
			0.05,
			"prefab geometry is placed relative to the recorded root"
		)
		player:destroy()
		container:Destroy()
		Snapshot.link(key, nil)
		prefabs:Destroy()
	end,

	meshPartsRebuildAsMeshParts = function(t: Assert.T)
		local ok, source = pcall(function()
			return game:GetService("AssetService"):CreateMeshPartAsync(Content.fromUri("rbxassetid://4770583131"))
		end)
		if not ok then
			print("Flashback: mesh loading unavailable, skipping mesh part test")
			return
		end
		local folder = Instance.new("Folder")
		folder.Name = "FlashbackTestScene"
		folder.Parent = workspace
		source.Name = "Limb"
		source.Anchored = true
		source.Size = Vector3.new(1, 2, 1)
		source.Color = Color3.fromRGB(200, 150, 100)
		source.TextureID = "rbxassetid://12"
		source.Parent = folder

		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:start()
		rec:track(source)
		rec:snapshot()
		local blob = rec:stop()
		folder:Destroy()

		local player, container = playerFor(blob)
		player:seek(1)
		local proxy = proxyOf(player, 1)
		t.ok(proxy:IsA("MeshPart"), "mesh part rebuilt as a real MeshPart")
		t.eq((proxy :: MeshPart).MeshId, "rbxassetid://4770583131")
		t.eq((proxy :: MeshPart).TextureID, "rbxassetid://12")
		t.eq(proxy.Size, Vector3.new(1, 2, 1))
		t.eq(proxy.Color, Color3.fromRGB(200, 150, 100))
		player:destroy()
		container:Destroy()
	end,

	avatarCharacterKeepsEveryLimb = function(t: Assert.T)
		local ok, rig = pcall(function()
			return game:GetService("Players"):CreateHumanoidModelFromUserId(game.CreatorId)
		end)
		if not ok or not rig then
			print("Flashback: avatar service unavailable, skipping avatar limb test")
			return
		end
		for _, d in rig:GetDescendants() do
			if d:IsA("BaseScript") then
				d:Destroy()
			end
		end
		local depth: { [string]: number } = {
			HumanoidRootPart = 0,
			LowerTorso = 1,
			UpperTorso = 2,
			Head = 3,
			LeftUpperArm = 3,
			RightUpperArm = 3,
			LeftLowerArm = 4,
			RightLowerArm = 4,
			LeftHand = 5,
			RightHand = 5,
			LeftUpperLeg = 2,
			RightUpperLeg = 2,
			LeftLowerLeg = 3,
			RightLowerLeg = 3,
			LeftFoot = 4,
			RightFoot = 4,
		}
		local byAttachment: { [string]: { Attachment } } = {}
		for _, d in rig:GetDescendants() do
			if d:IsA("Attachment") and d.Name:match("RigAttachment$") and depth[(d.Parent :: Instance).Name] then
				byAttachment[d.Name] = byAttachment[d.Name] or {}
				table.insert(byAttachment[d.Name], d)
			end
		end
		for name, pair in byAttachment do
			if #pair == 2 then
				local a, b = pair[1], pair[2]
				if depth[(a.Parent :: Instance).Name] > depth[(b.Parent :: Instance).Name] then
					a, b = b, a
				end
				local motor = Instance.new("Motor6D")
				motor.Name = (name:gsub("RigAttachment$", ""))
				motor.Part0 = a.Parent :: BasePart
				motor.Part1 = b.Parent :: BasePart
				motor.C0 = a.CFrame
				motor.C1 = b.CFrame
				motor.Parent = b.Parent
			end
		end
		local folder = Instance.new("Folder")
		folder.Name = "FlashbackTestScene"
		folder.Parent = workspace
		rig.Parent = folder
		rig:PivotTo(CFrame.new(0, 5, 0))
		rig:SetAttribute(Recorder.DESCRIPTOR_ATTRIBUTE, `char:{game.CreatorId}`)

		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:watchProperties("BasePart", { "Color", "Transparency", "Size", "Material" })
		rec:start()
		rec:track(rig)
		for _, c in rig:GetChildren() do
			if c:IsA("BasePart") then
				rec:track(c)
			end
		end
		for i = 1, 5 do
			rig:PivotTo(CFrame.new(i, 5, 0))
			rec:snapshot()
		end
		local blob = rec:stop()
		folder:Destroy()

		local player, container = playerFor(blob)
		player:seek(1)
		player:play()
		for _ = 1, 5 do
			player:step(1 / 30)
		end
		local proxy = proxyOf(player, 1) :: Instance
		local rootPart = (proxy :: Model).PrimaryPart :: BasePart
		local missing = {}
		for name in depth do
			local limb = proxy:FindFirstChild(name)
			if not limb or not limb:IsA("BasePart") then
				table.insert(missing, name .. " (absent)")
			elseif (limb.Position - rootPart.Position).Magnitude > 6 then
				table.insert(missing, `{name} ({math.floor((limb.Position - rootPart.Position).Magnitude)} studs away)`)
			elseif limb.Transparency > 0.5 and name ~= "HumanoidRootPart" then
				table.insert(missing, name .. " (transparent)")
			end
		end
		t.eq(#missing, 0, "limbs broken: " .. table.concat(missing, ", "))
		player:destroy()
		container:Destroy()
	end,

	snapshotsRefreshWhenDescendantsArrive = function(t: Assert.T)
		local folder = Instance.new("Folder")
		folder.Name = "FlashbackTestScene"
		folder.Parent = workspace
		local char = Instance.new("Model")
		char.Name = "Loading"
		local root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.Anchored = true
		root.Parent = char
		char.PrimaryPart = root
		char.Parent = folder

		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:start()
		rec:track(char)
		rec:snapshot()
		local arm = Instance.new("Part")
		arm.Name = "LeftUpperArm"
		arm.CFrame = CFrame.new(1.5, 0, 0)
		arm.Parent = char
		local motor = Instance.new("Motor6D")
		motor.Name = "LeftShoulder"
		motor.Part0 = root
		motor.Part1 = arm
		motor.Parent = arm
		task.wait()
		rec:snapshot()
		rec:snapshot()
		local blob = rec:stop()
		folder:Destroy()

		local player, container = playerFor(blob)
		player:seek(1)
		local proxy = proxyOf(player, 1) :: Instance
		t.ok(proxy:FindFirstChild("LeftUpperArm"), "late limb is part of the rebuilt model")
		t.ok(proxy:FindFirstChild("LeftShoulder", true), "late joint is rebuilt too")
		player:destroy()
		container:Destroy()
	end,

	accessoryHandlesKeepTheirOwnState = function(t: Assert.T)
		local folder = Instance.new("Folder")
		folder.Name = "FlashbackTestScene"
		folder.Parent = workspace
		local rig = Instance.new("Model")
		local root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.Anchored = true
		root.Parent = rig
		local function accessory(name: string, size: Vector3): BasePart
			local acc = Instance.new("Accessory")
			acc.Name = name
			local handle = Instance.new("Part")
			handle.Name = "Handle"
			handle.Size = size
			handle.Parent = acc
			acc.Parent = rig
			return handle
		end
		local hat = accessory("Hat", Vector3.new(2, 1, 2))
		accessory("Barrel", Vector3.new(1, 1, 1))
		rig.PrimaryPart = root
		rig.Parent = folder

		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:watchProperties("BasePart", { "Size", "Transparency" })
		rec:start()
		rec:track(rig)
		rec:snapshot()
		local quiet = rec.ops.pos
		rec:snapshot()
		t.eq(rec.ops.pos, quiet, "unchanged handles write nothing per tick")
		hat.Transparency = 0.5
		rec:snapshot()
		local blob = rec:stop()
		folder:Destroy()

		local player, container = playerFor(blob)
		player:seek(3)
		local proxy = proxyOf(player, 1) :: Instance
		local rebuiltHat = (proxy:FindFirstChild("Hat") :: Instance):FindFirstChild("Handle") :: BasePart
		local rebuiltBarrel = (proxy:FindFirstChild("Barrel") :: Instance):FindFirstChild("Handle") :: BasePart
		t.eq(rebuiltHat.Size, Vector3.new(2, 1, 2), "hat keeps its own size")
		t.eq(rebuiltBarrel.Size, Vector3.new(1, 1, 1), "barrel keeps its own size")
		t.near(rebuiltHat.Transparency, 0.5, 0.01, "change reaches the right handle")
		t.near(rebuiltBarrel.Transparency, 0, 0.01, "other handle untouched")
		player:destroy()
		container:Destroy()
	end,

	attributesScaleAndPerInstanceOverrides = function(t: Assert.T)
		local folder = Instance.new("Folder")
		folder.Name = "FlashbackTestScene"
		folder.Parent = workspace
		local model = Instance.new("Model")
		local root = Instance.new("Part")
		root.Name = "Root"
		root.Anchored = true
		root.Size = Vector3.new(2, 2, 2)
		root.Parent = model
		model.PrimaryPart = root
		local originalColor = root.Color
		model:SetAttribute("Team", "red")
		model:SetAttribute(Recorder.WATCH_ATTRIBUTE, "BasePart.Transparency")
		model:SetAttribute(Recorder.ATTRIBUTES_ATTRIBUTE, true)
		model:SetAttribute(Recorder.SCALE_ATTRIBUTE, true)
		model.Parent = folder
		local plain = Instance.new("Part")
		plain.Anchored = true
		plain.Parent = folder

		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:watchProperties("BasePart", { "Color" })
		rec:start()
		rec:track(model)
		rec:track(plain)
		rec:snapshot()
		t.eq(#rec.entities[model].watched["BasePart"], 1, "instance watch list overrides the recorder's")
		t.eq(rec.entities[plain].attributes, false, "attributes follow the recorder default")
		model:SetAttribute("Team", "blue")
		model:SetAttribute("Score", 7)
		model:ScaleTo(2)
		root.Color = Color3.new(1, 0, 0)
		root.Transparency = 0.5
		plain.Color = Color3.new(0, 1, 0)
		rec:snapshot()
		local blob = rec:stop()
		folder:Destroy()

		local player, container = playerFor(blob)
		player:seek(2)
		local proxy = proxyOf(player, 1) :: Instance
		t.eq(proxy:GetAttribute("Team"), "blue", "attribute change replayed")
		t.eq(proxy:GetAttribute("Score"), 7, "new attribute replayed")
		t.near((proxy :: Model):GetScale(), 2, 0.01, "model scale replayed")
		t.near(((proxy :: Model).PrimaryPart :: BasePart).Size.X, 4, 0.05, "scaled geometry")
		local rebuiltRoot = proxy:FindFirstChild("Root") :: BasePart
		t.near(rebuiltRoot.Transparency, 0.5, 0.01, "listed property recorded")
		t.eq(rebuiltRoot.Color, originalColor, "unlisted property ignored for the overriding instance")
		t.eq(proxyOf(player, 2).Color, Color3.new(0, 1, 0), "recorder default still applies elsewhere")
		player:seek(1)
		t.eq((proxyOf(player, 1) :: Instance):GetAttribute("Team"), "red", "rewound attribute")
		player:destroy()
		container:Destroy()
	end,

	descendantsCanBeSkipped = function(t: Assert.T)
		local folder = Instance.new("Folder")
		folder.Name = "FlashbackTestScene"
		folder.Parent = workspace
		local model = Instance.new("Model")
		local root = Instance.new("Part")
		root.Name = "Root"
		root.Anchored = true
		root.Parent = model
		local arm = Instance.new("Part")
		arm.Name = "Arm"
		arm.Parent = model
		local fire = Instance.new("Fire")
		fire.Enabled = false
		fire.Parent = arm
		model.PrimaryPart = root
		model:SetAttribute(Recorder.DESCENDANTS_ATTRIBUTE, false)
		model:SetAttribute(Recorder.ATTRIBUTES_ATTRIBUTE, true)
		model:SetAttribute("Team", "red")
		model.Parent = folder

		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:watchProperties("BasePart", { "Transparency" })
		rec:start()
		rec:track(model)
		rec:snapshot()
		local before = rec.ops.pos
		arm.Transparency = 0.5
		fire.Enabled = true
		rec:snapshot()
		t.eq(rec.ops.pos, before, "descendant changes are not written")
		model:SetAttribute("Team", "blue")
		rec:snapshot()
		t.ok(rec.ops.pos > before, "the entity's own attributes still are")
		local blob = rec:stop()
		folder:Destroy()

		local player, container = playerFor(blob)
		player:seek(3)
		local proxy = proxyOf(player, 1) :: Instance
		t.eq(proxy:GetAttribute("Team"), "blue")
		t.near((proxy:FindFirstChild("Arm") :: BasePart).Transparency, 0, 0.01, "descendant stayed as snapshotted")
		player:destroy()
		container:Destroy()
	end,

	sameNamedPartsStayApart = function(t: Assert.T)
		local folder = Instance.new("Folder")
		folder.Name = "FlashbackTestScene"
		folder.Parent = workspace
		local car = Instance.new("Model")
		local body = Instance.new("Part")
		body.Name = "Body"
		body.Anchored = true
		body.Parent = car
		local function wheel(x: number): Part
			local w = Instance.new("Part")
			w.Name = "Wheel"
			w.Anchored = true
			w.CFrame = CFrame.new(x, 0, 0)
			w.Parent = car
			return w
		end
		wheel(-2)
		local right = wheel(2)
		car.PrimaryPart = body
		car.Parent = folder

		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:watchProperties("BasePart", { "Transparency" })
		rec:start()
		rec:track(car)
		rec:track(right)
		rec:snapshot()
		right.Transparency = 0.5
		right.CFrame = CFrame.new(2, 5, 0)
		rec:snapshot()
		local blob = rec:stop()
		folder:Destroy()

		local player, container = playerFor(blob)
		t.eq(player:getEntities()[2].descriptor, "sub:Wheel#2", "sub entities are addressed by unique path")
		player:seek(2)
		local proxy = proxyOf(player, 1) :: Instance
		local wheels = {}
		for _, d in proxy:GetChildren() do
			if d.Name == "Wheel" then
				table.insert(wheels, d :: BasePart)
			end
		end
		t.eq(#wheels, 2, "both wheels rebuilt")
		t.near(wheels[1].Transparency, 0, 0.01, "first wheel untouched")
		t.near(wheels[2].Transparency, 0.5, 0.01, "second wheel changed")
		t.eq(proxyOf(player, 2), wheels[2], "the sub entity drives the second wheel")
		t.near(wheels[2].Position.Y, 5, 0.05, "second wheel follows its own transform")
		t.near(wheels[1].Position.Y, 0, 0.05, "first wheel stays")
		player:destroy()
		container:Destroy()
	end,

	characterMeshesAreKept = function(t: Assert.T)
		local folder = Instance.new("Folder")
		folder.Name = "FlashbackTestScene"
		folder.Parent = workspace
		local rig = Instance.new("Model")
		local root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.Anchored = true
		root.Parent = rig
		Instance.new("Humanoid").Parent = rig
		local mesh = Instance.new("CharacterMesh")
		mesh.BodyPart = Enum.BodyPart.Torso
		mesh.MeshId = 27111894
		mesh.BaseTextureId = 1
		mesh.OverlayTextureId = 2
		mesh.Parent = rig
		rig.PrimaryPart = root
		rig.Parent = folder

		local built = Snapshot.build(Snapshot.capture(rig) :: buffer)
		folder:Destroy()
		local rebuilt = built:FindFirstChildWhichIsA("CharacterMesh") :: CharacterMesh
		t.ok(rebuilt, "character mesh rebuilt")
		t.eq(rebuilt.BodyPart, Enum.BodyPart.Torso)
		t.eq(rebuilt.MeshId, 27111894)
		t.eq(rebuilt.BaseTextureId, 1)
		t.eq(rebuilt.OverlayTextureId, 2)
		built:Destroy()
	end,

	brokenJointsFreeTheLimb = function(t: Assert.T)
		local folder = Instance.new("Folder")
		folder.Name = "FlashbackTestScene"
		folder.Parent = workspace
		local rig = Instance.new("Model")
		local root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.Anchored = true
		root.CFrame = CFrame.new(0, 10, 0)
		root.Parent = rig
		local arm = Instance.new("Part")
		arm.Name = "Arm"
		arm.CFrame = CFrame.new(2, 10, 0)
		arm.Parent = rig
		local motor = Instance.new("Motor6D")
		motor.Part0 = root
		motor.Part1 = arm
		motor.C0 = CFrame.new(2, 0, 0)
		motor.Parent = arm
		rig.PrimaryPart = root
		rig.Parent = folder

		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:start()
		rec:track(rig)
		rec:track(arm)
		rec:snapshot()
		rec:snapshot()
		motor:Destroy()
		task.wait()
		arm.CFrame = CFrame.new(2, 3, 0)
		rec:snapshot()
		arm.CFrame = CFrame.new(2, 1, 0)
		rec:snapshot()
		local blob = rec:stop()
		folder:Destroy()

		local player, container = playerFor(blob)
		local limb = player:getEntities()[2]
		t.ok(limb, "the limb becomes an entity once its joint breaks")
		t.eq(limb.spawnTick, 2, "spawned on the tick the joint broke")
		player:seek(1)
		local proxy = proxyOf(player, 1) :: Instance
		t.ok(proxy:FindFirstChild("Motor6D", true), "joint intact before the break")
		player:seek(4)
		local proxyArm = proxy:FindFirstChild("Arm") :: BasePart
		t.eq(proxyArm:FindFirstChildWhichIsA("JointInstance"), nil, "joint removed on the proxy")
		t.near(proxyArm.Position.Y, 1, 0.05, "limb follows its own transform after the break")
		player:destroy()
		container:Destroy()
	end,

	toolsEquipAndUnequip = function(t: Assert.T)
		local folder = Instance.new("Folder")
		folder.Name = "FlashbackTestScene"
		folder.Parent = workspace
		local char = Instance.new("Model")
		local root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.Anchored = true
		root.Parent = char
		char.PrimaryPart = root
		char.Parent = folder
		local backpack = Instance.new("Folder")
		backpack.Name = "Backpack"
		backpack.Parent = folder
		local sword = Instance.new("Tool")
		sword.Name = "Sword"
		local handle = Instance.new("Part")
		handle.Name = "Handle"
		handle.Anchored = true
		handle.CFrame = CFrame.new(3, 0, 0)
		handle.Parent = sword
		sword.Parent = backpack

		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:start()
		rec:track(char)
		rec:snapshot()
		sword.Parent = char
		task.wait()
		rec:snapshot()
		rec:snapshot()
		sword.Parent = backpack
		task.wait()
		rec:snapshot()
		local blob = rec:stop()
		folder:Destroy()

		local player, container = playerFor(blob)
		local tool = player:getEntities()[2]
		t.ok(tool, "the equipped tool becomes an entity")
		t.eq(tool.descriptor, "model:Sword")
		t.eq(tool.spawnTick, 1)
		t.eq(tool.despawnTick, 3, "unequipping despawns it")
		player:seek(2)
		local proxy = proxyOf(player, 1) :: Instance
		t.eq(proxy:FindFirstChild("Handle"), nil, "character snapshot leaves the tool out")
		local toolProxy = proxyOf(player, 2) :: Instance
		t.eq(toolProxy.Parent, proxy, "tool proxy sits under the character proxy")
		t.near((toolProxy :: Model):GetPivot().Position.X, 3, 0.05, "tool follows its handle")
		player:seek(3)
		t.eq(player:getEntities()[2].proxy, nil, "tool gone after unequip")
		player:destroy()
		container:Destroy()
	end,

	soundRestartsAreRecorded = function(t: Assert.T)
		local folder, part = scene()
		local sound = Instance.new("Sound")
		sound.Name = "Swing"
		sound.SoundId = "rbxassetid://9125644905"
		sound.Parent = part
		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:start()
		rec:track(part)
		rec:snapshot()
		local function playAndWait()
			sound:Play()
			local started = os.clock()
			repeat
				task.wait()
			until rec.entities[part].soundPlays[sound] or os.clock() - started > 2
		end
		playAndWait()
		rec:snapshot()
		local mid = rec.ops.pos
		rec:snapshot()
		t.eq(rec.ops.pos, mid, "a playing sound writes nothing per tick")
		sound:Stop()
		task.wait()
		rec:snapshot()
		playAndWait()
		rec:snapshot()
		local blob = rec:stop()
		folder:Destroy()

		local player, container = playerFor(blob)
		local e = player:getEntities()[1]
		t.ok(e.props[2] and #e.props[2] >= 2, "play writes TimePosition and Playing")
		t.ok(e.props[5], "a second play is written again")
		player:destroy()
		container:Destroy()
	end,

	watchedPropertiesFollowDescendants = function(t: Assert.T)
		local folder = Instance.new("Folder")
		folder.Name = "FlashbackTestScene"
		folder.Parent = workspace
		local rig = Instance.new("Model")
		local root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.Anchored = true
		root.Parent = rig
		local arm = Instance.new("Part")
		arm.Name = "Arm"
		arm.Transparency = 0.25
		arm.Parent = rig
		local hat = Instance.new("Accessory")
		local handle = Instance.new("Part")
		handle.Name = "Handle"
		handle.Parent = hat
		hat.Parent = rig
		local humanoid = Instance.new("Humanoid")
		humanoid.Parent = rig
		rig.PrimaryPart = root
		rig.Parent = folder

		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:watchProperties("BasePart", { "Transparency" })
		rec:watchProperties("Humanoid", { "Health" })
		rec:start()
		rec:track(rig)
		rec:snapshot()
		arm.Transparency = 0.75
		handle.Transparency = 0.5
		humanoid.Health = 40
		rec:snapshot()
		local blob = rec:stop()
		folder:Destroy()

		local player, container = playerFor(blob)
		player:seek(1)
		local proxy = proxyOf(player, 1) :: Instance
		local rebuiltArm = proxy:FindFirstChild("Arm") :: BasePart
		t.near(rebuiltArm.Transparency, 0.25, 0.01, "snapshot transparency")
		player:seek(2)
		t.near(rebuiltArm.Transparency, 0.75, 0.01, "descendant transparency change replayed")
		t.near(
			(proxy:FindFirstChild("Handle", true) :: BasePart).Transparency,
			0.5,
			0.01,
			"accessory part change reaches the rebuilt proxy"
		)
		t.near((proxy:FindFirstChildWhichIsA("Humanoid") :: Humanoid).Health, 40, 0.01, "humanoid health replayed")
		player:destroy()
		container:Destroy()
	end,

	animationsStopWhenTheirTrackStops = function(t: Assert.T)
		local folder = Instance.new("Folder")
		folder.Name = "FlashbackTestScene"
		folder.Parent = workspace
		local rig = Instance.new("Model")
		local root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.Anchored = true
		root.Parent = rig
		local humanoid = Instance.new("Humanoid")
		humanoid.Parent = rig
		local animator = Instance.new("Animator")
		animator.Parent = humanoid
		rig.PrimaryPart = root
		rig.Parent = folder
		local anim = Instance.new("Animation")
		anim.AnimationId = "rbxassetid://507766666"
		local ok, track = pcall(animator.LoadAnimation, animator, anim)
		if not ok then
			print("Flashback: animations unavailable, skipping animation stop test")
			folder:Destroy()
			return
		end

		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:start()
		rec:track(rig)
		rec:snapshot()
		track:Play()
		task.wait()
		rec:snapshot()
		rec:snapshot()
		track:Stop()
		task.wait()
		rec:snapshot()
		rec:snapshot()
		local blob = rec:stop()
		folder:Destroy()

		local player, container = playerFor(blob)
		local e = player:getEntities()[1]
		local kinds = {}
		for _, a in e.anims do
			table.insert(kinds, `{a.kind}@{a.tick}`)
		end
		t.eq(#e.anims, 2, "one play and one stop recorded: " .. table.concat(kinds, ","))
		t.eq(e.anims[1].kind, "play")
		t.eq(e.anims[2].kind, "stop")
		t.ok(
			e.anims[2].tick > e.anims[1].tick and e.anims[2].tick <= e.anims[1].tick + 3,
			"stop lands on the first tick after the track went idle"
		)
		player:seek(e.anims[1].tick)
		t.ok(next(e.tracks) ~= nil, "track playing on the proxy after the play op")
		player:seek(5)
		t.eq(next(e.tracks), nil, "track removed from the proxy after the stop op")
		player:destroy()
		container:Destroy()
	end,

	unionsResolveThroughLinks = function(t: Assert.T)
		local GeometryService = game:GetService("GeometryService")
		local folder = Instance.new("Folder")
		folder.Name = "FlashbackTestScene"
		folder.Parent = workspace
		local a = Instance.new("Part")
		a.Size = Vector3.new(4, 4, 4)
		a.Parent = folder
		local b = Instance.new("Part")
		b.Size = Vector3.new(2, 8, 2)
		b.Parent = folder
		local ok, unions = pcall(function()
			return GeometryService:UnionAsync(a, { b })
		end)
		if not ok or not unions or not unions[1] then
			print("Flashback: GeometryService unavailable, skipping union test")
			folder:Destroy()
			return
		end
		local union = unions[1] :: UnionOperation
		union.Name = "Bench"
		union.Anchored = true
		union.CFrame = CFrame.new(0, 5, 0)
		union.Color = Color3.fromRGB(90, 60, 30)
		union.Parent = folder
		a:Destroy()
		b:Destroy()

		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:start()
		rec:track(union)
		rec:snapshot()
		local blob = rec:stop()
		local key = union:GetFullName()

		local player, container = playerFor(blob)
		local keys = player:links()
		t.eq(#keys, 1)
		t.eq(keys[1].key, key)
		t.eq(keys[1].kind, "union")
		t.ok(keys[1].resolved, "union at its recorded path resolves automatically")
		player:seek(1)
		t.ok(proxyOf(player, 1):IsA("UnionOperation"), "proxy is a union while the source exists")
		t.eq(proxyOf(player, 1).Color, Color3.fromRGB(90, 60, 30))
		player:destroy()
		container:Destroy()

		local moved = Instance.new("Folder")
		moved.Name = "FlashbackMovedUnions"
		moved.Parent = workspace
		union.Parent = moved
		player, container = playerFor(blob)
		t.eq(player:links()[1].resolved, false, "moved union no longer resolves by path")
		player:seek(1)
		t.ok(proxyOf(player, 1):IsA("Part"), "unresolved union falls back to a Part")
		player:destroy()
		container:Destroy()

		Snapshot.link(key, union)
		player, container = playerFor(blob)
		t.ok(player:links()[1].resolved, "manual link resolves the union")
		player:seek(1)
		t.ok(proxyOf(player, 1):IsA("UnionOperation"), "linked union rebuilds as a union")
		player:destroy()
		container:Destroy()
		Snapshot.link(key, nil)
		moved:Destroy()
		folder:Destroy()
	end,

	despawnRemovesProxyOnlyOnce = function(t: Assert.T)
		local folder, part = scene()
		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:start()
		rec:track(part)
		rec:snapshot()
		rec:snapshot()
		rec:untrack(part)
		rec:snapshot()
		local blob = rec:stop()
		folder:Destroy()
		local player, container = playerFor(blob)
		for _ = 1, 3 do
			player:seek(1)
			player:seek(3)
			player:seek(0)
		end
		player:seek(1)
		t.eq(#container:GetChildren(), 1, "exactly one proxy after repeated rewinds")
		player:destroy()
		container:Destroy()
	end,

	loopRestartsAndSeekZeroShowsFirstTick = function(t: Assert.T)
		local folder, part = scene()
		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:start()
		rec:track(part)
		for i = 1, 5 do
			part.CFrame = CFrame.new(i, 10, 0)
			rec:snapshot()
		end
		local blob = rec:stop()
		folder:Destroy()
		local player, container = playerFor(blob)
		player:seek(0)
		t.eq(player:currentTick(), 1, "seek 0 lands on the first tick")
		t.near((proxyOf(player, 1).Position - Vector3.new(1, 10, 0)).Magnitude, 0, 0.05, "first real keyframe shown")
		player:setLoop(true)
		player:play()
		player:step(10)
		t.ok(player:isPlaying(), "looping keeps playing past the end")
		t.ok(player:currentTick() < 5, "looped back to the start")
		player:setLoop(false)
		player:step(10)
		t.eq(player:isPlaying(), false, "without loop playback stops at the end")
		player:destroy()
		container:Destroy()
	end,

	reversePlaybackRewindsState = function(t: Assert.T)
		local folder, part = scene()
		local rec = Recorder.new({ tickRate = 10, trackCharacters = false })
		rec:watchProperties("BasePart", { "Transparency" })
		rec:start()
		rec:track(part)
		for i = 1, 10 do
			part.CFrame = CFrame.new(i, 10, 0)
			if i == 6 then
				part.Transparency = 0.5
			end
			rec:snapshot()
		end
		local blob = rec:stop()
		folder:Destroy()

		local player, container = playerFor(blob)
		player:seek(10)
		player:setReverse(true)
		player:play()
		t.ok(player:isPlaying())
		player:step(0.35)
		t.near(player:currentTick(), 6.5, 0.01, "playhead runs backwards")
		t.near(proxyOf(player, 1).Position.X, 6.5, 0.05, "transforms interpolate backwards")
		t.near(proxyOf(player, 1).Transparency, 0.5, 0.01, "state after the change still applied")
		player:step(0.2)
		t.near(proxyOf(player, 1).Transparency, 0, 0.01, "crossing the change tick rewinds state")
		player:step(5)
		t.eq(player:isPlaying(), false, "stops at the first tick")
		t.near(player:currentTick(), 1, 0.01)
		player:setReverse(false)
		player:play()
		player:step(0.1)
		t.near(player:currentTick(), 2, 0.01, "forward again")
		player:destroy()
		container:Destroy()
	end,

	keyframesAreIndexed = function(t: Assert.T)
		local rec = Recorder.new({ tickRate = 10, keyframeEvery = 4, trackCharacters = false })
		rec:start()
		for _ = 1, 10 do
			rec:snapshot()
		end
		rec:stop()
		t.eq(#rec.keyframes, 3)
		t.eq(rec.keyframes[1].tick, 1)
		t.eq(rec.keyframes[2].tick, 5)
		t.eq(rec.keyframes[3].tick, 9)
	end,
}
