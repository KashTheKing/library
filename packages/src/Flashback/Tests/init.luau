--!strict
--[=[
	@class FlashbackTests
	@ignore
	Minimal test runner. Each sibling ModuleScript returns a table of
	name -> function(t) where t provides assertion helpers. Run with
	require(ReplicatedStorage.Flashback.Tests).run() and inspect the returned
	summary. Instances already tagged for recording are untagged for the run
	and re-tagged afterwards. Deleting this folder removes all test code from
	a build.
]=]

local CollectionService = game:GetService("CollectionService")

local Assert = require(script.Assert)
local Recorder = require(script.Parent.Recorder)

export type Summary = { passed: number, failed: number, failures: { string } }

local Tests = {}

function Tests.run(filter: string?): Summary
	local summary: Summary = { passed = 0, failed = 0, failures = {} }
	local preTagged = CollectionService:GetTagged(Recorder.TAG)
	for _, inst in preTagged do
		inst:RemoveTag(Recorder.TAG)
	end
	for _, mod in script:GetChildren() do
		if not mod:IsA("ModuleScript") or not mod.Name:match("Spec$") or (filter and not mod.Name:find(filter)) then
			continue
		end
		local cases = require(mod) :: { [string]: (Assert.T) -> () }
		local names = {}
		for name in cases do
			table.insert(names, name)
		end
		table.sort(names)
		for _, name in names do
			local ok, err = pcall(cases[name] :: any, Assert)
			if ok then
				summary.passed += 1
			else
				summary.failed += 1
				table.insert(summary.failures, `{mod.Name}.{name}: {err}`)
			end
		end
	end
	for _, inst in preTagged do
		inst:AddTag(Recorder.TAG)
	end
	print(`Flashback tests: {summary.passed} passed, {summary.failed} failed`)
	for _, f in summary.failures do
		warn(f)
	end
	return summary
end

return Tests
