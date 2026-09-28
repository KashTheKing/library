--!strict
--[=[
	@class HttpStore
	Saves and loads replays through a plain HTTP backend. The server contract:

	- `GET    <base>`         → JSON array of keys
	- `GET    <base>/<key>`   → raw replay bytes (404 when missing)
	- `PUT    <base>/<key>`   → stores the raw body
	- `DELETE <base>/<key>`   → removes the replay

	An optional bearer token is sent as `Authorization: Bearer <token>`.
	Requires HttpService to be enabled and runs on the server or in Studio.
]=]

local HttpService = game:GetService("HttpService")

local HttpStore = {}

local function headers(token: string?): { [string]: string }
	local h = { ["Content-Type"] = "application/octet-stream" }
	if token and token ~= "" then
		h["Authorization"] = `Bearer {token}`
	end
	return h
end

local function url(base: string, key: string?): string
	local trimmed = base:gsub("/+$", "")
	return if key then `{trimmed}/{HttpService:UrlEncode(key)}` else trimmed
end

local function request(method: string, target: string, token: string?, body: string?): (boolean, string, number)
	local response = HttpService:RequestAsync({
		Url = target,
		Method = method,
		Headers = headers(token),
		Body = body,
	})
	return response.Success, response.Body, response.StatusCode
end

function HttpStore.save(key: string, blob: buffer, base: string, token: string?)
	local ok, body, code = request("PUT", url(base, key), token, buffer.tostring(blob))
	if not ok then
		error(`HTTP {code}: {body}`)
	end
end

function HttpStore.load(key: string, base: string, token: string?): buffer?
	local ok, body, code = request("GET", url(base, key), token)
	if code == 404 then
		return nil
	end
	if not ok then
		error(`HTTP {code}: {body}`)
	end
	return buffer.fromstring(body)
end

function HttpStore.exists(key: string, base: string, token: string?): boolean
	local ok, _, code = request("GET", url(base, key), token)
	return ok and code ~= 404
end

function HttpStore.list(base: string, token: string?): { string }
	local ok, body, code = request("GET", url(base), token)
	if not ok then
		error(`HTTP {code}: {body}`)
	end
	local decoded = HttpService:JSONDecode(body)
	local keys = {}
	for _, k in decoded do
		if typeof(k) == "string" then
			table.insert(keys, k)
		end
	end
	return keys
end

function HttpStore.remove(key: string, base: string, token: string?)
	local ok, body, code = request("DELETE", url(base, key), token)
	if not ok and code ~= 404 then
		error(`HTTP {code}: {body}`)
	end
end

return HttpStore
