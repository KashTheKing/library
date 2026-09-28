--!native
--!optimize 2
--[[
	Simulation

	Tessendorf-style FFT ocean. Every step the spectrum of each cascade is
	advanced in time, packed two real fields per complex FFT, transformed back
	to the spatial domain and post-processed into interleaved texel data,
	STRIDE numbers per texel:

		[1] displacement X   [2] height          [3] displacement Z
		[4] normal X / Y     [5] normal Z / Y    [6] foam (0..1)

	The normal is stored as its slope form (nx/ny, nz/ny) so cascades can be
	combined by adding slopes. Foam spawns where the choppy displacement
	compresses the surface the most and fades over FoamDecay seconds. Each
	cascade's Jacobian threshold is calibrated so that FoamCoverage of its
	surface can spawn foam, which keeps the amount sensible for any sea state.
	Foam lives in the undisplaced texel grid, so it rides the waves instead
	of travelling with the crests.

	Cascades cover separate wavelength bands and tile with different periods,
	so their sum does not visibly repeat.

	Each cascade also keeps a box-filtered mip chain of its texel data
	(n/2, n/4, ... 1). Coarse LOD levels sample the mip that matches their
	vertex spacing, so small waves fade out smoothly instead of aliasing.
]]

local Spectrum = require(script.Parent.Spectrum)
local Transform = require(script.Parent.Transform)

local Simulation = {}
Simulation.__index = Simulation

local TAU = 2 * math.pi
local STRIDE = 6
-- Foam is brightened a little in every coarser mip. Averaging a whitecap into a bigger texel would
-- otherwise dim it to nothing, and the far sea (the coarse mips) would lose its foam: the gain keeps
-- distant whitecaps showing, capped at 1 so a far texel never goes whiter than solid foam.
local FOAM_MIP_GAIN = 1.2

local FIELD_HEIGHT = 1
local FIELD_DISP_X = 2
local FIELD_DISP_Z = 3

Simulation.STRIDE = STRIDE

export type Mip = {
	n: number,
	data: { number },
	-- texel coordinate = world * scale + offset (mip texels are centred on their block)
	scale: number,
	offset: number,
}

export type Cascade = {
	index: number,
	settings: any,
	n: number,
	nn: number,
	size: number,
	texel: number,
	invTexel: number,
	mips: { Mip },

	h0r: { number },
	h0i: { number },
	h0mr: { number },
	h0mi: { number },
	omega: { number },
	kxk: { number },
	kzk: { number },
	active: { number },
	activeCount: number,
	activeRows: { number },

	hr: { number },
	hi: { number },
	height: { number },
	dispX: { number },
	dispZ: { number },
	foam: { number },
	data: { number },
	foamThreshold: number,
}

type Field = { cascade: Cascade, kind: number }

type Job = {
	plan: Transform.Plan,
	nn: number,
	re: { number },
	im: { number },
	zeros: { number },
	a: Field,
	b: Field?,
	rows: { number },
}

local function buildCascade(
	index: number,
	settings: any,
	spectrum: Spectrum.Result,
	scale: number,
	gravity: number
): Cascade
	local n = settings.Resolution
	local nn = n * n
	local size = settings.PatchSize
	local dk = TAU / size
	local half = n // 2

	local cascade: Cascade = {
		index = index,
		settings = settings,
		n = n,
		nn = nn,
		size = size,
		texel = size / n,
		invTexel = n / size,

		h0r = table.create(nn, 0),
		h0i = table.create(nn, 0),
		h0mr = table.create(nn, 0),
		h0mi = table.create(nn, 0),
		omega = table.create(nn, 0),
		kxk = table.create(nn, 0),
		kzk = table.create(nn, 0),
		active = {},
		activeCount = 0,
		activeRows = {},

		hr = table.create(nn, 0),
		hi = table.create(nn, 0),
		height = table.create(nn, 0),
		dispX = table.create(nn, 0),
		dispZ = table.create(nn, 0),
		foam = table.create(nn, 0),
		data = table.create(nn * STRIDE, 0),
		mips = {},
		foamThreshold = -math.huge,
	}

	-- mips[1] is the full-resolution data; each further mip halves the size down to 1x1
	local mipSize, level = n, 0
	while mipSize >= 1 do
		local factor = 2 ^ level
		table.insert(cascade.mips, {
			n = mipSize,
			data = if level == 0 then cascade.data else table.create(mipSize * mipSize * STRIDE, 0),
			scale = cascade.invTexel / factor,
			offset = 0.5 / factor - 0.5,
		})
		mipSize //= 2
		level += 1
	end

	local srcR, srcI = spectrum.h0r, spectrum.h0i
	local rowUsed = {}
	for j = 0, n - 1 do
		local mz = if j < half then j else j - n
		local jNeg = (n - j) % n
		for i = 0, n - 1 do
			local mx = if i < half then i else i - n
			local iNeg = (n - i) % n
			local cell = j * n + i + 1
			local negCell = jNeg * n + iNeg + 1

			local ar, ai = srcR[cell] * scale, srcI[cell] * scale
			local pr, pi = srcR[negCell] * scale, srcI[negCell] * scale
			if ar ~= 0 or ai ~= 0 or pr ~= 0 or pi ~= 0 then
				local kx, kz = mx * dk, mz * dk
				local k = math.sqrt(kx * kx + kz * kz)
				cascade.h0r[cell], cascade.h0i[cell] = ar, ai
				-- conj(h0(-k)) for the Hermitian half of the spectrum
				cascade.h0mr[cell], cascade.h0mi[cell] = pr, -pi
				cascade.omega[cell] = math.sqrt(gravity * k)
				cascade.kxk[cell] = kx / k
				cascade.kzk[cell] = kz / k
				table.insert(cascade.active, cell)
				rowUsed[j] = true
			end
		end
	end

	cascade.activeCount = #cascade.active
	for j = 0, n - 1 do
		if rowUsed[j] then
			table.insert(cascade.activeRows, j)
		end
	end

	return cascade
end

local function mergeRows(a: Cascade, b: Cascade?): { number }
	if not b or b == a then
		return a.activeRows
	end
	local used = {}
	for _, row in a.activeRows do
		used[row] = true
	end
	for _, row in b.activeRows do
		used[row] = true
	end
	local rows = {}
	for row = 0, a.n - 1 do
		if used[row] then
			table.insert(rows, row)
		end
	end
	return rows
end

-- Pairs up the real fields (height, displacement X/Z) of every cascade into
-- complex FFTs of matching size: IFFT(A + iB) = a + ib when A and B are
-- Hermitian, which halves the number of transforms.
local function buildJobs(cascades: { Cascade }): { Job }
	local fieldsBySize: { [number]: { Field } } = {}
	local sizes = {}
	for _, cascade in cascades do
		local fields = fieldsBySize[cascade.n]
		if not fields then
			fields = {}
			fieldsBySize[cascade.n] = fields
			table.insert(sizes, cascade.n)
		end
		for _, kind in { FIELD_HEIGHT, FIELD_DISP_X, FIELD_DISP_Z } do
			table.insert(fields, { cascade = cascade, kind = kind })
		end
	end

	local jobs = {}
	for _, n in sizes do
		local fields = fieldsBySize[n]
		local nn = n * n
		local plan = Transform.plan(n)
		local re, im, zeros = table.create(nn, 0), table.create(nn, 0), table.create(nn, 0)
		for f = 1, #fields, 2 do
			local a, b = fields[f], fields[f + 1]
			table.insert(jobs, {
				plan = plan,
				nn = nn,
				re = re,
				im = im,
				zeros = zeros,
				a = a,
				b = b,
				rows = mergeRows(a.cascade, b and b.cascade),
			})
		end
	end
	return jobs
end

local function fieldTarget(field: Field): { number }
	local cascade = field.cascade
	if field.kind == FIELD_HEIGHT then
		return cascade.height
	elseif field.kind == FIELD_DISP_X then
		return cascade.dispX
	end
	return cascade.dispZ
end

-- h(k, t) = h0(k) e^(iwt) + conj(h0(-k)) e^(-iwt)
local function evolve(cascade: Cascade, t: number)
	local active = cascade.active
	local h0r, h0i, h0mr, h0mi = cascade.h0r, cascade.h0i, cascade.h0mr, cascade.h0mi
	local omega = cascade.omega
	local hr, hi = cascade.hr, cascade.hi
	for a = 1, cascade.activeCount do
		local index = active[a]
		local phase = omega[index] * t
		local c, s = math.cos(phase), math.sin(phase)
		local ar, ai, pr, pi = h0r[index], h0i[index], h0mr[index], h0mi[index]
		hr[index] = (ar + pr) * c + (pi - ai) * s
		hi[index] = (ai + pi) * c + (ar - pr) * s
	end
end

-- Adds one field's spectrum into the packed FFT input. The real slot takes
-- the spectrum S, the imaginary slot takes i*S. Displacement uses
-- D(k) = i * (k / |k|) * h(k) * choppiness so positive choppiness sharpens crests.
local function scatter(field: Field, imaginary: boolean, re: { number }, im: { number })
	local cascade = field.cascade
	local active, count = cascade.active, cascade.activeCount
	local hr, hi = cascade.hr, cascade.hi

	if field.kind == FIELD_HEIGHT then
		if imaginary then
			for a = 1, count do
				local index = active[a]
				re[index] -= hi[index]
				im[index] += hr[index]
			end
		else
			for a = 1, count do
				local index = active[a]
				re[index] += hr[index]
				im[index] += hi[index]
			end
		end
		return
	end

	local direction = if field.kind == FIELD_DISP_X then cascade.kxk else cascade.kzk
	local chop = cascade.settings.Choppiness
	if imaginary then
		for a = 1, count do
			local index = active[a]
			local f = direction[index] * chop
			re[index] -= f * hr[index]
			im[index] -= f * hi[index]
		end
	else
		for a = 1, count do
			local index = active[a]
			local f = direction[index] * chop
			re[index] -= f * hi[index]
			im[index] += f * hr[index]
		end
	end
end

-- Picks the Jacobian below which the configured share of texels spawns foam
local function calibrateFoam(cascade: Cascade)
	local coverage = math.clamp(cascade.settings.FoamCoverage or 0, 0, 1)
	if coverage <= 0 then
		cascade.foamThreshold = -math.huge
		return
	end

	local n = cascade.n
	local dispX, dispZ = cascade.dispX, cascade.dispZ
	local inv2 = 0.5 * cascade.invTexel
	local jacobians = table.create(n * n)
	for j = 0, n - 1 do
		local row = j * n + 1
		local rowUp = (if j == n - 1 then 0 else j + 1) * n + 1
		local rowDown = (if j == 0 then n - 1 else j - 1) * n + 1
		for i = 0, n - 1 do
			local right = if i == n - 1 then 0 else i + 1
			local left = if i == 0 then n - 1 else i - 1
			local dxx = (dispX[row + right] - dispX[row + left]) * inv2
			local dxz = (dispX[rowUp + i] - dispX[rowDown + i]) * inv2
			local dzx = (dispZ[row + right] - dispZ[row + left]) * inv2
			local dzz = (dispZ[rowUp + i] - dispZ[rowDown + i]) * inv2
			jacobians[j * n + i + 1] = (1 + dxx) * (1 + dzz) - dxz * dzx
		end
	end
	table.sort(jacobians)
	cascade.foamThreshold = jacobians[math.clamp(math.round(coverage * #jacobians), 1, #jacobians)]
end

local function postProcess(cascade: Cascade, threshold: number, sharpness: number, strength: number, decay: number)
	local n = cascade.n
	local heights, dispX, dispZ = cascade.height, cascade.dispX, cascade.dispZ
	local foam, data = cascade.foam, cascade.data
	local inv2 = 0.5 * cascade.invTexel

	for j = 0, n - 1 do
		local row = j * n + 1
		local rowUp = (if j == n - 1 then 0 else j + 1) * n + 1
		local rowDown = (if j == 0 then n - 1 else j - 1) * n + 1
		for i = 0, n - 1 do
			local right = if i == n - 1 then 0 else i + 1
			local left = if i == 0 then n - 1 else i - 1
			local index = row + i

			local hx = (heights[row + right] - heights[row + left]) * inv2
			local hz = (heights[rowUp + i] - heights[rowDown + i]) * inv2
			local dxx = (dispX[row + right] - dispX[row + left]) * inv2
			local dxz = (dispX[rowUp + i] - dispX[rowDown + i]) * inv2
			local dzx = (dispZ[row + right] - dispZ[row + left]) * inv2
			local dzz = (dispZ[rowUp + i] - dispZ[rowDown + i]) * inv2

			-- Tangents of the displaced surface and their cross product
			local jxx, jzz = 1 + dxx, 1 + dzz
			local jacobian = jxx * jzz - dxz * dzx
			local ny = if jacobian > 0.15 then jacobian else 0.15
			local gx = (hz * dzx - jzz * hx) / ny
			local gz = (dxz * hx - hz * jxx) / ny

			local f = foam[index] * decay
			local spawn = (threshold - jacobian) * sharpness
			if spawn > 1 then
				spawn = 1
			end
			spawn *= strength
			if spawn > f then
				f = spawn
			end
			if f < 0.004 then
				f = 0
			end
			foam[index] = f

			local base = (index - 1) * STRIDE
			data[base + 1] = dispX[index]
			data[base + 2] = heights[index]
			data[base + 3] = dispZ[index]
			data[base + 4] = gx
			data[base + 5] = gz
			data[base + 6] = f
		end
	end
end

-- 2x2 box filter from each mip into the next
local function buildMips(cascade: Cascade)
	local mips = cascade.mips
	for m = 2, #mips do
		local source, target = mips[m - 1], mips[m]
		local sn, tn = source.n, target.n
		local s, t = source.data, target.data
		for j = 0, tn - 1 do
			local row0 = 2 * j * sn
			local row1 = row0 + sn
			for i = 0, tn - 1 do
				local a = (row0 + 2 * i) * STRIDE
				local b = a + STRIDE
				local c = (row1 + 2 * i) * STRIDE
				local d = c + STRIDE
				local o = (j * tn + i) * STRIDE
				t[o + 1] = (s[a + 1] + s[b + 1] + s[c + 1] + s[d + 1]) * 0.25
				t[o + 2] = (s[a + 2] + s[b + 2] + s[c + 2] + s[d + 2]) * 0.25
				t[o + 3] = (s[a + 3] + s[b + 3] + s[c + 3] + s[d + 3]) * 0.25
				t[o + 4] = (s[a + 4] + s[b + 4] + s[c + 4] + s[d + 4]) * 0.25
				t[o + 5] = (s[a + 5] + s[b + 5] + s[c + 5] + s[d + 5]) * 0.25
				local foam = (s[a + 6] + s[b + 6] + s[c + 6] + s[d + 6]) * (0.25 * FOAM_MIP_GAIN)
				t[o + 6] = if foam > 1 then 1 else foam
			end
		end
	end
end

function Simulation.new(config: any)
	local self = setmetatable({
		config = config,
		cascades = {} :: { Cascade },
		jobs = {} :: { Job },
		time = 0,
		calibratePending = true,
	}, Simulation)
	self:Rebuild()
	return self
end

-- Regenerates every cascade from the current config (spectrum, band or size changes)
function Simulation:Rebuild()
	local config = self.config
	local spectra = {}
	local totalVariance = 0
	for index, settings in config.Cascades do
		local spectrum = Spectrum.build(config, settings, index)
		spectra[index] = spectrum
		totalVariance += spectrum.variance
	end

	-- Significant wave height Hs = 4 * standard deviation of the surface
	local scale = if totalVariance > 0 then (config.WaveHeight / 4) / math.sqrt(totalVariance) else 0

	local cascades = {}
	for index, settings in config.Cascades do
		cascades[index] = buildCascade(index, settings, spectra[index], scale, config.Gravity)
	end
	self.cascades = cascades
	self.jobs = buildJobs(cascades)
	self.calibratePending = true
	self:Step(self.time, 0)
end

-- Re-derives the foam thresholds on the next step (after choppiness or coverage changes)
function Simulation:CalibrateFoam()
	self.calibratePending = true
end

function Simulation:Step(t: number, dt: number)
	self.time = t
	local config = self.config

	for _, cascade in self.cascades do
		evolve(cascade, t)
	end

	for _, job in self.jobs do
		local re, im, nn = job.re, job.im, job.nn
		table.move(job.zeros, 1, nn, 1, re)
		table.move(job.zeros, 1, nn, 1, im)
		scatter(job.a, false, re, im)
		local b = job.b
		if b then
			scatter(b, true, re, im)
		end
		Transform.inverse2D(job.plan, re, im, job.rows)
		table.move(re, 1, nn, 1, fieldTarget(job.a))
		if b then
			table.move(im, 1, nn, 1, fieldTarget(b))
		end
	end

	if self.calibratePending then
		self.calibratePending = false
		for _, cascade in self.cascades do
			calibrateFoam(cascade)
		end
	end

	local decay = math.exp(-math.max(dt, 0) / math.max(config.FoamDecay, 0.05))
	local sharpness = config.FoamSharpness
	for _, cascade in self.cascades do
		postProcess(cascade, cascade.foamThreshold, sharpness, cascade.settings.Foam or 1, decay)
		buildMips(cascade)
	end
end

-- Index into cascade.mips for a surface sampled every `spacing` studs.
-- `bias` widens the filter relative to the spacing (1.5 keeps waves shorter
-- than about three samples out of the vertices).
function Simulation.mipFor(cascade: Cascade, spacing: number, bias: number): number
	local level = math.round(math.log(math.max(spacing * bias / cascade.texel, 1e-6), 2))
	return math.clamp(level, 0, #cascade.mips - 1) + 1
end

-- Bilinearly samples one mip at a world position (undisplaced grid coordinates)
local function sampleMip(mip: Mip, x: number, z: number): (number, number, number, number, number, number)
	local n, data = mip.n, mip.data
	local scale, offset = mip.scale, mip.offset
	local u, v = x * scale + offset, z * scale + offset
	local iu, iv = math.floor(u), math.floor(v)
	local fu, fv = u - iu, v - iv
	iu %= n
	iv %= n
	local iu1 = if iu == n - 1 then 0 else iu + 1
	local iv1 = if iv == n - 1 then 0 else iv + 1
	local b00 = (iv * n + iu) * STRIDE
	local b10 = (iv * n + iu1) * STRIDE
	local b01 = (iv1 * n + iu) * STRIDE
	local b11 = (iv1 * n + iu1) * STRIDE
	local w11 = fu * fv
	local w10 = fu - w11
	local w01 = fv - w11
	local w00 = 1 - fu - fv + w11
	return data[b00 + 1] * w00 + data[b10 + 1] * w10 + data[b01 + 1] * w01 + data[b11 + 1] * w11,
		data[b00 + 2] * w00 + data[b10 + 2] * w10 + data[b01 + 2] * w01 + data[b11 + 2] * w11,
		data[b00 + 3] * w00 + data[b10 + 3] * w10 + data[b01 + 3] * w01 + data[b11 + 3] * w11,
		data[b00 + 4] * w00 + data[b10 + 4] * w10 + data[b01 + 4] * w01 + data[b11 + 4] * w11,
		data[b00 + 5] * w00 + data[b10 + 5] * w10 + data[b01 + 5] * w01 + data[b11 + 5] * w11,
		data[b00 + 6] * w00 + data[b10 + 6] * w10 + data[b01 + 6] * w01 + data[b11 + 6] * w11
end

Simulation.sampleMip = sampleMip

--[[
	Sum of all cascades at an undisplaced position: dispX, height, dispZ,
	slopeX, slopeZ, foam. `mips` optionally picks a mip index per cascade
	(defaults to full resolution).
]]
function Simulation:Sample(x: number, z: number, mips: { number }?): (number, number, number, number, number, number)
	local dx, h, dz, gx, gz, foam = 0, 0, 0, 0, 0, 0
	for index, cascade in self.cascades do
		local a, b, c, d, e, f = sampleMip(cascade.mips[if mips then mips[index] else 1], x, z)
		dx += a
		h += b
		dz += c
		gx += d
		gz += e
		foam += f
	end
	return dx, h, dz, gx, gz, math.min(foam, 1)
end

function Simulation:GetDisplacement(x: number, z: number, mips: { number }?): (number, number, number)
	local dx, h, dz = 0, 0, 0
	for index, cascade in self.cascades do
		local a, b, c = sampleMip(cascade.mips[if mips then mips[index] else 1], x, z)
		dx += a
		h += b
		dz += c
	end
	return dx, h, dz
end

return Simulation
