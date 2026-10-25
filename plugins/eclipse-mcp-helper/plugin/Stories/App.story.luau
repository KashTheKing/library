-- UI Labs story: the whole helper panel with sample helpers. Every button works against the sample state, and the
-- controls switch the bridge and Eclipse status.
local Root = script.Parent.Parent
local Fusion = require(Root.Packages.Fusion)
local App = require(Root.UI.App)
local Mock = require(script.Parent.Mock)

return {
	fusion = Fusion,
	controls = {
		Connection = "connected", -- connected | connecting | offline | blocked
		EclipseOpen = true,
		AnimationOpen = true,
		Frame = 12,
	},
	story = function(props)
		local scope = Fusion.scoped(Fusion)
		local agents = scope:Value(table.clone(Mock.Agents))
		local state = {
			Connection = props.controls.Connection,
			Detail = scope:Computed(function(use)
				local c = use(props.controls.Connection)
				return if c == "offline" then "Start the bridge on this computer: node bridge/src/bridge.js (helpers start it on their own)."
					elseif c == "blocked" then "Allow this plugin to reach 127.0.0.1 (Studio asks once)."
					else nil
			end),
			Eclipse = scope:Computed(function(use)
				return {
					found = use(props.controls.EclipseOpen),
					active = use(props.controls.EclipseOpen) and use(props.controls.AnimationOpen),
					version = 6,
					frame = use(props.controls.Frame),
					fps = 60,
				}
			end),
			Agents = agents,
			Leases = scope:Value(Mock.Leases),
			Activity = scope:Value(Mock.Activity),
			Paused = scope:Value(false),
			ShowPresence = scope:Value(true),
		}
		local function setStopped(id, stopped)
			local list = {}
			for _, a in Fusion.peek(agents) do
				local copy = table.clone(a)
				if copy.id == id then
					copy.stopped = stopped
				end
				table.insert(list, copy)
			end
			agents:set(list)
		end
		local ui = App(scope, {
			State = state :: any,
			Parent = props.target,
			OnPause = function(p)
				state.Paused:set(p)
			end,
			OnShowPresence = function(on)
				state.ShowPresence:set(on)
			end,
			OnStop = function(id)
				setStopped(id, true)
			end,
			OnResume = function(id)
				setStopped(id, false)
			end,
		})
		return function()
			Fusion.doCleanup(scope)
			ui:Destroy()
		end
	end,
}
