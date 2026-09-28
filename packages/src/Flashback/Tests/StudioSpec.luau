--!strict
local Assert = require(script.Parent.Assert)
local Studio = require(script.Parent.Parent.Studio)

return {
	createRecorderAppliesOptions = function(t: Assert.T)
		local rec =
			Studio.createRecorder({ tickRate = 120, keyframeEvery = 0, watch = "Humanoid.Health, Humanoid.Health" })
		t.eq(rec.tickRate, 60, "tick rate clamped")
		t.eq(rec.keyframeEvery, 1, "keyframe floor")
		t.eq(rec.trackCharacters, true, "characters default on")
		t.eq(rec.watched["BasePart"], nil, "only listed classes are watched")
		t.eq(#rec.watched["Humanoid"], 1, "duplicates collapse")
		t.ok(Studio.createRecorder({}).watched["BasePart"], "default watch list")
	end,

	saveRequiresName = function(t: Assert.T)
		local result = Studio.saveBlob(buffer.create(1), "", { backend = "datastore", store = "FlashbackTests" }, false)
		t.eq(result.ok, false)
		t.eq(result.exists, nil)
	end,
}
