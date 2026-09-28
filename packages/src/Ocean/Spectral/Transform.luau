--!native
--!optimize 2
--[[
	Transform

	In-place inverse 2D FFT over flat row-major arrays (1-indexed), with the
	real and imaginary parts in separate tables. Uses radix-4 passes when the
	size is a power of four and radix-2 passes otherwise.

	Computes x[n] = sum_k X[k] * e^(+2*pi*i*k*n/N) along both axes, without
	the 1/N normalisation (the wave amplitudes already account for it).

	(Part of the FFT sea, see Spectral.)
]]

local Transform = {}

type Stage = {
	span: number,
	quarter: number,
	c1: { number },
	s1: { number },
	c2: { number },
	s2: { number },
	c3: { number },
	s3: { number },
}

export type Plan = {
	n: number,
	radix4: boolean,
	swapA: { number },
	swapB: { number },
	swapCount: number,
	stages: { Stage },
}

local function digitReverse(value: number, digits: number, base: number): number
	local result = 0
	for _ = 1, digits do
		result = result * base + value % base
		value //= base
	end
	return result
end

function Transform.plan(n: number): Plan
	local log2 = math.round(math.log(n, 2))
	assert(2 ^ log2 == n and n >= 4, "FFT size must be a power of two >= 4")

	local radix4 = log2 % 2 == 0
	local base = if radix4 then 4 else 2
	local digits = if radix4 then log2 // 2 else log2

	local swapA, swapB = {}, {}
	for i = 0, n - 1 do
		local r = digitReverse(i, digits, base)
		if r > i then
			table.insert(swapA, i)
			table.insert(swapB, r)
		end
	end

	local stages = {}
	local span = base
	while span <= n do
		local quarter = span // base
		local stage: Stage = {
			span = span,
			quarter = quarter,
			c1 = table.create(quarter),
			s1 = table.create(quarter),
			c2 = table.create(quarter),
			s2 = table.create(quarter),
			c3 = table.create(quarter),
			s3 = table.create(quarter),
		}
		for j = 0, quarter - 1 do
			local angle = 2 * math.pi * j / span
			stage.c1[j + 1], stage.s1[j + 1] = math.cos(angle), math.sin(angle)
			stage.c2[j + 1], stage.s2[j + 1] = math.cos(2 * angle), math.sin(2 * angle)
			stage.c3[j + 1], stage.s3[j + 1] = math.cos(3 * angle), math.sin(3 * angle)
		end
		table.insert(stages, stage)
		span *= base
	end

	return {
		n = n,
		radix4 = radix4,
		swapA = swapA,
		swapB = swapB,
		swapCount = #swapA,
		stages = stages,
	}
end

local function permute(plan: Plan, re: { number }, im: { number }, base: number, stride: number)
	local swapA, swapB = plan.swapA, plan.swapB
	for s = 1, plan.swapCount do
		local a = base + swapA[s] * stride
		local b = base + swapB[s] * stride
		re[a], re[b] = re[b], re[a]
		im[a], im[b] = im[b], im[a]
	end
end

local function pass4(plan: Plan, re: { number }, im: { number }, base: number, stride: number)
	permute(plan, re, im, base, stride)
	local n = plan.n
	for _, stage in plan.stages do
		local span, quarter = stage.span, stage.quarter
		local c1, s1, c2, s2, c3, s3 = stage.c1, stage.s1, stage.c2, stage.s2, stage.c3, stage.s3
		local step = quarter * stride
		for j = 0, quarter - 1 do
			local w1r, w1i = c1[j + 1], s1[j + 1]
			local w2r, w2i = c2[j + 1], s2[j + 1]
			local w3r, w3i = c3[j + 1], s3[j + 1]
			for g = j, n - 1, span do
				local p0 = base + g * stride
				local p1 = p0 + step
				local p2 = p1 + step
				local p3 = p2 + step

				local a0r, a0i = re[p0], im[p0]
				local xr, xi = re[p1], im[p1]
				local a1r, a1i = xr * w1r - xi * w1i, xr * w1i + xi * w1r
				xr, xi = re[p2], im[p2]
				local a2r, a2i = xr * w2r - xi * w2i, xr * w2i + xi * w2r
				xr, xi = re[p3], im[p3]
				local a3r, a3i = xr * w3r - xi * w3i, xr * w3i + xi * w3r

				local t0r, t0i = a0r + a2r, a0i + a2i
				local t1r, t1i = a0r - a2r, a0i - a2i
				local t2r, t2i = a1r + a3r, a1i + a3i
				local t3r, t3i = a1r - a3r, a1i - a3i

				re[p0], im[p0] = t0r + t2r, t0i + t2i
				re[p2], im[p2] = t0r - t2r, t0i - t2i
				re[p1], im[p1] = t1r - t3i, t1i + t3r
				re[p3], im[p3] = t1r + t3i, t1i - t3r
			end
		end
	end
end

local function pass2(plan: Plan, re: { number }, im: { number }, base: number, stride: number)
	permute(plan, re, im, base, stride)
	local n = plan.n
	for _, stage in plan.stages do
		local span, half = stage.span, stage.quarter
		local c1, s1 = stage.c1, stage.s1
		local step = half * stride
		for j = 0, half - 1 do
			local wr, wi = c1[j + 1], s1[j + 1]
			for g = j, n - 1, span do
				local a = base + g * stride
				local b = a + step
				local br, bi = re[b], im[b]
				local tr = br * wr - bi * wi
				local ti = br * wi + bi * wr
				local ar, ai = re[a], im[a]
				re[b], im[b] = ar - tr, ai - ti
				re[a], im[a] = ar + tr, ai + ti
			end
		end
	end
end

--[[
	Transforms rows first, then columns. `activeRows` optionally lists the
	0-based rows that can hold non-zero input; all other rows are skipped in
	the first pass (their transform is zero anyway).
]]
function Transform.inverse2D(plan: Plan, re: { number }, im: { number }, activeRows: { number }?)
	local n = plan.n
	local pass = if plan.radix4 then pass4 else pass2
	if activeRows then
		for _, row in activeRows do
			pass(plan, re, im, row * n + 1, 1)
		end
	else
		for row = 0, n - 1 do
			pass(plan, re, im, row * n + 1, 1)
		end
	end
	for column = 0, n - 1 do
		pass(plan, re, im, column + 1, n)
	end
end

return Transform
