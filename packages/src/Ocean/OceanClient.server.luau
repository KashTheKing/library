-- This script starts the ocean for you: nothing to edit, nothing to call. Leave it right here,
-- next to the module it belongs to (the Infinite Ocean plugin put it here). Delete the module and
-- this script goes with it. (The check below only stops the plugin's own bundled copy from
-- starting during a playtest.)
local top: Instance = script
while top.Parent and top.Parent ~= game do
	top = top.Parent
end
if top.ClassName ~= "PluginDebugService" then
	require(script.Parent).Init()
end
