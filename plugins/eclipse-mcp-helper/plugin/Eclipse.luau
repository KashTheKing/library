--!strict
-- Talks to Eclipse Animator through its own extension API: Eclipse puts a BindableFunction per open session in
-- CoreGui.EclipseAnimatorAPI, and Invoke(action, request) returns { ok, result } or { ok = false, error }.
-- The helper never touches Eclipse's code or saves; it only uses this public endpoint.

local Eclipse = {}

Eclipse.MinVersion = 6

export type Endpoint = {
	session: string,
	version: number,
	invoke: (action: string, request: any) -> (boolean, any),
}

local function wrap(fn: BindableFunction): Endpoint
	return {
		session = fn.Name,
		version = tonumber(fn:GetAttribute("APIVersion")) or 0,
		invoke = function(action: string, request: any)
			local ok, response = pcall(function()
				return fn:Invoke(action, request)
			end)
			if not ok then
				return false, "Eclipse didn't answer: " .. tostring(response)
			end
			if type(response) ~= "table" then
				return false, "Eclipse gave an unexpected answer"
			end
			if response.ok then
				return true, response.result
			end
			return false, tostring(response.error)
		end,
	}
end

-- Every open Eclipse session, newest API first. `container` defaults to CoreGui (tests pass their own).
function Eclipse.sessions(container: Instance?): { Endpoint }
	local root = container or game:GetService("CoreGui")
	local registry = root:FindFirstChild("EclipseAnimatorAPI")
	local out = {}
	if registry then
		for _, child in registry:GetChildren() do
			if child:IsA("BindableFunction") and string.sub(child.Name, 1, 8) == "Session-" then
				table.insert(out, wrap(child))
			end
		end
	end
	table.sort(out, function(a, b)
		return a.version > b.version
	end)
	return out
end

-- The session to drive: the one that has an animation open, else the first.
function Eclipse.pick(container: Instance?, wanted: string?): Endpoint?
	local list = Eclipse.sessions(container)
	if wanted then
		for _, e in list do
			if e.session == wanted then
				return e
			end
		end
		return nil
	end
	for _, e in list do
		local ok, info = e.invoke("GetInfo", {})
		if ok and info.Active then
			return e
		end
	end
	return list[1]
end

return Eclipse
