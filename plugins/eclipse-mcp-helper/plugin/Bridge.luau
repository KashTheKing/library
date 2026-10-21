--!strict
-- The plugin's side of the local bridge. Studio plugins can't listen for connections, so the plugin long-polls the
-- bridge for commands, runs them one at a time, and posts each result back. Only 127.0.0.1 is ever contacted.

local HttpService = game:GetService("HttpService")

local Bridge = {}
Bridge.__index = Bridge

export type Status = "connecting" | "connected" | "offline" | "blocked"

export type Bridge = typeof(setmetatable(
	{} :: {
		url: string,
		studio: string,
		info: any,
		status: Status,
		alive: boolean,
		onCommands: (commands: { any }) -> (),
		onPresence: (presence: any) -> (),
		onStatus: (status: Status, detail: string?) -> (),
	},
	Bridge
))

function Bridge.new(port: number, info: any, handlers: any): Bridge
	return setmetatable({
		url = "http://127.0.0.1:" .. port,
		studio = HttpService:GenerateGUID(false),
		info = info,
		status = "connecting" :: Status,
		alive = true,
		onCommands = handlers.onCommands,
		onPresence = handlers.onPresence,
		onStatus = handlers.onStatus,
	}, Bridge)
end

function Bridge.post(self: Bridge, path: string, body: any): (boolean, any, number?)
	body.studio = self.studio
	local ok, response = pcall(HttpService.RequestAsync, HttpService, {
		Url = self.url .. path,
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = HttpService:JSONEncode(body),
	})
	if not ok then
		return false, tostring(response), nil
	end
	local decoded = nil
	pcall(function()
		decoded = HttpService:JSONDecode(response.Body)
	end)
	if not response.Success then
		return false, decoded or response.StatusMessage, response.StatusCode
	end
	return true, decoded, response.StatusCode
end

function Bridge.setStatus(self: Bridge, status: Status, detail: string?)
	if self.status ~= status then
		self.status = status
		self.onStatus(status, detail)
	end
end

local function blocked(message: any): boolean
	local text = string.lower(tostring(message))
	return string.find(text, "permission", 1, true) ~= nil
		or string.find(text, "not allowed", 1, true) ~= nil
		or string.find(text, "denied", 1, true) ~= nil
end

function Bridge.hello(self: Bridge): boolean
	local ok, body = self:post("/plugin/hello", table.clone(self.info))
	if ok and body and body.ok then
		self:setStatus("connected")
		if body.presence then
			self.onPresence(body.presence)
		end
		return true
	end
	if blocked(body) then
		self:setStatus("blocked", "Allow this plugin to reach 127.0.0.1 (Studio asks once).")
	else
		self:setStatus("offline", "Start the bridge on this computer: node bridge/src/bridge.js (helpers start it on their own).")
	end
	return false
end

function Bridge.start(self: Bridge)
	task.spawn(function()
		local wait = 1
		while self.alive do
			if self.status ~= "connected" then
				if not self:hello() then
					task.wait(wait)
					wait = math.min(wait * 2, 10)
					continue
				end
				wait = 1
			end
			local ok, body, code = self:post("/plugin/poll", {})
			if not self.alive then
				break
			end
			if ok and body then
				if body.presence then
					self.onPresence(body.presence)
				end
				if body.commands and #body.commands > 0 then
					self.onCommands(body.commands)
				end
			elseif code == 404 then
				self:setStatus("connecting") -- the bridge restarted; say hello again
			else
				self:setStatus("offline", "Lost the bridge; retrying.")
				task.wait(1)
			end
		end
	end)
end

function Bridge.result(self: Bridge, id: string, ok: boolean, value: any, summary: string?)
	task.spawn(function()
		local body: any = { id = id, ok = ok, summary = summary }
		if ok then
			body.result = value
		else
			body.error = value
		end
		local sent, err = self:post("/plugin/result", body)
		if not sent then
			-- A value JSON can't hold: still answer, so the helper isn't left waiting.
			self:post("/plugin/result", { id = id, ok = false, error = "Result could not be sent: " .. tostring(err) })
		end
	end)
end

function Bridge.state(self: Bridge, state: any)
	if self.status == "connected" then
		task.spawn(self.post, self, "/plugin/state", state)
	end
end

function Bridge.control(self: Bridge, body: any)
	task.spawn(function()
		local ok, response = self:post("/plugin/control", body)
		if ok and response and response.presence then
			self.onPresence(response.presence)
		end
	end)
end

function Bridge.stop(self: Bridge)
	self.alive = false
end

return Bridge
