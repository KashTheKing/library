-- This script starts the ocean for you: nothing to edit, nothing to call. Leave it right here,
-- next to the module it belongs to (the Infinite Ocean plugin put it here). Delete the module and
-- this script goes with it. (The check below only stops the plugin's own bundled copy from
-- starting.)
local top: Instance = script
local bundled = false -- inside a copy of the plugin kept in the place (ServerStorage.OceanPlugin)
while top.Parent and top.Parent ~= game do
	top = top.Parent
	bundled = bundled or top.Name == "OceanPlugin"
end
if top.ClassName ~= "PluginDebugService" and not bundled then
	require(script.Parent).Init()
end
