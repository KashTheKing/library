---
title: Components with Binder
sidebar_position: 2
description: Structure a Roblox game as tagged instances bound to classes with Binder, with automatic cleanup through Trove.
---

# Components with Binder

Nearly everything in my games follows one pattern: an instance in the world carries a **tag**, a **Binder** notices it and constructs a **class** for it, the class gets a **Trove** to put its connections in, and when the instance goes away the Trove is cleaned. No `Destroy` bookkeeping, no dangling connections, no giant scripts that loop over `workspace`. This guide builds that pattern from nothing to a working door, then shows the pieces you reach for next.

You need [Binder](../packages/binder.md) installed (it brings Trove, Signal and Predicates with it). The [Binder API page](/api/Binder) has every method; this guide is about how to use them together.

## 1. A class with a constructor

A component is a plain Luau class whose constructor takes the instance and a Trove:

```lua
-- ReplicatedStorage/Components/Door.luau
local Door = {}
Door.__index = Door

function Door.new(model: Model, trove)
	local self = setmetatable({
		Model = model,
		Open = false,
	}, Door)

	-- Anything that needs disconnecting later goes into the trove.
	trove:Connect(model.PrimaryPart.ClickDetector.MouseClick, function()
		self:Toggle()
	end)

	return self
end

function Door:Toggle()
	self.Open = not self.Open
	self.Model.PrimaryPart.CanCollide = not self.Open
	self.Model.PrimaryPart.Transparency = if self.Open then 0.7 else 0
end

function Door:Destroy()
	-- Optional. Called for you when the door is unbound, because Binder adds
	-- any returned object with a Destroy method to the Trove.
	print("Door gone:", self.Model.Name)
end

return Door
```

Two things to notice: the constructor never connects anything without the Trove, and it **returns the object**. Binder errors if a constructor returns `nil`, and it puts anything with a `Destroy` method into the Trove so your cleanup runs automatically.

## 2. A Binder for the class

One script creates the Binder. In a Rojo project this is a server `Script` under `ServerScriptService`, or a `LocalScript` for client-side components; the same code works on either side.

```lua
-- ServerScriptService/Binders.server.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Binder = require(ReplicatedStorage.Packages.Binder)
local Door = require(ReplicatedStorage.Components.Door)

Binder.new(Door, {
	Tags = { "Door" },          -- CollectionService tag to watch
	ClassNames = { "Model" },   -- only Models (IsA is used, so BasePart covers Part, MeshPart, ...)
	Ancestors = { workspace },  -- only things in the workspace
	AutoStart = true,           -- start watching immediately
})
```

Now select a door model in Studio, add the tag `Door` (Tag Editor, or the Tags section of the Properties panel), give it a PrimaryPart with a ClickDetector, and press Play. The Binder constructs a `Door` for every tagged model that exists, and for every one that is added or tagged later. Remove the tag or destroy the model and the Trove is cleaned.

Every filter is optional. Leave out `Ancestors` and Binder watches the whole game through the tag signals. Leave out `Tags` and it binds everything under the ancestors that passes the other filters (give it at least `Tags` or `Ancestors`, or it only scans once at start).

## 3. Reading configuration with a predicate

Doors that open at different speeds should not need different classes. Put the speed in an **attribute** and require it with a predicate from [Predicates](../packages/predicates.md), which Binder exposes as `Binder.Predicates`:

```lua
Binder.new(Door, {
	Tags = { "Door" },
	ClassNames = { "Model" },
	Predicate = Binder.Predicates.Attribute("OpenTime", "number", "DoorBinder"),
	AutoStart = true,
})
```

A predicate returns `true` or `false`, plus any extra values. `Attribute` returns the attribute's value, and Binder passes every extra value to your constructor **after the Trove**:

```lua
function Door.new(model: Model, trove, openTime: number)
	-- openTime is guaranteed to be a number here
end
```

If a tagged door is missing the attribute, the predicate fails, the door is not bound, and a warning tagged `DoorBinder` is printed telling you which instance and why. That is the whole validation story: bad setup is caught at bind time with a readable message, and the constructor can trust its arguments.

Predicates compose. `Binder.Predicates.Combine({ ... })` requires several at once and forwards all their extra values in order. `Child("Hinge", "BasePart")`, `Humanoid()`, `Player()` and the rest are listed on the [Predicates API page](/api/Predicates).

## 4. Talking to bound objects

Keep the Binder in a variable and you can look objects up, listen for them, and bind by hand:

```lua
local doors = Binder.new(Door, { Tags = { "Door" }, AutoStart = true })

-- The object for a given instance (nil if not bound)
local door = doors:GetBinding(someModel)
if door then
	door:Toggle()
end

-- Every currently bound instance
for _, model in doors:GetInstances() do
	print(model:GetFullName())
end

-- React to binds and unbinds
doors.InstanceBound:Connect(function(model, trove, door)
	print("bound", model.Name)
end)
doors.InstanceUnbound:Connect(function(model)
	print("unbound", model.Name)
end)

-- Bind or unbind yourself (also adds/removes the tags)
doors:Bind(newModel)
doors:Unbind(newModel)
```

A Binder created with `ManualBindingOnly = true` never watches anything; you call `Bind` and `Unbind` yourself and still get the Trove-per-instance and the signals. That is handy for objects created by code rather than placed in the world.

## 5. Ordering between systems

When one component depends on another being ready (a `Turret` that needs the `Base` it sits on to be bound first), give the Binders a `Priority`. Binds queued on the same frame are flushed on the next `Heartbeat` in ascending priority, so a `Priority = 1` Binder always constructs before a `Priority = 2` one, whatever order their instances arrived in. Binders without a priority bind immediately.

## 6. Shutting down

`binder:Stop()` disconnects the watchers but keeps existing bindings. `binder:Destroy()` unbinds everything (cleaning every Trove and firing `InstanceUnbound` for each) and then disconnects the signals. Set `RemoveTagsOnCleanup = true` in the config if you want unbound instances to lose their tags too.

## Where this leads

- Put the Binder creation for a whole game in one place, one Binder per component type. That file becomes a readable list of everything the game reacts to.
- Server-only components (damage, currency) live in server Binders; visual components (VFX, UI prompts) in client Binders; both can bind the **same** tagged instance.
- Replicate per-instance state to clients with [Authority](../packages/authority.md), send commands with [Packet](../packages/packet.md), and validate anything from the client with [t](../packages/t.md).
- The [Damage Part example](../building-blocks/damage-part-example.md) is a complete Binder component you can unpack and read.

Questions about the pattern: the [Discord](https://discord.gg/6HYgCk22eD) is the place.
