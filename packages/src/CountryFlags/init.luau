--!strict
local HttpService = game:GetService("HttpService")
local LocalizationService = game:GetService("LocalizationService")
local RunService = game:GetService("RunService")

--Url for requesting location data
local IP_URL = "https://ifconfig.co/json"

--Type checking for Location http response
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

local CountryFlags = {
	Flags = Flags,
	LanguageMap = LanguageMap
}

--Returns all country codes in array/list format
function CountryFlags.GetCodes()
	local list = {}
	
	for code in pairs(Flags) do
		table.insert(list, code)
	end
	
	return list
end

--Returns true if the given value is a country code
function CountryFlags.IsA<T>(t: T): boolean
	return typeof(t) == "string" and #(t:gsub("%a", "")) == 2
end

--Returns the flag emoji for the given country
function CountryFlags.Get(countryCode: string): string
	assert(CountryFlags.IsA(countryCode), "Invalid country code")
	
	return Flags[countryCode:upper()]
end

--Returns the country region for a given player (ex. en-us)
function CountryFlags.GetPlayerRegion(player: Player)
	return LocalizationService:GetCountryRegionForPlayerAsync(player)
end

--Returns the server's location data
--Only works on the server because it uses HttpService
--Can throw errors because it uses HttpService
function CountryFlags.GetLocationData(): LocationData
	assert(RunService:IsServer(), "You must be on the server")
	
	local response = HttpService:GetAsync(IP_URL, false)
	local locationData = HttpService:JSONDecode(response)
	
	return locationData
end

--Splits the language and country code from a region string
--Example: en-us -> EN, US
function CountryFlags.SplitRegion(regionString: string): (string, string)
	local split = regionString:split("-")
	assert(#split >= 2, "Invalid region string")
	
	return split[1]:upper(), split[2]:upper()
end

--Returns a mapped flag for a given language code
--Note: Not all flags have a language mapping
function CountryFlags.FromLanguage(languageCode: string): string?
	local mappedCountry = LanguageMap[languageCode:upper()]
	
	if mappedCountry then
		return Flags[mappedCountry]
	end
	
	return nil
end

return CountryFlags