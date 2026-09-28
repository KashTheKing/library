--!strict
--[[
	Spectrum

	Builds the starting wave amplitudes h0(k) of one cascade from a
	directional Phillips spectrum. Amplitudes come from a seeded generator,
	so every client builds exactly the same ocean.

	The amplitudes are unnormalised: `variance` is the expected height
	variance they produce, which the simulation uses to scale all cascades
	together to the configured wave height.

	(Part of the FFT sea, see Spectral.)
]]

local Spectrum = {}

export type Settings = {
	Seed: number,
	WindSpeed: number,
	WindDirection: number,
	DirectionalSpread: number,
	WindAlignment: number,
	SmallWaveCutoff: number,
	Gravity: number,
}

export type CascadeShape = {
	PatchSize: number,
	Resolution: number,
	MinWavelength: number,
	MaxWavelength: number,
	Amplitude: number,
}

export type Result = {
	h0r: { number },
	h0i: { number },
	variance: number,
}

local TAU = 2 * math.pi

local function phillips(
	kx: number,
	kz: number,
	windX: number,
	windZ: number,
	largestWave: number,
	spread: number,
	alignment: number,
	cutoff: number
): number
	local k2 = kx * kx + kz * kz
	if k2 < 1e-12 then
		return 0
	end
	local k = math.sqrt(k2)
	local cosTheta = (kx * windX + kz * windZ) / k
	local directional = math.abs(cosTheta) ^ spread
	if cosTheta < 0 then
		directional *= 1 - alignment
	end
	return math.exp(-1 / (k2 * largestWave * largestWave)) / (k2 * k2) * directional * math.exp(-k2 * cutoff * cutoff)
end

local function gaussianPair(rng: Random): (number, number)
	local u1 = math.max(rng:NextNumber(), 1e-12)
	local u2 = rng:NextNumber()
	local r = math.sqrt(-2 * math.log(u1))
	return r * math.cos(TAU * u2), r * math.sin(TAU * u2)
end

function Spectrum.build(settings: Settings, cascade: CascadeShape, cascadeIndex: number): Result
	local n = cascade.Resolution
	local half = n // 2
	local dk = TAU / cascade.PatchSize
	local kMin = TAU / math.max(cascade.MaxWavelength, 1e-6)
	local kMax = TAU / math.max(cascade.MinWavelength, 1e-6)

	local windAngle = math.rad(settings.WindDirection)
	local windX, windZ = math.cos(windAngle), math.sin(windAngle)
	local largestWave = settings.WindSpeed * settings.WindSpeed / math.max(settings.Gravity, 1e-3)
	local spread = settings.DirectionalSpread
	local alignment = math.clamp(settings.WindAlignment, 0, 1)
	local cutoff = settings.SmallWaveCutoff
	local amplitude = cascade.Amplitude

	local rng = Random.new(settings.Seed * 7919 + cascadeIndex * 104729)
	local h0r = table.create(n * n, 0)
	local h0i = table.create(n * n, 0)
	local variance = 0

	for j = 0, n - 1 do
		local mz = if j < half then j else j - n
		for i = 0, n - 1 do
			local mx = if i < half then i else i - n
			-- Always draw, so the random stream never depends on the band limits
			local g1, g2 = gaussianPair(rng)

			-- The Nyquist row and column cannot be made Hermitian for the
			-- horizontal displacement, so they stay empty.
			if i ~= half and j ~= half then
				local kx, kz = mx * dk, mz * dk
				local k = math.sqrt(kx * kx + kz * kz)
				if k > 0 and k >= kMin and k < kMax then
					local a = math.sqrt(phillips(kx, kz, windX, windZ, largestWave, spread, alignment, cutoff))
						* dk
						* amplitude
					local index = j * n + i + 1
					h0r[index] = g1 * a
					h0i[index] = g2 * a
					-- E|h(k,t)|^2 = E|h0(k)|^2 + E|h0(-k)|^2 = 4a^2
					variance += 4 * a * a
				end
			end
		end
	end

	return { h0r = h0r, h0i = h0i, variance = variance }
end

return Spectrum
