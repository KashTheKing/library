--!strict
--Settings

--[=[
	@class ClientSettings
	@deprecated v1.0.0 -- No longer maintained; kept for existing projects. There is no direct replacement.

	:::caution Deprecated
	ClientSettings is no longer maintained and is kept only for existing projects. There is no
	direct replacement in this library.
	:::

	A bare-bones key/value store for local (per-machine) settings. The module is a single shared
	table: read a setting by indexing it, write one by assigning to it, and every assignment fires
	the `SettingChanged` signal with the key and the new value. There are no `Get` / `Set`
	functions; plain indexing is the whole API. Values are kept in memory only, so they reset when
	the game restarts unless you save them yourself.

	The source code calls the class `LocalSettings` and the Wally package is
	`kashtheking/local-settings`; both refer to this module.

	```lua
	local ClientSettings = require(path.to.ClientSettings)

	ClientSettings.SettingChanged:Connect(function(key: string, value: any)
		print("Setting", key, "is now", value)
	end)

	ClientSettings.MusicVolume = 0.5 -- fires SettingChanged("MusicVolume", 0.5)
	print(ClientSettings.MusicVolume) -- 0.5
	ClientSettings.MusicVolume = nil -- removes it and fires SettingChanged("MusicVolume", nil)
	```

	Assigning fires the signal even when the value did not change. Do not assign to
	`SettingChanged` itself; it lives on the returned table, so writing to it replaces the signal
	instead of storing a setting. Depends on Sleitnick's
	[Signal](https://sleitnick.github.io/RbxUtil/api/Signal/), which Wally installs alongside it.

	**Credits:** the change event is [Signal](https://sleitnick.github.io/RbxUtil/api/Signal/), by [sleitnick](https://github.com/Sleitnick) ([sleitnick's RbxUtil](https://sleitnick.github.io/RbxUtil/)). Wally installs it.

	Installation and guide: [ClientSettings package page](/docs/packages/client-settings).
]=]
local LocalSettings = {

}

--[=[
	@type LocalSettings {}
	@within ClientSettings
	The type of the backing settings table (empty at compile time, since settings are added at runtime). Exported for scripts that want to annotate the module.
]=]
export type LocalSettings = typeof(LocalSettings)

--Return
local Signal = require(script.Parent.Signal)
local SettingChanged = Signal.new()

--[=[
	@prop SettingChanged Signal<string, any>
	@within ClientSettings
	@readonly
	Fires after any setting is assigned (`ClientSettings.Key = value`). Receives the key and the new value (`nil` when the setting was removed).
]=]
return setmetatable({
	SettingChanged = SettingChanged
}, {
	__index = LocalSettings,
	
	__newindex = function(_, index, value)
		LocalSettings[index] = value
		SettingChanged:Fire(index, value)
	end
})