# Packages
All of my maintained and distributed packages

Reusable utility modules, installable via [Wally](https://wally.run) or the [Studio Wally plugin](../plugins/studio-wally).

| Package | Description |
| --- | --- |
| [Attributor](src/Attributor) | An object for reading/writing attributes of an instance as if they were properties. Also comes with a :Destroy() function for easy cleanup. |
| [Authority](src/Authority) | A server-authorative state handler that uses attributes to replicate values. |
| [Binder](src/Binder) | An instance-lifecycle Binder class for your binding needs, with filters like class whitelist, ancestry whitelist, tags, and predicates. Uses Sleitnick's Trove and Signal modules. |
| [CameraController](src/CameraController) | An object oriented camera controller for Roblox. Uses Sleitnick's Trove for easy cleanup and use. If you want an easy way to manage the camera in your game, this module is for you. |
| [ClassProperties](src/ClassProperties) | A list of typed constructors for each Roblox instance's properties. Useful for type-checking pseudo-instances |
| [ClientSettings](src/ClientSettings) | A bare-bones module for storing and changing local settings. Uses Signal to fire an event when a setting is changed. |
| [CountryFlags](src/CountryFlags) | A utility module for getting the emoji for a country/region/language code. Also has utilities for getting country/region/language codes. |
| [GuiHandler](src/GuiHandler) | An object oriented Gui Handler class for Roblox. Uses Sleitnick's Trove and Signal for easy cleanup and use, as well as a configurable setup for each Gui Handler and full type checking in strict. If you want an easy way to make show/hide tweens for Guis in your game, this module is for you. Previous versions are broken, DO NOT USE THEM! |
| [Hitbox](src/Hitbox) | A simple object oriented hitbox module that utilizes :GetPartsInPart() and sleitnick's trove for easy cleanup. Also uses sleitnick's Timer module to scan the hitbox for a given duration. |
| [Mechanic](src/Mechanic) | A component style binder for Roblox that uses CollectionService tags. Uses Sleitnick's Trove and Signal for easy cleanup and use, as well as a configurable setup for each Mechanic and full type checking in strict. If you want an easy way to make Instances do things in your game, this module is for you. Previous versions are broken, DO NOT USE THEM! |
| [Packet](src/Packet) | A buffer-based networking library for Roblox. |
| [Predicates](src/Predicates) | A utility library for predicates. Primarily used in my kashtheking/binder package. |
| [SoundPool](src/SoundPool) | A SoundPool class. Useful for SFX in fighting games. Uses Sleitnick's trove and signal packages along with frqstbite's object-pool package. |
| [StateManager](src/StateManager) | A state manager for Roblox that uses Sleitnick's Trove and Signal for easy cleanup and use, as well as a configurable setup for each StateManager and full type checking in strict. If you want an easy way to handle state in your game, this module is for you. Previous versions are broken, DO NOT USE THEM! |
| [t](src/t) | A runtime type checker for Roblox. |
