--!strict
-- Who owns each step of Eclipse's undo history. Eclipse has one history for everyone, so a helper may only undo
-- when the newest step is its own, and only redo what it undid itself. Steps Kash makes are never anyone's.

export type Ownership = {
	undo: { { count: number, agent: string } },
	redo: { { count: number, agent: string } },
	undoCount: number,
	redoCount: number,
}

local Ownership = {}

function Ownership.new(): Ownership
	return { undo = {}, redo = {}, undoCount = 0, redoCount = 0 }
end

-- A helper's edit finished and the history now has `undoCount` steps.
function Ownership.recordEdit(o: Ownership, agent: string, undoCount: number, redoCount: number)
	table.insert(o.undo, { count = undoCount, agent = agent })
	table.clear(o.redo)
	o.undoCount, o.redoCount = undoCount, redoCount
end

-- The history moved without a helper (Kash edited, undid or redid). Returns true when it changed.
function Ownership.observe(o: Ownership, undoCount: number, redoCount: number): boolean
	if undoCount == o.undoCount and redoCount == o.redoCount then
		return false
	end
	while #o.undo > 0 and o.undo[#o.undo].count > undoCount do
		table.remove(o.undo)
	end
	-- Any change by Kash makes the redo stack his.
	table.clear(o.redo)
	o.undoCount, o.redoCount = undoCount, redoCount
	return true
end

function Ownership.canUndo(o: Ownership, agent: string, undoCount: number): (boolean, string?)
	local top = o.undo[#o.undo]
	if not top or top.count ~= undoCount then
		return false, "The newest undo step isn't yours (Kash or another helper edited since)."
	elseif top.agent ~= agent then
		return false, "The newest undo step belongs to another helper."
	end
	return true, nil
end

function Ownership.didUndo(o: Ownership, agent: string, undoCount: number, redoCount: number)
	table.remove(o.undo)
	table.insert(o.redo, { count = redoCount, agent = agent })
	o.undoCount, o.redoCount = undoCount, redoCount
end

function Ownership.canRedo(o: Ownership, agent: string, redoCount: number): (boolean, string?)
	local top = o.redo[#o.redo]
	if not top or top.count ~= redoCount or top.agent ~= agent then
		return false, "The newest redo step isn't one you undid."
	end
	return true, nil
end

function Ownership.didRedo(o: Ownership, agent: string, undoCount: number, redoCount: number)
	table.remove(o.redo)
	table.insert(o.undo, { count = undoCount, agent = agent })
	o.undoCount, o.redoCount = undoCount, redoCount
end

return Ownership
