-- Loads the built plugin (rojo build) in Lune and runs its modules with a fake `script`, so the tests exercise the
-- exact code that ships. Usage: lune run test/run.luau <path to built .rbxm>
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local Harness = {}

function Harness.load(path: string, stubs: { [string]: any }?)
	local root = roblox.deserializeModel(fs.readFile(path))[1]
	local cache = {}
	local game = roblox.Instance.new("DataModel")
	local workspace = game:GetService("Workspace")
	local env
	local function load(module)
		if stubs and stubs[module.Name] then
			return stubs[module.Name]
		end
		if cache[module] ~= nil then
			return cache[module]
		end
		local fn = luau.load(module.Source, { debugName = module:GetFullName(), environment = env(module) })
		local result = fn()
		cache[module] = result
		return result
	end
	function env(module)
		return setmetatable({
			script = module,
			require = load,
			game = game,
			workspace = workspace,
			CFrame = roblox.CFrame, Vector3 = roblox.Vector3, Vector2 = roblox.Vector2, Color3 = roblox.Color3,
			UDim2 = roblox.UDim2, UDim = roblox.UDim, Enum = roblox.Enum, Instance = roblox.Instance, Font = roblox.Font,
			typeof = roblox.typeof or typeof,
			task = require("@lune/task"),
		}, { __index = _G })
	end
	return {
		root = root,
		game = game,
		workspace = workspace,
		require = function(name)
			local found = root:FindFirstChild(name, true)
			assert(found, "no module " .. name)
			return load(found)
		end,
	}
end

local passed, failed = 0, 0
function Harness.test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		print("ok - " .. name)
	else
		failed += 1
		print("not ok - " .. name .. "\n    " .. tostring(err))
	end
end

function Harness.eq(a, b, msg: string?)
	if a ~= b then
		error((msg or "values differ") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
	end
end

function Harness.finish()
	print(string.format("# pass %d\n# fail %d", passed, failed))
	if failed > 0 then
		require("@lune/process").exit(1)
	end
end

return Harness
