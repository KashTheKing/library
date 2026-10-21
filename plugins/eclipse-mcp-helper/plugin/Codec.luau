--!strict
-- Turns Roblox values into JSON-safe tables for helpers, and back. Instances travel as paths from the DataModel
-- ({"$inst": ["Workspace", "Rig", "Torso"], "id": ...}); the id is the instance's debug id, so a helper can point
-- at one of two parts that share a name.

local Codec = {}

local byId: { [string]: Instance } = setmetatable({}, { __mode = "v" }) :: any

local function round(n: number): number
	-- Six decimals is plenty for poses and keeps the JSON readable.
	return math.floor(n * 1e6 + 0.5) / 1e6
end

local function debugId(instance: Instance): string?
	local ok, id = pcall(function()
		return (instance :: any):GetDebugId(0)
	end)
	return if ok and type(id) == "string" then id else nil
end

function Codec.pathOf(instance: Instance, root: Instance): { string }?
	local names = {}
	local node: Instance? = instance
	while node and node ~= root do
		table.insert(names, 1, node.Name)
		node = node.Parent
	end
	return if node == root then names else nil
end

function Codec.resolvePath(names: { string }, root: Instance): Instance?
	local node: Instance? = root
	for i, name in names do
		if not node then
			return nil
		end
		local child = (node :: Instance):FindFirstChild(name)
		if not child and i == 1 and node == root then
			local ok, service = pcall(function()
				return (root :: any):GetService(name)
			end)
			child = if ok then service else nil
		end
		node = child
	end
	return node
end

function Codec.encode(value: any, root: Instance, depth: number?): any
	local d = depth or 0
	if d > 12 then
		return "<too deep>"
	end
	local kind = typeof(value)
	if kind == "nil" or kind == "boolean" or kind == "string" then
		return value
	elseif kind == "number" then
		return if value ~= value or value == math.huge or value == -math.huge then tostring(value) else value
	elseif kind == "Instance" then
		local id = debugId(value)
		if id then
			byId[id] = value
		end
		return { ["$inst"] = Codec.pathOf(value, root) or { value.Name }, id = id, class = value.ClassName }
	elseif kind == "CFrame" then
		local c = { value:GetComponents() }
		for i, n in c do
			c[i] = round(n)
		end
		local rx, ry, rz = value:ToOrientation()
		return {
			["$cf"] = c,
			p = { round(value.X), round(value.Y), round(value.Z) },
			r = { round(math.deg(rx)), round(math.deg(ry)), round(math.deg(rz)) },
		}
	elseif kind == "Vector3" then
		return { ["$v3"] = { round(value.X), round(value.Y), round(value.Z) } }
	elseif kind == "Vector2" then
		return { ["$v2"] = { round(value.X), round(value.Y) } }
	elseif kind == "Color3" then
		return { ["$c3"] = { round(value.R), round(value.G), round(value.B) } }
	elseif kind == "UDim2" then
		return { ["$udim2"] = { value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset } }
	elseif kind == "EnumItem" then
		local enumName = string.gsub(tostring(value.EnumType), "^Enum%.", "")
		return { ["$enum"] = enumName .. "." .. value.Name }
	elseif kind == "table" then
		local out = {}
		for k, v in value do
			local key = if type(k) == "number" then k else tostring(k)
			out[key] = Codec.encode(v, root, d + 1)
		end
		return out
	end
	return tostring(value)
end

local function numbers(list: any, count: number, what: string): { number }
	assert(type(list) == "table" and #list == count, what .. " needs " .. count .. " numbers")
	for _, n in list do
		assert(type(n) == "number" and n == n and math.abs(n) < math.huge, what .. " needs finite numbers")
	end
	return list
end

local function decodeCFrame(v: any): CFrame
	if type(v) == "table" and #v > 0 then
		local c = numbers(v, 12, "CFrame")
		return CFrame.new(c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12])
	end
	assert(type(v) == "table", "CFrame must be 12 numbers or {p, r}")
	local p: { number } = if v.p then numbers(v.p, 3, "CFrame p") else { 0, 0, 0 }
	local r: { number } = if v.r then numbers(v.r, 3, "CFrame r") else { 0, 0, 0 }
	return CFrame.new(p[1], p[2], p[3]) * CFrame.fromOrientation(math.rad(r[1]), math.rad(r[2]), math.rad(r[3]))
end

function Codec.resolveInstance(v: any, root: Instance): Instance
	if type(v) == "string" then
		local found = Codec.resolvePath(string.split(v, "."), root)
		assert(found, "No instance at " .. v)
		return found
	end
	assert(type(v) == "table", "Expected an instance path")
	local id = v["$id"] or v.id
	if type(id) == "string" and byId[id] and byId[id].Parent then
		return byId[id]
	end
	local names = v["$inst"]
	assert(type(names) == "table", "Expected {\"$inst\": [names]}")
	local found = Codec.resolvePath(names, root)
	assert(found, "No instance at " .. table.concat(names, "."))
	return found
end

-- Fields that hold instances in Eclipse API requests; plain strings there are paths, not text.
local INSTANCE_FIELDS = { Target = true, Targets = true, Parent = true }

function Codec.decode(value: any, root: Instance, field: string?): any
	if type(value) ~= "table" then
		if type(value) == "string" and field and INSTANCE_FIELDS[field] and not string.match(value, "^folder_") then
			-- Timeline folder ids start with folder_; anything else in these fields is an instance path.
			return Codec.resolveInstance(value, root)
		end
		return value
	end
	if value["$inst"] ~= nil or value["$id"] ~= nil then
		return Codec.resolveInstance(value, root)
	elseif value["$cf"] ~= nil then
		return decodeCFrame(value["$cf"])
	elseif value["$v3"] ~= nil then
		local n = numbers(value["$v3"], 3, "Vector3")
		return Vector3.new(n[1], n[2], n[3])
	elseif value["$v2"] ~= nil then
		local n = numbers(value["$v2"], 2, "Vector2")
		return Vector2.new(n[1], n[2])
	elseif value["$c3"] ~= nil then
		local n = numbers(value["$c3"], 3, "Color3")
		return Color3.new(n[1], n[2], n[3])
	elseif value["$udim2"] ~= nil then
		local n = numbers(value["$udim2"], 4, "UDim2")
		return UDim2.new(n[1], n[2], n[3], n[4])
	elseif value["$enum"] ~= nil then
		local text = string.gsub(tostring(value["$enum"]), "^Enum%.", "")
		local enumName, itemName = string.match(text, "^([%w_]+)%.([%w_]+)$")
		assert(enumName, "Enum must look like EasingStyle.Quad")
		local ok, item = pcall(function()
			return (Enum :: any)[enumName :: string][itemName :: string]
		end)
		assert(ok and item, "Unknown enum " .. tostring(value["$enum"]))
		return item
	end
	local out = {}
	for k, v in value do
		local childField = if type(k) == "number" then field else k
		out[k] = Codec.decode(v, root, childField)
	end
	return out
end

return Codec
