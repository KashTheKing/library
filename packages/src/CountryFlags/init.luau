--!strict
local HttpService = game:GetService("HttpService")
local LocalizationService = game:GetService("LocalizationService")
local RunService = game:GetService("RunService")

--Url for requesting location data
local IP_URL = "https://ifconfig.co/json"

--Type checking for Location http response
--[=[
	@interface LocationData
	@within CountryFlags
	.ip string -- The public IP address the request was made from, e.g. `"2605:c840:402:8bac::8e03"`.
	.ip_decimal number -- The same IP address as a decimal number.
	.country string -- Full country name, e.g. `"United States"`.
	.country_iso string -- Two-letter ISO 3166-1 country code, e.g. `"US"`. Pass this to [CountryFlags.Get].
	.country_eu boolean -- Whether the country is a member of the European Union.
	.region_name string -- Name of the state, province or region, e.g. `"Nevada"`.
	.region_code string -- Short region code, e.g. `"NV"`.
	.metro_code number -- Metro (designated market area) code, e.g. `839`.
	.zip_code string -- Postal code, e.g. `"89183"`.
	.city string -- City name, e.g. `"Las Vegas"`.
	.latitude number -- Latitude in decimal degrees, e.g. `36.0021`.
	.longitude number -- Longitude in decimal degrees, e.g. `-115.147`.
	.time_zone string -- IANA time zone name, e.g. `"America/Los_Angeles"`.

	The JSON body returned by `https://ifconfig.co/json`, as decoded by [CountryFlags.GetLocationData].
	Because it describes the machine that made the HTTP request, it is the location of the **game
	server**, not of any player. Fields are whatever the service returns; some may be missing for
	IP addresses the service cannot geolocate.
]=]
export type LocationData = {
	ip: string,                  -- "2605:c840:402:8bac:28ec:35d0:3a42:8e03"
	ip_decimal: number,          -- 50540686877883626031144216325813079555
	country: string,             -- "United States"
	country_iso: string,         -- "US"
	country_eu: boolean,         -- false
	region_name: string,         -- "Nevada"
	region_code: string,         -- "NV"
	metro_code: number,          -- 839
	zip_code: string,            -- "89183"
	city: string,                -- "Las Vegas"
	latitude: number,            -- 36.0021
	longitude: number,           -- -115.147
	time_zone: string,           -- "America/Los_Angeles"
}

--Dictionary sorted for every country flag
local Flags: {[string]: string} = {
	AF = "🇦🇫", AX = "🇦🇽", AL = "🇦🇱", DZ = "🇩🇿", AS = "🇦🇸", AD = "🇦🇩", AO = "🇦🇴", AI = "🇦🇮",
	AQ = "🇦🇶", AG = "🇦🇬", AR = "🇦🇷", AM = "🇦🇲", AW = "🇦🇼", AU = "🇦🇺", AT = "🇦🇹", AZ = "🇦🇿",
	BS = "🇧🇸", BH = "🇧🇭", BD = "🇧🇩", BB = "🇧🇧", BY = "🇧🇾", BE = "🇧🇪", BZ = "🇧🇿", BJ = "🇧🇯",
	BM = "🇧🇲", BT = "🇧🇹", BO = "🇧🇴", BA = "🇧🇦", BW = "🇧🇼", BR = "🇧🇷", IO = "🇮🇴", VG = "🇻🇬",
	BN = "🇧🇳", BG = "🇧🇬", BF = "🇧🇫", BI = "🇧🇮", KH = "🇰🇭", CM = "🇨🇲", CA = "🇨🇦", CV = "🇨🇻",
	KY = "🇰🇾", CF = "🇨🇫", TD = "🇹🇩", CL = "🇨🇱", CN = "🇨🇳", CX = "🇨🇽", CC = "🇨🇨", CO = "🇨🇴",
	KM = "🇰🇲", CG = "🇨🇬", CD = "🇨🇩", CR = "🇨🇷", CI = "🇨🇮", HR = "🇭🇷", CU = "🇨🇺", CY = "🇨🇾",
	CZ = "🇨🇿", DK = "🇩🇰", DJ = "🇩🇯", DM = "🇩🇲", DO = "🇩🇴", EC = "🇪🇨", EG = "🇪🇬", SV = "🇸🇻",
	GQ = "🇬🇶", ER = "🇪🇷", EE = "🇪🇪", SZ = "🇸🇿", ET = "🇪🇹", EU = "🇪🇺", FK = "🇫🇰", FO = "🇫🇴",
	FJ = "🇫🇯", FI = "🇫🇮", FR = "🇫🇷", GF = "🇬🇫", PF = "🇵🇫", TF = "🇹🇫", GA = "🇬🇦", GM = "🇬🇲",
	GE = "🇬🇪", DE = "🇩🇪", GH = "🇬🇭", GI = "🇬🇮", GR = "🇬🇷", GL = "🇬🇱", GD = "🇬🇩", GU = "🇬🇺",
	GT = "🇬🇹", GG = "🇬🇬", GN = "🇬🇳", GW = "🇬🇼", GY = "🇬🇾", HT = "🇭🇹", HN = "🇭🇳", HK = "🇭🇰",
	HU = "🇭🇺", IS = "🇮🇸", IN = "🇮🇳", ID = "🇮🇩", IR = "🇮🇷", IQ = "🇮🇶", IE = "🇮🇪", IM = "🇮🇲",
	IL = "🇮🇱", IT = "🇮🇹", JM = "🇯🇲", JP = "🇯🇵", JE = "🇯🇪", JO = "🇯🇴", KZ = "🇰🇿", KE = "🇰🇪",
	KI = "🇰🇮", XK = "🇽🇰", KW = "🇰🇼", KG = "🇰🇬", LA = "🇱🇦", LV = "🇱🇻", LB = "🇱🇧", LS = "🇱🇸",
	LR = "🇱🇷", LY = "🇱🇾", LI = "🇱🇮", LT = "🇱🇹", LU = "🇱🇺", MO = "🇲🇴", MK = "🇲🇰", MG = "🇲🇬",
	MW = "🇲🇼", MY = "🇲🇾", MV = "🇲🇻", ML = "🇲🇱", MT = "🇲🇹", MH = "🇲🇭", MQ = "🇲🇶", MR = "🇲🇷",
	MU = "🇲🇺", YT = "🇾🇹", MX = "🇲🇽", FM = "🇫🇲", MD = "🇲🇩", MC = "🇲🇨", MN = "🇲🇳", ME = "🇲🇪",
	MS = "🇲🇸", MA = "🇲🇦", MZ = "🇲🇿", MM = "🇲🇲", NA = "🇳🇦", NR = "🇳🇷", NP = "🇳🇵", NL = "🇳🇱",
	NC = "🇳🇨", NZ = "🇳🇿", NI = "🇳🇮", NE = "🇳🇪", NG = "🇳🇬", NU = "🇳🇺", KP = "🇰🇵", MP = "🇲🇵",
	NO = "🇳🇴", OM = "🇴🇲", PK = "🇵🇰", PW = "🇵🇼", PS = "🇵🇸", PA = "🇵🇦", PY = "🇵🇾", PE = "🇵🇪",
	PH = "🇵🇭", PN = "🇵🇳", PL = "🇵🇱", PT = "🇵🇹", PR = "🇵🇷", QA = "🇶🇦", RE = "🇷🇪", RO = "🇷🇴",
	RU = "🇷🇺", RW = "🇷🇼", KN = "🇰🇳", LC = "🇱🇨", VC = "🇻🇨", CW = "🇨🇼", WS = "🇼🇸", ST = "🇸🇹",
	SA = "🇸🇦", SN = "🇸🇳", RS = "🇷🇸", SC = "🇸🇨", SL = "🇸🇱", SG = "🇸🇬", SX = "🇸🇽", SK = "🇸🇰",
	SI = "🇸🇮", SB = "🇸🇧", SO = "🇸🇴", ZA = "🇿🇦", GS = "🇬🇸", KR = "🇰🇷", SS = "🇸🇸", SE = "🇸🇪",
	CH = "🇨🇭", SY = "🇸🇾", TW = "🇹🇼", TJ = "🇹🇯", TZ = "🇹🇿", TH = "🇹🇭", TL = "🇹🇱", TG = "🇹🇬",
	TK = "🇹🇰", TO = "🇹🇴", TT = "🇹🇹", TN = "🇹🇳", TR = "🇹🇷", TM = "🇹🇲", TC = "🇹🇨", TV = "🇹🇻",
	UG = "🇺🇬", UA = "🇺🇦", AE = "🇦🇪", GB = "🇬🇧", US = "🇺🇸", UY = "🇺🇾", UZ = "🇺🇿", VU = "🇻🇺",
	VA = "🇻🇦", VE = "🇻🇪", VN = "🇻🇳", YE = "🇾🇪", ZM = "🇿🇲", ZW = "🇿🇼", UN = "🇺🇳"
}

--Language to flag map for any given language
local LanguageMap = {
	EN = "US",
	FR = "FR",
	ES = "ES",
	DE = "DE",
	IT = "IT",
	JA = "JP",
	KO = "KR",
	RU = "RU",
	ZH = "CN",
	AR = "SA",
	PT = "BR",
	TR = "TR",
	HI = "IN",
	NL = "NL",
	SV = "SE",
	DA = "DK",
	NO = "NO",
	FI = "FI",
	CS = "CZ",
	PL = "PL",
	TH = "TH",
	VI = "VN",
	ID = "ID",
	HE = "IL"
}

--[=[
	@class CountryFlags

	Utilities for turning country, region and language codes into flag emoji, and for finding out
	which country a player or the server is in. The module is a plain table of functions: there is
	nothing to construct and no `self` to pass.

	```lua
	local Players = game:GetService("Players")
	local CountryFlags = require(path.to.CountryFlags)

	-- Server: greet each player with the flag of the country they are connecting from.
	Players.PlayerAdded:Connect(function(player)
		local ok, countryCode = pcall(CountryFlags.GetPlayerRegion, player) -- yields, e.g. "US"
		if not ok then
			return
		end

		local flag = CountryFlags.Flags[countryCode] or CountryFlags.Get("UN")
		print(("Welcome %s %s"):format(player.Name, flag))
	end)

	-- Anywhere: flags from a region string or a language code.
	local language, country = CountryFlags.SplitRegion("en-us") -- "EN", "US"
	print(CountryFlags.Flags[country])                          -- "🇺🇸"
	print(CountryFlags.FromLanguage(language))                  -- "🇺🇸" (EN is mapped to US)
	print(CountryFlags.FromLanguage("ja"))                      -- "🇯🇵"
	```

	Codes are compared case-insensitively by the helper functions (they upper-case their input),
	but the [CountryFlags.Flags] and [CountryFlags.LanguageMap] tables themselves are keyed by
	**upper-case** codes.

	**Credits:** written by KashTheKing. No third-party dependencies.

	Installation and guide: [CountryFlags package page](/docs/packages/country-flags).
]=]
local CountryFlags = {
	Flags = Flags,
	LanguageMap = LanguageMap
}

--[=[
	@prop Flags { [string]: string }
	@within CountryFlags
	@readonly
	Dictionary of upper-case ISO 3166-1 alpha-2 country codes to their flag emoji, e.g.
	`CountryFlags.Flags.GB == "🇬🇧"`. Besides real countries it also contains `EU` (European Union)
	and `UN` (United Nations), which are handy fallbacks. Indexing an unknown code returns `nil`.
]=]

--[=[
	@prop LanguageMap { [string]: string }
	@within CountryFlags
	@readonly
	Maps an upper-case two-letter ISO 639-1 **language** code to the **country** code whose flag
	is conventionally used for that language, e.g. `EN -> "US"`, `JA -> "JP"`, `PT -> "BR"`,
	`AR -> "SA"`. It is used by [CountryFlags.FromLanguage]. Only about two dozen common languages
	are mapped; a language is not a country, so the choice is a convention, not a fact. You may
	add or override entries at runtime (`CountryFlags.LanguageMap.EN = "GB"`) before calling
	[CountryFlags.FromLanguage].
]=]

--Returns all country codes in array/list format
--[=[
	Returns every code that has a flag in [CountryFlags.Flags], as a new array. The order is not
	defined (it comes from `pairs`), so sort it yourself if you need a stable list.

	```lua
	local codes = CountryFlags.GetCodes()
	table.sort(codes)
	print(#codes, codes[1]) -- 231 AD
	```

	@function GetCodes
	@within CountryFlags
	@return { string } -- Array of upper-case country codes such as `"US"`, including `"EU"` and `"UN"`.
]=]
function CountryFlags.GetCodes()
	local list = {}
	
	for code in pairs(Flags) do
		table.insert(list, code)
	end
	
	return list
end

--Returns true if the given value is a country code
--[=[
	Tells whether `value` looks like a two-letter country code. It only checks the shape of the
	value (a string of length two once letters are accounted for); it does **not** check that the
	code exists in [CountryFlags.Flags], so `IsA` returning `true` does not guarantee that
	[CountryFlags.Get] will find a flag.

	:::caution
	The current implementation strips the letters with `gsub("%a", "")` and then requires the
	**remaining** string to be two characters long. A plain code such as `"US"` therefore
	returns `false`, and [CountryFlags.Get] (which asserts on this function) errors for it. Until
	this is fixed, index [CountryFlags.Flags] directly for lookups.
	:::

	@function IsA
	@within CountryFlags
	@param t T -- Any value; non-strings return `false`.
	@return boolean -- `true` if the value passes the country-code shape check.
]=]
function CountryFlags.IsA<T>(t: T): boolean
	return typeof(t) == "string" and #(t:gsub("%a", "")) == 2
end

--Returns the flag emoji for the given country
--[=[
	Returns the flag emoji for a country code. The code is upper-cased before the lookup, so
	`"gb"` and `"GB"` both work. If the code passes [CountryFlags.IsA] but has no entry in
	[CountryFlags.Flags], the result is `nil` even though the declared return type is `string`.

	```lua
	print(CountryFlags.Get("de")) -- "🇩🇪"
	```

	@function Get
	@within CountryFlags
	@param countryCode string -- Two-letter country code, any case.
	@return string -- The flag emoji, or `nil` when the code is unknown.
	@error "Invalid country code" -- When `countryCode` does not satisfy [CountryFlags.IsA] (see the caution there).
]=]
function CountryFlags.Get(countryCode: string): string
	assert(CountryFlags.IsA(countryCode), "Invalid country code")
	
	return Flags[countryCode:upper()]
end

--Returns the country region for a given player (ex. en-us)
--[=[
	Returns the two-letter country/region code the player is connecting from, e.g. `"US"`, by
	calling `LocalizationService:GetCountryRegionForPlayerAsync`. Despite the name, the result is
	a country code, not a `language-COUNTRY` locale string, so it can be used directly with
	[CountryFlags.Flags]. Wrap the call in `pcall`: the underlying Roblox API yields and raises an
	error if the request fails or the player has already left.

	```lua
	local ok, code = pcall(CountryFlags.GetPlayerRegion, player)
	if ok then
		print(CountryFlags.Flags[code])
	end
	```

	@function GetPlayerRegion
	@within CountryFlags
	@server
	@yields
	@param player Player -- The player to look up; must still be in the game.
	@return string -- Upper-case country/region code such as `"US"`.
	@error string -- Propagated from `GetCountryRegionForPlayerAsync` when the lookup fails.
]=]
function CountryFlags.GetPlayerRegion(player: Player)
	return LocalizationService:GetCountryRegionForPlayerAsync(player)
end

--Returns the server's location data
--Only works on the server because it uses HttpService
--Can throw errors because it uses HttpService
--[=[
	Fetches the geolocation of the **game server** by requesting `https://ifconfig.co/json` with
	`HttpService:GetAsync` and decoding the JSON body into a [LocationData] table. This is the
	server's public IP location (the data centre the server runs in), not a player's location;
	use [CountryFlags.GetPlayerRegion] for players.

	Requirements and failure modes:
	- Server only: the function asserts `RunService:IsServer()`.
	- HTTP requests must be enabled in Game Settings, otherwise `GetAsync` errors.
	- The request yields and can fail (network error, rate limit, service down), so call it in a
	  `pcall` and cache the result rather than calling it per player.

	```lua
	local ok, location = pcall(CountryFlags.GetLocationData)
	if ok then
		print(location.country, location.country_iso, CountryFlags.Flags[location.country_iso])
	end
	```

	@function GetLocationData
	@within CountryFlags
	@server
	@yields
	@return LocationData -- The decoded location of the server.
	@error "You must be on the server" -- When called from a client.
	@error string -- Any error raised by `HttpService:GetAsync` or `HttpService:JSONDecode`.
]=]
function CountryFlags.GetLocationData(): LocationData
	assert(RunService:IsServer(), "You must be on the server")
	
	local response = HttpService:GetAsync(IP_URL, false)
	local locationData = HttpService:JSONDecode(response)
	
	return locationData
end

--Splits the language and country code from a region string
--Example: en-us -> EN, US
--[=[
	Splits a `language-COUNTRY` locale string such as `"en-us"` (the format of
	`LocalizationService.RobloxLocaleId` or `Player.LocaleId`) into its language and country codes,
	both upper-cased. Only the first two segments are returned, so `"zh-Hans-CN"` gives
	`"ZH", "HANS"`.

	```lua
	local language, country = CountryFlags.SplitRegion(player.LocaleId) -- "EN", "US"
	local flag = CountryFlags.Flags[country] or CountryFlags.FromLanguage(language)
	```

	@function SplitRegion
	@within CountryFlags
	@param regionString string -- A locale string containing at least one `-`, e.g. `"en-us"`.
	@return string -- The language code in upper case, e.g. `"EN"`.
	@return string -- The country/region code in upper case, e.g. `"US"`.
	@error "Invalid region string" -- When the string does not contain a `-`.
]=]
function CountryFlags.SplitRegion(regionString: string): (string, string)
	local split = regionString:split("-")
	assert(#split >= 2, "Invalid region string")
	
	return split[1]:upper(), split[2]:upper()
end

--Returns a mapped flag for a given language code
--Note: Not all flags have a language mapping
--[=[
	Returns a representative flag for a **language** code by looking the upper-cased code up in
	[CountryFlags.LanguageMap] and then in [CountryFlags.Flags]. Returns `nil` when the language
	has no mapping, which is the case for most of the world's languages, so always handle `nil`.

	```lua
	print(CountryFlags.FromLanguage("ko")) -- "🇰🇷"
	print(CountryFlags.FromLanguage("eo")) -- nil (Esperanto is not mapped)
	```

	@function FromLanguage
	@within CountryFlags
	@param languageCode string -- Two-letter ISO 639-1 language code, any case.
	@return string? -- The flag emoji of the mapped country, or `nil` if the language is not mapped.
]=]
function CountryFlags.FromLanguage(languageCode: string): string?
	local mappedCountry = LanguageMap[languageCode:upper()]
	
	if mappedCountry then
		return Flags[mappedCountry]
	end
	
	return nil
end

return CountryFlags