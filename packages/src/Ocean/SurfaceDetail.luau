--!native
--!optimize 2
--[[
	Client-only. The water's small-scale surface: ripples far finer than the wave mesh can carry,
	lit per pixel through a SurfaceAppearance on every part of the water (the tiles and the static
	mesh). The mesh draws the swell; this draws the chop on top of it, and a low roughness gives
	it sharp sun glints and a clear sky reflection.

	SurfaceDetail = Ripples: a built-in normal map, animated. RIPPLES ripple trains, each a whole
	number of wavelengths across the texture tile (so the map tiles) and a whole number of periods
	per loop (so it loops), shorter ones steeper and faster like real ripples. Only the slope is
	needed, and cos(A + B) splits into per-column and per-row tables, so a baked pixel is a few
	multiplies per ripple. FRAMES frames are baked once in small slices (no hitch), then played
	back as a flipbook like the foam (SurfaceTexture), crossfaded on Regular and Realistic.
	Runtime SurfaceAppearances only take EditableImages (AssetService:CreateSurfaceAppearanceAsync),
	so this costs two of them: the normal map and a flat roughness map. They have no mipmaps, which
	is why the ripples are soft: a fine, sharp pattern would shimmer in the distance.

	SurfaceDetail = Custom: a SurfaceAppearance named WaterSurface inside the Ocean module, made in
	Studio from your own uploaded maps (mipmapped and compressed, so it holds up at a distance).
	Each part of the water gets a clone.

	No ColorMap either way: the water's colour stays the part colour the renderer tints.
]]
local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")

local Settings = require(script.Parent.Settings)

local SIZE = 128 -- pixels per side, over one texture tile of the water
local FULL = Vector2.one * SIZE
-- The map repeats every texture tile (the renderer's re-centre step, a few dozen studs), so any
-- feature that stands out repeats on a visible grid. Many trains of similar size in every
-- direction, and none longer than a quarter of the tile, read as even chop instead.
local RIPPLES = 36
local MIN_PER_TILE, MAX_PER_TILE = 4, 11 -- ripple wavelengths per tile
local FRAMES = 32
local FPS = 4 -- 8 s loop
local ROWS_PER_SLICE = 3 -- baked per frame (~1 ms)
local TAU = 2 * math.pi
local DETAIL_NAME = "OceanDetail" -- the SurfaceAppearance this module parents to each part
local CUSTOM_NAME = "WaterSurface" -- SurfaceDetail = Custom: the SurfaceAppearance to clone, inside the Ocean module

local SurfaceDetail = {}

-- The ripple trains, fixed: integer wave vector (M, N) across the tile, amplitude, whole periods per loop.
local rippleM: { number } = {}
local rippleN: { number } = {}
local rippleAmp: { number } = {}
local rippleCycles: { number } = {}
local ripplePhase: { number } = {}
do
	local rng = Random.new(11)
	local taken = {}
	while #rippleM < RIPPLES do
		-- stratified directions over the half circle (a ripple and its opposite are the same train)
		local angle = (#rippleM + rng:NextNumber()) * math.pi / RIPPLES
		local length = rng:NextNumber(MIN_PER_TILE, MAX_PER_TILE)
		local m, n = math.round(math.cos(angle) * length), math.round(math.sin(angle) * length)
		local key = `{m},{n}`
		if (m ~= 0 or n ~= 0) and not taken[key] and not taken[`{-m},{-n}`] then
			taken[key] = true
			local k = math.sqrt(m * m + n * n)
			table.insert(rippleM, m)
			table.insert(rippleN, n)
			table.insert(rippleAmp, k ^ -1.2) -- a gently falling spectrum: no one train dominates
			table.insert(rippleCycles, math.max(1, math.round(math.sqrt(k)))) -- deep-water dispersion, roughly
			table.insert(ripplePhase, rng:NextNumber(0, TAU))
		end
	end
end

-- per column (x) and ripple i, at [(i - 1) * SIZE + x + 1]: cos and sin of 2 pi M u
local colCos = table.create(RIPPLES * SIZE, 0)
local colSin = table.create(RIPPLES * SIZE, 0)
for i = 1, RIPPLES do
	for x = 0, SIZE - 1 do
		local a = TAU * rippleM[i] * (x + 0.5) / SIZE
		colCos[(i - 1) * SIZE + x + 1] = math.cos(a)
		colSin[(i - 1) * SIZE + x + 1] = math.sin(a)
	end
end

local mode = "None" -- what is applied: None, Ripples or Custom
local strength, roughness = -1, -1 -- the settings the current maps were made with
local generation = 0
local smooth = true
local normalImage: EditableImage? = nil
local roughImage: EditableImage? = nil
local frames: { buffer } = {}
local ready = false
local playback: RBXScriptConnection? = nil
local applied: { [MeshPart]: boolean } = setmetatable({} :: any, { __mode = "k" })
local warned: { [string]: boolean } = {}

local function warnOnce(key: string, message: string)
	if not warned[key] then
		warned[key] = true
		warn(message)
	end
end

-- Crossfade between frames (30 fps) or just step through them (4 fps, free).
function SurfaceDetail.SetSmooth(on: boolean)
	smooth = on
end

-- Bakes rows y0 .. y1 of frame f (1-based) into `pixels`: the slope of the ripple field, as a
-- tangent-space normal (R = along u, G = along v, B = up).
local function bakeRows(pixels: buffer, f: number, y0: number, y1: number, scale: number)
	local tau = TAU * (f - 1) / FRAMES
	local rowCos, rowSin = table.create(RIPPLES, 0), table.create(RIPPLES, 0)
	local am, an = table.create(RIPPLES, 0), table.create(RIPPLES, 0)
	for i = 1, RIPPLES do
		local a = rippleAmp[i] * TAU * scale
		am[i], an[i] = a * rippleM[i], a * rippleN[i]
	end
	for y = y0, y1 do
		for i = 1, RIPPLES do
			local b = TAU * rippleN[i] * (y + 0.5) / SIZE - rippleCycles[i] * tau + ripplePhase[i]
			rowCos[i], rowSin[i] = math.cos(b), math.sin(b)
		end
		for x = 0, SIZE - 1 do
			local gu, gv = 0, 0
			for i = 1, RIPPLES do
				local j = (i - 1) * SIZE + x + 1
				-- cos(A + B): the ripple's slope, both ways
				local c = colCos[j] * rowCos[i] - colSin[j] * rowSin[i]
				gu += am[i] * c
				gv += an[i] * c
			end
			local inv = 1 / math.sqrt(gu * gu + gv * gv + 1)
			local r = math.floor((0.5 - 0.5 * gu * inv) * 255 + 0.5)
			local g = math.floor((0.5 - 0.5 * gv * inv) * 255 + 0.5)
			local b = math.floor((0.5 + 0.5 * inv) * 255 + 0.5)
			-- RGBA, little-endian
			buffer.writeu32(pixels, (y * SIZE + x) * 4, r + g * 0x100 + b * 0x10000 + 0xFF000000)
		end
	end
end

-- The slope scale that gives RippleStrength as the root-mean-square slope (1 = 45 degrees).
local function slopeScale(wanted: number): number
	local sum = 0
	for i = 1, RIPPLES do
		local k = math.sqrt(rippleM[i] ^ 2 + rippleN[i] ^ 2)
		sum += (rippleAmp[i] * TAU * k) ^ 2 / 2
	end
	return wanted / math.sqrt(sum)
end

local function bake(target: EditableImage, scale: number, token: number)
	for f = 1, FRAMES do
		local pixels = buffer.create(SIZE * SIZE * 4)
		for y0 = 0, SIZE - 1, ROWS_PER_SLICE do
			bakeRows(pixels, f, y0, math.min(y0 + ROWS_PER_SLICE, SIZE) - 1, scale)
			RunService.Heartbeat:Wait()
			if token ~= generation then
				return -- stopped mid-bake
			end
		end
		frames[f] = pixels
		if f == 1 then -- show something straight away; the parts get their maps from here on
			target:WritePixelsBuffer(Vector2.zero, FULL, pixels)
		end
	end
	ready = true
end

local function play(target: EditableImage)
	local blend = buffer.create(SIZE * SIZE * 4)
	local tick = 0
	local shown = 0
	playback = RunService.Heartbeat:Connect(function()
		tick += 1
		if not ready or tick % 4 ~= 0 then -- 15 fps is plenty for ripples this slow (an 8 s loop)
			return
		end
		local position = (os.clock() * FPS) % FRAMES
		local a = math.floor(position)
		if not smooth then
			if a ~= shown then
				shown = a
				target:WritePixelsBuffer(Vector2.zero, FULL, frames[a + 1])
			end
			return
		end
		local t = position - a
		local frameA, frameB = frames[a + 1], frames[a % FRAMES + 2] or frames[1]
		local readu8, writeu8 = buffer.readu8, buffer.writeu8
		for i = 0, SIZE * SIZE * 4 - 1 do
			local va = readu8(frameA, i)
			writeu8(blend, i, va + (readu8(frameB, i) - va) * t)
		end
		target:WritePixelsBuffer(Vector2.zero, FULL, blend)
	end)
end

-- The two maps for Ripples, baked in the background.
local function startRipples(): boolean
	local normal = AssetService:CreateEditableImage({ Size = FULL })
	if not normal then
		warnOnce("budget", "[Ocean] EditableImage memory budget reached: no surface ripples")
		return false
	end
	local rough = AssetService:CreateEditableImage({ Size = FULL })
	if not rough then
		normal:Destroy()
		warnOnce("budget", "[Ocean] EditableImage memory budget reached: no surface ripples")
		return false
	end
	normalImage, roughImage = normal, rough

	local grey = math.floor(math.clamp(roughness, 0, 1) * 255 + 0.5)
	local flat = buffer.create(SIZE * SIZE * 4)
	for i = 0, SIZE * SIZE - 1 do
		buffer.writeu32(flat, i * 4, grey + grey * 0x100 + grey * 0x10000 + 0xFF000000)
	end
	rough:WritePixelsBuffer(Vector2.zero, FULL, flat)

	task.spawn(bake, normal, slopeScale(strength), generation)
	play(normal)
	return true
end

local function removeFrom(part: MeshPart)
	local old = part:FindFirstChild(DETAIL_NAME)
	if old then
		old:Destroy()
	end
end

-- Takes every part's detail off and frees the maps.
function SurfaceDetail.Stop()
	generation += 1
	if playback then
		playback:Disconnect()
		playback = nil
	end
	for part in applied do
		removeFrom(part)
	end
	table.clear(applied)
	for _, image in { normalImage, roughImage } do
		if image then
			image:Destroy()
		end
	end
	normalImage, roughImage = nil, nil
	table.clear(frames)
	ready = false
	mode = "None"
end

local function giveRipples(part: MeshPart, token: number, normal: EditableImage, rough: EditableImage)
	-- only once the first frame is in: a SurfaceAppearance might keep the maps as they were when made
	while not frames[1] do
		RunService.Heartbeat:Wait()
		if token ~= generation then
			return
		end
	end
	local ok, result = pcall(function()
		return AssetService:CreateSurfaceAppearanceAsync({
			NormalMap = Content.fromObject(normal),
			RoughnessMap = Content.fromObject(rough),
		})
	end)
	if not ok then
		warnOnce("create", `[Ocean] surface ripples unavailable: {result}`)
		return
	end
	local appearance = result :: SurfaceAppearance
	if token ~= generation or part.Parent == nil then
		appearance:Destroy() -- stopped or rebuilt meanwhile
		return
	end
	removeFrom(part)
	appearance.Name = DETAIL_NAME
	appearance.Parent = part
end

-- Gives each part the detail `wanted` asks for ("Ripples", "Custom" or "None"), remaking the maps
-- when the mode, RippleStrength or WaterRoughness changed. Safe to call on every look change; parts
-- that already have it are left alone.
function SurfaceDetail.Apply(wanted: string, parts: { MeshPart })
	local wantStrength, wantRoughness = Settings.Get("RippleStrength"), Settings.Get("WaterRoughness")
	if wanted ~= mode or (wanted == "Ripples" and (wantStrength ~= strength or wantRoughness ~= roughness)) then
		SurfaceDetail.Stop()
		strength, roughness = wantStrength, wantRoughness
		if wanted == "Ripples" then
			if not startRipples() then
				return
			end
		end
		mode = wanted
	end
	if mode == "None" then
		return
	end
	local template: SurfaceAppearance? = nil
	if mode == "Custom" then
		local found = Settings.GetHost():FindFirstChild(CUSTOM_NAME)
		if not (found and found:IsA("SurfaceAppearance")) then
			warnOnce(
				"custom",
				`[Ocean] SurfaceDetail is Custom but the Ocean module has no SurfaceAppearance named {CUSTOM_NAME}`
			)
			return
		end
		template = found
	end
	for _, part in parts do
		if applied[part] then
			continue
		end
		applied[part] = true
		if template then
			removeFrom(part)
			local copy = template:Clone()
			copy.Name = DETAIL_NAME
			copy.Parent = part
		else
			task.spawn(giveRipples, part, generation, normalImage :: EditableImage, roughImage :: EditableImage)
		end
	end
end

return SurfaceDetail
