--!native
--!optimize 2
--[[
	Client-only "shader": a live EditableImage the ocean's foam layer uses as its texture.
	(Same trick OSGL wraps - a pixel buffer + WritePixelsBuffer - minus the library: OSGL can't
	target MeshPart.TextureContent and we need none of its drawing primitives.)

		white, alpha = a web of foam rings: cell borders of animated Worley noise, domain-warped,
		with wandering thickness and gaps so it reads as foam, not a honeycomb.

	Per-pixel noise every frame is far too slow in Luau, so it's a flipbook: FRAMES frames are
	baked once in small slices (no hitch), then playback is one buffer upload per tick. Feature
	points move on closed orbits and cells wrap at the edges, so it loops and tiles seamlessly.
]]
local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")

local SIZE = 128 -- pixels per side
local CELLS = 6 -- Worley cells per side = foam rings per tile
local FRAMES = 32
local FPS = 8 -- 4 s loop
local ORBIT = 0.32 -- how far feature points wander, in cells
local TAU = 2 * math.pi
local ROWS_PER_SLICE = 8 -- baked per frame (~2-3 ms)

local SurfaceTexture = {}
local FULL = Vector2.one * SIZE
SurfaceTexture.Ready = false
local smooth = true

-- Crossfade between frames (30 fps, ~0.5 ms) or just step through them (8 fps, free).
function SurfaceTexture.SetSmooth(on: boolean)
	smooth = on
end
SurfaceTexture.BakeProgress = 0

local image: EditableImage? = nil
local frames: { buffer } = {}
local playback: RBXScriptConnection? = nil
local generation = 0

local function smoothstep(a: number, b: number, x: number): number
	local t = math.clamp((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)
end

local function bake(target: EditableImage, token: number)
	local rng = Random.new(7)
	local n = CELLS * CELLS
	local phase, spin, radius = table.create(n, 0), table.create(n, 1), table.create(n, 0)
	for i = 1, n do
		phase[i] = rng:NextNumber(0, TAU)
		spin[i] = if rng:NextNumber() < 0.5 then -1 else 1
		radius[i] = rng:NextNumber(0.5, 1) * ORBIT
	end

	local px, py = table.create(n, 0), table.create(n, 0) -- feature points this frame, in cell units
	local rows = 0
	for f = 1, FRAMES do
		local angle = TAU * (f - 1) / FRAMES
		for cy = 0, CELLS - 1 do
			for cx = 0, CELLS - 1 do
				local i = cy * CELLS + cx + 1
				local a = phase[i] + spin[i] * angle
				px[i] = cx + 0.5 + math.cos(a) * radius[i]
				py[i] = cy + 0.5 + math.sin(a) * radius[i]
			end
		end

		local pixels = buffer.create(SIZE * SIZE * 4)
		for y = 0, SIZE - 1 do
			local sv = (y + 0.5) / SIZE * TAU -- 0..2pi across the tile: whole-number multiples stay tileable
			for x = 0, SIZE - 1 do
				local su = (x + 0.5) / SIZE * TAU
				-- domain warp: bend the straight Voronoi borders into wobbly foam lines
				local u = su / TAU * CELLS + 0.24 * math.sin(2 * sv + 1.3 + angle) + 0.1 * math.sin(5 * sv + 0.7)
				local v = sv / TAU * CELLS + 0.24 * math.sin(2 * su + 4.1 - angle) + 0.1 * math.sin(5 * su + 2.9)
				local cellX, cellY = math.floor(u), math.floor(v)
				local f1, f2 = 9, 9 -- squared distances to the nearest two feature points
				for oy = -1, 1 do
					local ny = cellY + oy
					local wy = ny % CELLS
					for ox = -1, 1 do
						local nx = cellX + ox
						local i = wy * CELLS + nx % CELLS + 1
						local dx = px[i] + (nx - nx % CELLS) - u -- un-wrap the neighbour back next to us
						local dy = py[i] + (ny - wy) - v
						local d = dx * dx + dy * dy
						if d < f1 then
							f1, f2 = d, f1
						elseif d < f2 then
							f2 = d
						end
					end
				end
				local edge = math.sqrt(f2) - math.sqrt(f1) -- 0 on a cell border
				local width = 0.13 + 0.09 * math.sin(3 * su + 2 * sv + angle) -- line thickness wanders
				local gaps =
					smoothstep(-0.25, 0.45, math.sin(3 * su - 2 * sv + 0.5) * math.sin(2 * su + 4 * sv + 2.2 + angle))
				-- crisp foam line; thins out in places but rings stay closed
				local ring = (1 - smoothstep(0.02, width, edge)) * (0.55 + 0.45 * gaps)
				local froth = (1 - smoothstep(0.1, 0.6, edge)) * 0.3 * gaps -- soft churn hugging the line

				local alpha = math.clamp(math.max(ring, froth), 0, 1)
				-- RGBA, little-endian: white with the pattern in alpha
				buffer.writeu32(pixels, (y * SIZE + x) * 4, 0x00FFFFFF + math.floor(alpha * 255) * 0x1000000)
			end

			rows += 1
			if rows % ROWS_PER_SLICE == 0 then
				SurfaceTexture.BakeProgress = rows / (FRAMES * SIZE)
				RunService.Heartbeat:Wait()
				if token ~= generation then
					return -- stopped mid-bake
				end
			end
		end
		frames[f] = pixels
		if f == 1 then -- show something straight away
			target:WritePixelsBuffer(Vector2.zero, FULL, pixels)
		end
	end
	SurfaceTexture.BakeProgress = 1
	SurfaceTexture.Ready = true
end

-- Returns the Content to put on the foam MeshPart's TextureContent. Safe to call repeatedly.
function SurfaceTexture.Get(): Content
	if not image then
		local created = AssetService:CreateEditableImage({ Size = FULL })
		if not created then -- the client's EditableImage budget is spent: plain white foam, no rings
			warn("[Ocean] EditableImage memory budget reached: no animated foam texture")
			return Content.none
		end
		image = created
		generation += 1
		task.spawn(bake, created, generation)

		local blendFoam = buffer.create(SIZE * SIZE * 4)
		buffer.fill(blendFoam, 0, 255) -- white; only alpha is blended per pixel
		local tick = 0
		local shown = 0
		playback = RunService.Heartbeat:Connect(function()
			tick += 1
			if not SurfaceTexture.Ready or tick % 2 == 1 then -- 30 fps is plenty for a 4 s loop
				return
			end
			local position = (os.clock() * FPS) % FRAMES
			local a = math.floor(position)
			if not smooth then
				if a ~= shown then
					shown = a
					created:WritePixelsBuffer(Vector2.zero, FULL, frames[a + 1])
				end
				return
			end
			-- crossfade between the two neighbouring baked frames: the flipbook itself is only
			-- 8 fps, which steps visibly; the lerp costs well under a millisecond in native
			local t = position - a
			local foamA, foamB = frames[a + 1], frames[a % FRAMES + 2] or frames[1]
			local readu8, writeu8 = buffer.readu8, buffer.writeu8
			for i = 3, SIZE * SIZE * 4 - 1, 4 do
				local fa = readu8(foamA, i)
				writeu8(blendFoam, i, fa + (readu8(foamB, i) - fa) * t)
			end
			created:WritePixelsBuffer(Vector2.zero, FULL, blendFoam)
		end)
	end
	return Content.fromObject(image :: EditableImage)
end

function SurfaceTexture.Stop()
	generation += 1
	if playback then
		playback:Disconnect()
		playback = nil
	end
	if image then
		image:Destroy()
		image = nil
	end
	table.clear(frames)
	SurfaceTexture.Ready = false
	SurfaceTexture.BakeProgress = 0
end

return SurfaceTexture
