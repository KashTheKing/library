--!strict
--Settings

local LocalSettings = {

}

export type LocalSettings = typeof(LocalSettings)

--Return
local Signal = require(script.Parent.Signal)
local SettingChanged = Signal.new()

return setmetatable({
	SettingChanged = SettingChanged
}, {
	__index = LocalSettings,
	
	__newindex = function(_, index, value)
		LocalSettings[index] = value
		SettingChanged:Fire(index, value)
	end
})