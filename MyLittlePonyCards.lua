-- Pony Pairs auto-solver | "My Little Pony Card Opening" (universe 10775160561)
-- Plays the game's own memory board like a perfect-memory human: flips unknown cards,
-- remembers every card id the server reveals, and completes a pair as soon as both
-- halves are known. Taps go through the game's own tapCard function, so animations,
-- queueing and the Memory remote behave exactly like a real click.

local env = (getgenv and getgenv()) or _G
-- keep the user's settings across reloads (Destroy() switches Enabled off, so copy first)
local PERSIST = { "Mode", "TurboGap", "AutoOpen", "AdaptiveSlow", "PackAuto", "PackSet", "PackBuy", "PackGap", "PackLimit", "SlowCapProbe", "PackVisible", "PackCardView", "PackSummaryView", "PackSellDupes", "PackBuyAmount", "StickerAutoOpen", "StickerPickDelay", "StickerDragTime", "StickerPerfectCount" }
local previousSettings
if env.PonyPairsSolver and env.PonyPairsSolver.Config then
	previousSettings = {}
	for _, key in ipairs(PERSIST) do previousSettings[key] = env.PonyPairsSolver.Config[key] end
end
if env.PonyPairsSolver and env.PonyPairsSolver.Destroy then
	pcall(env.PonyPairsSolver.Destroy)
end

local Players = game:GetService("Players")
local lp = Players.LocalPlayer

local CARD_COUNT = 12

local Config = {
	Enabled = false,       -- solver starts OFF every time the script loads; flip the Solver toggle to start it
	FlipDelay = 0.6,        -- seconds between taps (server flags pairs solved too fast as "slow" = no coins)
	FlipJitter = 0.15,      -- random extra seconds added to each delay
	DealSettle = 1.0,       -- seconds to wait after a deal (the deal animation takes ~0.93s)
	ResolveTimeout = 4,     -- seconds to wait for the server to answer one flip
	SlowPenaltyStep = 0.15, -- added to the delay each time the server reports "slow"
	SlowPenaltyMax = 1.5,
	MaxRounds = 0,          -- stop after this many finished boards (0 = unlimited)
	AutoOpen = false,       -- open the Pony Pairs board by itself when at the desk
	Verbose = true,
	Mode = "Human",         -- only Human is available; Blatant, Instant and Turbo are locked
	TurboGap = 0.21,        -- seconds between flips in Turbo (server rejects gaps under ~0.2s)
	PackAuto = false,       -- auto-open packs
	CollectionSell = false, -- sell duplicates from the whole collection; cannot be undone, always starts OFF
	PackBuyAmount = 0,      -- >0: buy this many first, open that many, then stop (0 = open continuously)
	PackSet = "MOON1",      -- which pack (set id) to open
	PackBuy = true,         -- buy the pack with coins when you own none
	PackVisible = true,     -- true: open on screen through the game's own pack screen; false: headless
	PackCardView = 0.9,     -- seconds each revealed card stays on screen (visible mode)
	PackSummaryView = 2.0,  -- seconds the summary stays on screen before collecting (visible mode)
	PackSellDupes = false,  -- press the game's "sell dupes" button on each summary (visible mode only; cannot be undone)
	StickerEnabled = false,   -- sticker postcard solver; always starts OFF
	StickerPerfectCount = 3,  -- perfect drops per postcard (0-5); the stickers after those land as "nice"
	StickerAutoOpen = false,  -- open the sticker desk by itself when at the main desk
	StickerPickDelay = 0.6,   -- seconds before each sticker and before mailing (same base as puzzle Human)
	StickerDragTime = 0.8,    -- seconds each sticker takes to travel to its outline
	PackGap = 1.0,          -- seconds between pack opens
	PackLimit = 0,          -- stop after this many opened packs (0 = unlimited)
	AdaptiveSlow = false,   -- if true, add delay whenever the server reports "slow"
	SlowCapProbe = false,       -- experimental: after N consecutive 'slow' matches, pause and test if the cap lifts
	SlowCapThreshold = 3,       -- consecutive slow matches before triggering a probe pause
	SlowCapPauseSeconds = 30,   -- initial pause length (doubles on repeated failure, capped by SlowCapPauseMax)
	SlowCapPauseMax = 600,      -- longest pause the probe will grow to
	HesitationChance = 0.04,    -- per-flip chance of a human-like pause (Human/Blatant/Instant only, never Turbo)
	HesitationMin = 0.6,        -- shortest hesitation pause, seconds
	HesitationMax = 2.2,        -- longest hesitation pause, seconds
	TurboGapVariance = 0.3,     -- Turbo gap is multiplied by 1.0..(1+this) so every gap isn't identical
}

----------------------------------------------------------------------
-- Config file: settings only. The switches that start automation are never saved here.
----------------------------------------------------------------------
local CONFIG_FOLDER = "PonyPairsSolver"
local CONFIG_PATH = CONFIG_FOLDER .. "/config.json"
local HttpService = game:GetService("HttpService")

local function numberIn(low, high, whole)
	return function(v)
		return type(v) == "number" and v >= low and v <= high and (not whole or v % 1 == 0)
	end
end
local function isBool(v) return type(v) == "boolean" end
-- ordered, so an unchanged config always produces the same signature
local SAVED_SETTINGS = {
	{ "Mode", function(v) return v == "Human" or v == "Blatant" or v == "Instant" or v == "Turbo" end },
	{ "TurboGap", numberIn(0, 5) },
	{ "AutoOpen", isBool },
	{ "PackSet", function(v) return type(v) == "string" and #v > 0 and #v <= 32 end },
	{ "PackBuy", isBool },
	{ "PackGap", numberIn(0, 60) },
	{ "PackLimit", numberIn(0, 100000, true) },
	{ "PackVisible", isBool },
	{ "PackCardView", numberIn(0.1, 10) },
	{ "PackSummaryView", numberIn(0.1, 10) },
	{ "PackSellDupes", isBool },
	{ "PackBuyAmount", numberIn(0, 100, true) },
	{ "StickerAutoOpen", isBool },
	{ "StickerPickDelay", numberIn(0.3, 3) },
	{ "StickerDragTime", numberIn(0.3, 3) },
	{ "StickerPerfectCount", numberIn(0, 5, true) },
}

local configState = { autoSave = true, lastSignature = nil, note = "no saved config yet" }

local function configSignature()
	local parts = { tostring(configState.autoSave) }
	for _, entry in ipairs(SAVED_SETTINGS) do
		parts[#parts + 1] = tostring(Config[entry[1]])
	end
	return table.concat(parts, "|")
end

local function loadConfigFile()
	if not (isfile and readfile and isfile(CONFIG_PATH)) then return end
	local ok, data = pcall(function() return HttpService:JSONDecode(readfile(CONFIG_PATH)) end)
	if not ok or type(data) ~= "table" or type(data.settings) ~= "table" then
		pcall(function() writefile(CONFIG_PATH .. ".bad", readfile(CONFIG_PATH)) end)
		configState.note = "saved config was unreadable, kept a copy as config.json.bad"
		warn("[PonyPairs] " .. configState.note)
		return
	end
	local skipped = 0
	for _, entry in ipairs(SAVED_SETTINGS) do
		local value = data.settings[entry[1]]
		if value ~= nil then
			if entry[2](value) then Config[entry[1]] = value else skipped += 1 end
		end
	end
	if data.autoSave == false then configState.autoSave = false end
	configState.note = skipped > 0 and ("loaded, ignored " .. skipped .. " invalid values") or "loaded"
end

local function saveConfigFile()
	local settings = {}
	for _, entry in ipairs(SAVED_SETTINGS) do settings[entry[1]] = Config[entry[1]] end
	local ok, err = pcall(function()
		if not isfolder(CONFIG_FOLDER) then makefolder(CONFIG_FOLDER) end
		writefile(CONFIG_PATH, HttpService:JSONEncode({ version = 1, autoSave = configState.autoSave, settings = settings }))
	end)
	configState.lastSignature = configSignature()
	configState.note = ok and ("saved at " .. os.date("%H:%M:%S")) or ("save failed: " .. tostring(err))
	if not ok then warn("[PonyPairs] " .. configState.note) end
	return ok
end

loadConfigFile()
if env.PonyPairsDiscardSettings then
	previousSettings = nil -- the user reset the config: do not carry the old values into this load
	env.PonyPairsDiscardSettings = nil
end

if previousSettings then
	for key, value in pairs(previousSettings) do
		if value ~= nil then Config[key] = value end
	end
end

-- a reload must never start a second purchase of the chosen quantity by itself
if Config.PackBuyAmount > 0 then
	Config.PackAuto = false
end

-- Blatant, Instant and Turbo are locked: an older saved choice must not bring them back
Config.Mode = "Human"

-- both options are locked off in the menu
Config.AdaptiveSlow = false
Config.SlowCapProbe = false

local Modes = {
	Human = { delay = 0.6, jitter = 0.15 },
	Blatant = { delay = 0.15, jitter = 0 },
	Instant = { delay = 0, jitter = 0 },  -- limited only by server round-trip time
	Turbo = { delay = 0, jitter = 0 },    -- headless: talks to the server directly, no board UI
}

local function log(...)
	if Config.Verbose then
		print("[PonyPairs]", ...)
	end
end

-- Sum of two half-spread uniforms approximates a triangular distribution peaked at
-- spread/2, which matches real human reaction-time variance far better than a flat
-- uniform spread (a flat spread makes every delay equally likely, which is itself an
-- unnatural, easily-averaged signature).
local function humanSpread(rngSource, spread)
	if spread <= 0 then
		return 0
	end
	local half = spread / 2
	return rngSource:NextNumber(0, half) + rngSource:NextNumber(0, half)
end

----------------------------------------------------------------------
-- Resolve game internals (validated; errors out instead of guessing)
----------------------------------------------------------------------
local function resolveGame()
	local playerScripts = lp:WaitForChild("PlayerScripts", 10)
	local client = playerScripts and playerScripts:WaitForChild("Client", 10)
	assert(client, "PlayerScripts.Client not found")

	local Memory = require(client:WaitForChild("Memory", 10))
	local Store = require(client:WaitForChild("Store", 10))
	assert(type(Memory) == "table" and type(Memory.init) == "function"
		and type(Memory.tourParts) == "function" and type(Memory.isActive) == "function"
		and type(Memory.open) == "function", "Memory module has an unexpected shape")
	assert(type(Store) == "table" and type(Store.memory) == "function", "Store.memory not found")

	local tapCard
	for _, up in pairs(debug.getupvalues(Memory.init)) do
		if type(up) == "function" then
			local ok, name = pcall(debug.info, up, "n")
			if ok and name == "tapCard" then
				tapCard = up
				break
			end
		end
	end
	assert(tapCard, "tapCard not found in Memory.init upvalues (game updated?)")

	local cards = debug.getupvalues(Memory.tourParts)[1]
	assert(type(cards) == "table" and #cards == CARD_COUNT, "card list not found or wrong size")
	for i, card in ipairs(cards) do
		assert(typeof(card.part) == "Instance" and card.part.Name == "Card" .. i
			and type(card.state) == "string", "card " .. i .. " has an unexpected shape")
	end
	return Memory, Store, tapCard, cards
end

local Memory, Store, tapCard, cards = resolveGame()

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local alive = true
local unlocked = false -- becomes true only after the key window is passed; every automation loop checks it
local rng = Random.new()
local penalty = 0
local seeded = false
local seedStart = 0
local lastOpenTry = 0
local rejected = 0

local state = {
	ids = {},          -- card index -> card id revealed by the server
	matched = {},      -- card index -> true once paired
	openFirst = nil,   -- index of the face-up card waiting for its partner
	finished = false,  -- current board completed
	boardPairs = 0,    -- pairs matched on the current board
	readyAt = 0,       -- os.clock() time after which tapping is allowed
}
local stats = { collectionSold = 0, collectionCoins = 0, stickersPlaced = 0, postcards = 0, postcardCoins = 0, unpaidStreak = 0, dupesSold = 0, packsOpened = 0, packsBought = 0, coinsSpent = 0, cardsPulled = 0, newCards = 0, rateLimited = 0, taps = 0, userClicks = 0, rounds = 0, flips = 0, pairs = 0, misses = 0, slow = 0, failures = 0, timeouts = 0, finishedRounds = 0, lastError = nil }

-- Coin meter: follows the wallet balance, so it counts coins from every source.
-- Rises are "earned", drops are "spent"; a rise and a drop inside one sample show only their difference.
local coinMeter = { since = os.clock(), elapsedFrom = nil, last = nil, earned = 0, spent = 0 }
local RECENT_WINDOW = 60
local coinHistory = {} -- one { at, earned } point per second, covering RECENT_WINDOW
local function resetCoinMeter()
	table.clear(coinHistory)
	coinMeter.since, coinMeter.last, coinMeter.earned, coinMeter.spent = os.clock(), nil, 0, 0
end
local function sampleCoins()
	local ok, money = pcall(Store.money)
	if not ok or type(money) ~= "number" or money ~= money then return end
	if coinMeter.last == nil then
		coinMeter.since = os.clock() -- the clock starts with the first balance read
	elseif money > coinMeter.last then
		coinMeter.earned += money - coinMeter.last
	else
		coinMeter.spent += coinMeter.last - money
	end
	coinMeter.last = money
	local now = os.clock()
	local newest = coinHistory[#coinHistory]
	if not newest or now - newest.at >= 1 then
		table.insert(coinHistory, { at = now, earned = coinMeter.earned })
		-- keep one point at or just beyond the window edge
		while coinHistory[2] and now - coinHistory[2].at >= RECENT_WINDOW do
			table.remove(coinHistory, 1)
		end
	end
end
local function coinReport()
	local seconds = math.max(os.clock() - coinMeter.since, 1)
	local perSecond = coinMeter.earned / seconds
	local net = coinMeter.earned - coinMeter.spent
	local netPerSecond = net / seconds
	local recentSeconds, recentEarned = 0, 0
	local oldest = coinHistory[1]
	if oldest then
		recentSeconds = os.clock() - oldest.at
		recentEarned = coinMeter.earned - oldest.earned
	end
	return {
		recentSeconds = recentSeconds, recentEarned = recentEarned,
		seconds = seconds, earned = coinMeter.earned, spent = coinMeter.spent, net = net,
		perSecond = perSecond, perMinute = perSecond * 60, perHour = perSecond * 3600,
		netPerSecond = netPerSecond, netPerMinute = netPerSecond * 60, netPerHour = netPerSecond * 3600,
	}
end

----------------------------------------------------------------------
-- Slow-cap probe (experimental): after a run of consecutive 'slow' matches,
-- pause all flipping for a while and check whether the very next match comes
-- back slow-free. Only measures what we can observe; never assumes the cap
-- is time-based until the logged results actually show that.
----------------------------------------------------------------------
local slowCap = {
	pauseUntil = 0,
	pausedAt = 0,
	pauseSeconds = Config.SlowCapPauseSeconds,
	consecutiveSlow = 0,
	probing = false,
	log = {},
	lastResult = nil,
}

local function slowCapOnMatch(isSlow)
	if not Config.SlowCapProbe then
		return
	end
	if slowCap.probing then
		local idleSeconds = os.clock() - slowCap.pausedAt
		slowCap.probing = false
		slowCap.log[#slowCap.log + 1] = { idleSeconds = idleSeconds, stillSlow = isSlow }
		if #slowCap.log > 20 then
			table.remove(slowCap.log, 1)
		end
		if isSlow then
			slowCap.pauseSeconds = math.min(slowCap.pauseSeconds * 2, Config.SlowCapPauseMax)
			slowCap.consecutiveSlow = Config.SlowCapThreshold
			slowCap.pausedAt = os.clock()
			slowCap.pauseUntil = os.clock() + slowCap.pauseSeconds
			slowCap.probing = true
			slowCap.lastResult = string.format("still capped after %.0fs idle - now pausing %.0fs", idleSeconds, slowCap.pauseSeconds)
			log("[SlowCapProbe] " .. slowCap.lastResult)
		else
			slowCap.consecutiveSlow = 0
			slowCap.pauseSeconds = Config.SlowCapPauseSeconds
			slowCap.lastResult = string.format("cap lifted after %.0fs idle!", idleSeconds)
			log("[SlowCapProbe] " .. slowCap.lastResult)
		end
		return
	end

	if isSlow then
		slowCap.consecutiveSlow += 1
		if slowCap.consecutiveSlow >= Config.SlowCapThreshold then
			slowCap.pausedAt = os.clock()
			slowCap.pauseUntil = os.clock() + slowCap.pauseSeconds
			slowCap.probing = true
			slowCap.lastResult = string.format("%d consecutive slow matches - pausing %.0fs to test", slowCap.consecutiveSlow, slowCap.pauseSeconds)
			log("[SlowCapProbe] " .. slowCap.lastResult)
		end
	else
		slowCap.consecutiveSlow = 0
	end
end

local function resetBoard()
	state.ids = {}
	state.matched = {}
	state.openFirst = nil
	state.finished = false
	state.boardPairs = 0
	seeded = true
end

local function unmatched(i)
	return not state.matched[i] and cards[i].state ~= "matched"
end

local function collect(predicate)
	local list = {}
	for i = 1, CARD_COUNT do
		if predicate(i) then
			list[#list + 1] = i
		end
	end
	return list
end

----------------------------------------------------------------------
-- Server result tracking (wraps Store.memory, fully transparent)
----------------------------------------------------------------------
local function onResult(action, arg, ok, data)
	if action == "deal" then
		if ok then
			resetBoard()
			stats.rounds += 1
			state.readyAt = os.clock() + Config.DealSettle
			log("new board dealt (round " .. stats.rounds .. ")")
		else
			state.readyAt = os.clock() + 1
			stats.lastError = "deal: " .. tostring(data)
		end
		return
	end
	if action ~= "flip" then
		return
	end
	if not ok or type(data) ~= "table" or data.id == nil then
		stats.failures += 1
		stats.lastError = "flip " .. tostring(arg) .. ": " .. tostring(data)
		log("flip " .. tostring(arg) .. " rejected: " .. tostring(data))
		return
	end

	stats.flips += 1
	state.ids[arg] = data.id
	if data.match == nil then
		state.openFirst = arg
		log("flip " .. arg .. " -> " .. tostring(data.id) .. " (first of pair)")
		return
	end

	local first = state.openFirst
	state.openFirst = nil
	if data.match then
		state.matched[arg] = true
		if first then
			state.matched[first] = true
			state.ids[first] = data.id
		end
		stats.pairs += 1
		state.boardPairs += 1
		log("flip " .. arg .. " -> " .. tostring(data.id) .. " MATCH (" .. state.boardPairs .. "/6)")
		slowCapOnMatch(data.slow == true)
	else
		stats.misses += 1
		log("flip " .. arg .. " -> " .. tostring(data.id) .. " miss")
	end
	if data.slow then
		stats.slow += 1
		if Config.AdaptiveSlow then
			penalty = math.min(penalty + Config.SlowPenaltyStep, Config.SlowPenaltyMax)
		end
		log("server reported 'slow' (penalty " .. penalty .. ")")
	end
	if data.finished then
		state.finished = true
		stats.finishedRounds += 1
		log("board finished (" .. stats.finishedRounds .. " done)")
		if Config.MaxRounds > 0 and stats.finishedRounds >= Config.MaxRounds then
			Config.Enabled = false
			log("MaxRounds reached, paused")
		end
	end
end

local originalMemory = Store.memory
local function wrapper(action, arg)
	if not alive then
		return originalMemory(action, arg)
	end
	if action == "deal" then
		state.readyAt = math.huge
	end
	local ok, data = originalMemory(action, arg)
	if alive then
		local success, err = pcall(onResult, action, arg, ok, data)
		if not success then
			warn("[PonyPairs] tracker error: " .. tostring(err))
		end
	end
	return ok, data
end

if table.isfrozen(Store) and setreadonly then
	pcall(setreadonly, Store, false)
end
local installed = pcall(function()
	Store.memory = wrapper
end)
assert(installed and Store.memory == wrapper, "could not hook Store.memory (table is read-only)")

----------------------------------------------------------------------
-- Decision logic
----------------------------------------------------------------------
local function pickNext()
	local first = state.openFirst
	if first then
		local firstId = state.ids[first]
		if firstId then
			for j = 1, CARD_COUNT do
				if j ~= first and unmatched(j) and state.ids[j] == firstId then
					return j, "partner"
				end
			end
		end
		local unknown = collect(function(j)
			return j ~= first and unmatched(j) and state.ids[j] == nil
		end)
		if #unknown > 0 then
			return unknown[rng:NextInteger(1, #unknown)], "explore"
		end
		local any = collect(function(j)
			return j ~= first and unmatched(j)
		end)
		return any[1], "fallback"
	end

	for i = 1, CARD_COUNT do
		local id = state.ids[i]
		if id and unmatched(i) then
			for j = i + 1, CARD_COUNT do
				if unmatched(j) and state.ids[j] == id then
					return i, "known-pair"
				end
			end
		end
	end

	local unknown = collect(function(i)
		return unmatched(i) and state.ids[i] == nil
	end)
	if #unknown > 0 then
		return unknown[rng:NextInteger(1, #unknown)], "explore"
	end
	return nil
end

----------------------------------------------------------------------
-- Turbo: headless engine. Deals and flips straight against the server through the
-- game's own Store.memory (so money/profile still update). The board UI is not used.
----------------------------------------------------------------------
local function turboPick(ids, matched, openFirst)
	local function free(i) return not matched[i] end
	if openFirst then
		local firstId = ids[openFirst]
		if firstId then
			for j = 1, CARD_COUNT do
				if j ~= openFirst and free(j) and ids[j] == firstId then return j end
			end
		end
		for j = 1, CARD_COUNT do
			if j ~= openFirst and free(j) and ids[j] == nil then return j end
		end
		for j = 1, CARD_COUNT do
			if j ~= openFirst and free(j) then return j end
		end
		return nil
	end
	for i = 1, CARD_COUNT do
		if free(i) and ids[i] then
			for j = i + 1, CARD_COUNT do
				if free(j) and ids[j] == ids[i] then return i end
			end
		end
	end
	for i = 1, CARD_COUNT do
		if free(i) and ids[i] == nil then return i end
	end
	return nil
end

local function turboActive()
	if Config.SlowCapProbe and os.clock() < slowCap.pauseUntil then
		return false
	end
	return unlocked and alive and Config.Enabled and Config.Mode == "Turbo" and not Memory.isActive()
end

local function turboBoard()
	local okDeal, deal = originalMemory("deal")
	if not okDeal then
		stats.failures += 1
		stats.lastError = "deal: " .. tostring(deal)
		return false
	end
	stats.rounds += 1
	local ids, matched, openFirst = {}, {}, nil
	local lastSend, errorsInRow = 0, 0
	for _ = 1, 120 do
		if not turboActive() then return false end
		local index = turboPick(ids, matched, openFirst)
		if not index then return false end
		local gap = Config.TurboGap * rng:NextNumber(1.0, 1.0 + Config.TurboGapVariance)
		local wait = gap - (os.clock() - lastSend)
		if wait > 0 then task.wait(wait) end
		lastSend = os.clock()
		local ok, d = originalMemory("flip", index)
		if not ok then
			if tostring(d) == "slow" then
				stats.rateLimited += 1
				task.wait(0.1)
			else
				stats.failures += 1
				stats.lastError = "flip " .. index .. ": " .. tostring(d)
				errorsInRow += 1
				if errorsInRow >= 1 then return false end
				task.wait(0.4)
			end
		elseif type(d) == "table" and d.id ~= nil then
			errorsInRow = 0
			stats.flips += 1
			ids[index] = d.id
			if d.match == nil then
				openFirst = index
			else
				local first = openFirst
				openFirst = nil
				if d.match then
					matched[index] = true
					if first then matched[first] = true end
					stats.pairs += 1
					slowCapOnMatch(d.slow == true)
				else
					stats.misses += 1
				end
				if d.slow then stats.slow += 1 end
				if d.finished then
					stats.finishedRounds += 1
					return true
				end
			end
		else
			stats.failures += 1
			stats.lastError = "flip " .. index .. ": unexpected reply"
			errorsInRow += 1
			if errorsInRow >= 3 then return false end
		end
	end
	return false
end

task.spawn(function()
	while alive do
		if turboActive() then
			local ok, result = pcall(turboBoard)
			if not ok then
				warn("[PonyPairs] turbo error: " .. tostring(result))
				task.wait(1)
			elseif not result then
				task.wait(0.5)
			end
			if Config.MaxRounds > 0 and stats.finishedRounds >= Config.MaxRounds then
				Config.Enabled = false
			end
		else
			task.wait(0.2)
		end
	end
end)

----------------------------------------------------------------------
-- Auto pack opening (headless: Store.buy / Store.open / Store.packDone)
----------------------------------------------------------------------
local CardData = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("CardData"))

local gameApp
for _, up in pairs(debug.getupvalues(Memory.open)) do
	if type(up) == "table" and type(up.setMode) == "function" then
		gameApp = up
		break
	end
end

local function packScreenBusy()
	return gameApp ~= nil and gameApp.mode == "pack"
end

local packBackoff = 0
local packRun -- quantity run { setId, price, amount, bought, opened, buyStop }; nil outside a run

local function openOnePack()
	local setId = Config.PackSet
	local set = CardData.Sets[setId]
	if not set then
		stats.packNote = "unknown pack " .. tostring(setId)
		return false
	end
	if packScreenBusy() then
		stats.packNote = "pack screen is open, waiting"
		return false
	end
	if Store.pendingPack() then
		Store.packDone()
	end
	if Store.packCount(setId) <= 0 then
		if not Config.PackBuy or packRun then
			stats.packNote = "out of " .. set.name .. " (buying is off)"
			return false
		end
		local price = set.price or 0
		if Store.money() < price then
			stats.packNote = "not enough coins (" .. price .. " needed)"
			return false
		end
		local okBuy, buyRes = Store.buy(setId, nil)
		if not okBuy then
			stats.failures += 1
			stats.packNote = "buy failed: " .. tostring(buyRes)
			return false
		end
		stats.packsBought += 1
		stats.coinsSpent += price
	end
	local ok, res = Store.open(setId, false, 1, {})
	if not ok or type(res) ~= "table" or type(res.cards) ~= "table" then
		if tostring(res):lower():find("slow down", 1, true) then
			stats.rateLimited += 1
			stats.packNote = "server throttle, backing off"
			packBackoff = math.min(packBackoff + 0.5, 4)
			return false
		end
		stats.failures += 1
		stats.packNote = "open failed: " .. tostring(res)
		return false
	end
	packBackoff = 0
	if res.apply then
		res.apply()
	end
	Store.packDone()
	stats.packsOpened += 1
	stats.packNote = nil
	local names = {}
	for _, c in ipairs(res.cards) do
		stats.cardsPulled += 1
		if c.new then
			stats.newCards += 1
		end
		local info = CardData.ById[c.id]
		names[#names + 1] = (info and info.name or tostring(c.id)) .. (info and info.rarity and (" (" .. info.rarity .. ")") or "")
	end
	stats.lastPull = table.concat(names, ", ")
	return true
end

----------------------------------------------------------------------
-- Visible pack opening: drives the game's own desk / pack screen
----------------------------------------------------------------------
local SELL_TIMEOUT = 10 -- seconds to wait for a dupe sale to settle before collecting
local STALL_TIMEOUT = 45 -- seconds without any stage/card progress before giving up
local TICK = 0.1

local packInternals
local function resolvePackInternals()
	if packInternals then
		return packInternals
	end
	assert(gameApp and gameApp.Desk and gameApp.PackOpening, "game app not found (game updated?)")
	local opening, desk = gameApp.PackOpening, gameApp.Desk
	for _, name in ipairs({ "isActive", "back", "pending", "resume", "init" }) do
		assert(type(opening[name]) == "function", "PackOpening." .. name .. " missing")
	end
	assert(type(desk.openNext) == "function" and type(desk.hasPack) == "function", "Desk API changed")
	local found = {}
	for _, up in pairs(debug.getupvalues(opening.init)) do
		if type(up) == "function" then
			local name = debug.info(up, "n")
			if name == "requestOpen" or name == "flingTop" then
				found[name] = up
			end
		end
	end
	assert(found.requestOpen and found.flingTop, "pack screen functions not found (game updated?)")
	packInternals = {
		opening = opening,
		desk = desk,
		requestOpen = found.requestOpen,
		flingTop = found.flingTop,
		screen = function()
			return debug.getupvalue(opening.isActive, 1) -- live pack screen state, nil when closed
		end,
	}
	return packInternals
end

local function sellInProgress(s)
	for _, entry in ipairs(s.cards) do
		if entry.selling or entry.queued then
			return true
		end
	end
	return false
end

-- Presses the game's own button, so its keep count, favourites, placed cards and rarity limit apply.
-- Returns true if the button was pressed; false if the game is not offering a sale.
local function pressSellDupes(g)
	local button = g.opening.sellDupesButton()
	if not button then
		return false
	end
	if type(firesignal) == "function" then
		firesignal(button.MouseButton1Click)
	else
		assert(type(getconnections) == "function", "executor has no firesignal or getconnections")
		for _, connection in ipairs(getconnections(button.MouseButton1Click)) do
			connection:Fire()
		end
	end
	return true
end

-- Plays the currently open pack screen to completion. Returns true once it has closed.
local function drivePackScreen(g)
	local mark, markAt = nil, os.clock()
	local since = os.clock()
	local counted, tearHold = nil, nil
	local sale -- one sale attempt per pack screen
	while alive and Config.PackAuto and Config.PackVisible do
		local s = g.screen()
		if not s then
			if sale and not sale.done then
				stats.dupesSold += sale.before - #sale.state.cards
			end
			return counted ~= nil, counted
		end
		if s.aborted then
			stats.packNote = "game refused the open: " .. tostring(s.res)
			return false
		end
		local now = tostring(s.stage) .. ":" .. tostring(s.idx)
		if now ~= mark then
			mark, markAt, since = now, os.clock(), os.clock()
		elseif os.clock() - markAt > STALL_TIMEOUT and s.stage ~= "inspecting" then
			Config.PackAuto = false
			stats.packNote = "stuck at " .. now .. ", auto-open turned off"
			return false
		end
		if s.stage == "tear" then
			if not s.hold then
				-- same state the game sets after you hold the pack; its render loop does the tear
				tearHold = { t0 = os.clock(), pos = Vector2.zero, auto = true }
				s.hold = tearHold
				if not s.requested then
					g.requestOpen()
				end
				s.tearHintT, s.hintDir = nil, nil
			end
			stats.packNote = "tearing"
		elseif s.stage == "reveal" then
			if not counted then
				counted = #s.cards
				local names = {}
				for _, entry in ipairs(s.cards) do
					local info = entry.card
					names[#names + 1] = tostring(info.name or info.id) .. (info.rarity and (" (" .. info.rarity .. ")") or "")
				end
				stats.lastPull = table.concat(names, ", ")
				for _, entry in ipairs(s.cards) do
					if entry.new then
						stats.newCards += 1
					end
				end
			end
			if not s.drag and os.clock() >= (s.lockUntil or 0) and os.clock() - since >= Config.PackCardView then
				stats.packNote = "card " .. tostring(s.idx) .. "/" .. #s.cards
				since = os.clock()
				task.spawn(g.flingTop, 0)
			end
		elseif s.stage == "summary" then
			counted = counted or #s.cards
			if os.clock() - since >= Config.PackSummaryView then
				if Config.PackSellDupes and not sale then
					local before = #s.cards
					if pressSellDupes(g) then
						sale = { state = s, before = before, at = os.clock() }
						stats.packNote = "selling dupes"
					else
						sale = { done = true }
					end
				elseif sale and not sale.done then
					local waited = os.clock() - sale.at
					if (waited > 0.5 and not sellInProgress(s)) or waited > SELL_TIMEOUT then
						sale.done = true
						stats.dupesSold += sale.before - #s.cards
						since = os.clock() -- show what is left before collecting
					end
				else
					stats.packNote = "collecting"
					since = os.clock()
					g.opening.back()
				end
			end
		end
		task.wait(TICK)
	end
	-- switched off mid-tear: release only the hold this driver created
	local s = g.screen()
	if s and tearHold and s.hold == tearHold then
		s.hold = nil
	end
	return false
end

local function openOnePackVisible()
	local setId = Config.PackSet
	local set = CardData.Sets[setId]
	if not set then
		stats.packNote = "unknown pack " .. tostring(setId)
		return false
	end
	local g = resolvePackInternals()
	if not g.screen() then
		if gameApp.mode ~= "desk" or gameApp.busy then
			stats.packNote = "waiting for the desk (close other screens)"
			return false
		end
		if g.opening.pending() then
			g.opening.resume()
		elseif g.desk.hasPack(setId, false) then
			g.desk.openNext(setId, false)
		elseif Store.packCount(setId) - Store.goldCount(setId) > 0 then
			stats.packNote = "waiting for the pack to appear on the desk"
			return false
		elseif not Config.PackBuy or packRun then
			stats.packNote = "out of " .. set.name .. " (buying is off)"
			return false
		else
			local price = set.price or 0
			if Store.money() < price then
				stats.packNote = "not enough coins (" .. price .. " needed)"
				return false
			end
			local okBuy, buyRes = Store.buy(setId, nil)
			if okBuy then
				stats.packsBought += 1
				stats.coinsSpent += price
			else
				stats.failures += 1
				stats.packNote = "buy failed: " .. tostring(buyRes)
			end
			return false -- the desk shows the new pack shortly; open it on a later pass
		end
		if not g.screen() then
			stats.packNote = "the desk did not open a pack"
			return false
		end
	end
	local done, cardCount = drivePackScreen(g)
	if done then
		stats.packsOpened += 1
		stats.cardsPulled += cardCount
		stats.packNote = nil
	end
	return done
end

local function finishPackRun(note)
	Config.PackAuto = false
	packRun = nil
	stats.packNote = note
end

-- one pass of auto-open; with a quantity chosen it buys them all first, then opens that many
local function packStep()
	local openPack = Config.PackVisible and openOnePackVisible or openOnePack
	if not packRun then
		local amount = math.floor(Config.PackBuyAmount)
		local set = CardData.Sets[Config.PackSet]
		if amount <= 0 or not set then
			return openPack()
		end
		local price = set.price or 0
		local money = Store.money()
		if money < price * amount then
			finishPackRun(string.format("not enough coins for %d packs (need %d, have %d), nothing bought", amount, price * amount, money))
			return false
		end
		packRun = { setId = Config.PackSet, price = price, amount = amount, bought = 0, opened = 0 }
	end
	local run = packRun
	if Config.PackSet ~= run.setId then
		finishPackRun(string.format("pack choice changed, run stopped (bought %d, opened %d)", run.bought, run.opened))
		return false
	end

	if run.bought < run.amount and not run.buyStop then
		if packScreenBusy() or Store.pendingPack() then
			-- finish a leftover pack first; it does not count toward the run
			if Config.PackVisible then openPack() else Store.packDone() end
			return false
		end
		if gameApp.mode ~= "desk" or gameApp.busy then
			stats.packNote = "waiting for the desk before buying"
			return false
		end
		if Store.money() < run.price then
			run.buyStop = "not enough coins"
			return false
		end
		local okBuy, buyRes = Store.buy(run.setId, nil)
		if okBuy then
			run.bought += 1
			stats.packsBought += 1
			stats.coinsSpent += run.price
			stats.packNote = string.format("buying %d/%d", run.bought, run.amount)
		else
			stats.failures += 1
			run.buyStop = tostring(buyRes) -- no retry: open what was bought, then stop
		end
		return false
	end

	local stopText = run.buyStop and (" | buying stopped: " .. run.buyStop) or ""
	if run.bought == 0 then
		finishPackRun("nothing bought" .. stopText)
		return false
	end
	if gameApp.mode == "desk" and not Store.pendingPack() and Store.packCount(run.setId) - Store.goldCount(run.setId) <= 0 then
		finishPackRun(string.format("no packs left, run stopped (bought %d, opened %d)", run.bought, run.opened) .. stopText)
		return false
	end
	local done = openPack()
	if done and packRun == run then
		run.opened += 1
		if run.opened >= run.bought then
			finishPackRun(string.format("finished: bought %d/%d, opened %d", run.bought, run.amount, run.opened) .. stopText)
		end
	end
	return done
end

task.spawn(function()
	while alive do
		if unlocked and Config.PackAuto then
			local ok, result = pcall(packStep)
			if not ok then
				stats.packNote = "error: " .. tostring(result)
				task.wait(1)
			elseif result then
				task.wait(Config.PackGap)
			else
				task.wait(1 + packBackoff)
			end
			if Config.PackLimit > 0 and stats.packsOpened >= Config.PackLimit then
				Config.PackAuto = false
			end
		else
			packRun = nil
			task.wait(0.25)
		end
	end
end)

----------------------------------------------------------------------
-- Collection duplicates. Same protections as the game's own sell screens, using the player's
-- in-game "keep" and "dupe" settings. Selling cannot be undone, so anything unclear is skipped.
----------------------------------------------------------------------
local COLLECTION_INTERVAL, COLLECTION_RETRY, COLLECTION_MAX_FAILURES = 15, 60, 3
-- the game's four "dupe" setting choices (PackOpening, read 2026-11-26): highest rarity each one sells
local DUPE_RULES = {
	{ rarity = "SR", also = { GSR = true } },
	{ rarity = "SSR" },
	{ rarity = "UR" },
	{ everything = true },
}

-- returns { have = {id = copies to sell}, count, value, keep, ruleText } or nil plus a reason
local function collectionPlan()
	local profile = Store.profile
	if type(profile) ~= "table" or type(profile.owned) ~= "table" or type(profile.settings) ~= "table" then
		return nil, "collection data not available"
	end
	local keepSetting, dupeSetting = profile.settings.keep, profile.settings.dupe
	local rule = DUPE_RULES[dupeSetting]
	if type(keepSetting) ~= "number" or not rule then
		return nil, "could not read your keep / dupe settings, nothing will be sold"
	end
	local keep = math.clamp(math.floor(keepSetting), 1, 3) -- never "keep none"
	local limit = math.huge
	if not rule.everything then
		local info = CardData.Rarities[rule.rarity]
		if not info then return nil, "rarity data changed, nothing will be sold" end
		limit = info.tier
	end
	local plan = { have = {}, count = 0, value = 0, keep = keep, ruleText = rule.everything and "every rarity" or (rule.rarity .. " and below") }
	for id, owned in pairs(profile.owned) do
		local card = CardData.ById[id]
		local rarity = card and CardData.Rarities[card.rarity]
		if type(owned) == "number" and card and rarity and not card.secret
			and not Store.isFav(id)
			and not (type(profile.gold) == "table" and profile.gold[id]) -- skip cards with a gold record
			and (rarity.tier <= limit or (rule.also ~= nil and rule.also[card.rarity] == true)) then
			local extra = owned - math.max(keep, Store.placed(id))
			if extra > 0 then
				plan.have[id] = extra
				plan.count += extra
				plan.value += (rarity.sell or 0) * extra
			end
		end
	end
	return plan
end

task.spawn(function()
	local nextCheck, failures = 0, 0
	while alive do
		if not (unlocked and Config.CollectionSell) then
			nextCheck, failures = 0, 0
		elseif os.clock() >= nextCheck then
			local ok, err = pcall(function()
				if not gameApp or gameApp.mode ~= "desk" or gameApp.busy or Store.pendingPack() then
					stats.collectionNote = "waiting for the main desk"
					nextCheck = os.clock() + 2
					return
				end
				local plan, reason = collectionPlan()
				if not plan then error(reason, 0) end
				nextCheck = os.clock() + COLLECTION_INTERVAL
				if plan.count == 0 then
					stats.collectionNote = "no duplicates to sell"
					return
				end
				if not Config.CollectionSell then return end
				local moneyBefore = Store.money()
				local sold, reply = Store.sell(plan.have, { keep = plan.keep })
				if not sold then error("sale refused: " .. tostring(reply), 0) end
				local soldCount = 0
				if type(reply) == "table" and type(reply.sold) == "table" then
					for _, n in pairs(reply.sold) do soldCount += tonumber(n) or 0 end
				else
					soldCount = plan.count
				end
				failures = 0
				local gained = math.max(Store.money() - moneyBefore, 0)
				stats.collectionSold += soldCount
				stats.collectionCoins += gained
				stats.collectionNote = string.format("sold %d cards for %d coins at %s", soldCount, gained, os.date("%H:%M:%S"))
				log(stats.collectionNote)
			end)
			if not ok then
				failures += 1
				stats.collectionNote = tostring(err)
				warn("[PonyPairs] collection sell: " .. tostring(err))
				nextCheck = os.clock() + COLLECTION_RETRY
				if failures >= COLLECTION_MAX_FAILURES then
					Config.CollectionSell = false
					stats.collectionNote = "turned off after 3 failures: " .. tostring(err)
				end
			end
		end
		task.wait(0.5)
	end
end)

----------------------------------------------------------------------
-- Sticker postcards: visible drag, then the game's own place / send functions
----------------------------------------------------------------------
local LIFT_HEIGHT = 0.55    -- studs; the height the game holds a dragged sticker at
-- the game says "perfect" under 0.07 studs from the outline center, "nice" from 0.07 to under 0.18
local NICE_OFFSET = Vector3.new(0.12, 0, 0)
local UNPAID_LIMIT = 2      -- turn off after this many postcards in a row pay nothing
local RunService = game:GetService("RunService")

local stickerInternals
local function resolveStickerInternals()
	if stickerInternals then
		return stickerInternals
	end
	assert(gameApp, "game app not found (game updated?)")
	local module = require(lp.PlayerScripts.Client:WaitForChild("StickerGame", 10))
	for _, name in ipairs({ "open", "close", "init" }) do
		assert(type(module[name]) == "function", "StickerGame." .. name .. " missing")
	end
	local found = {}
	for _, up in pairs(debug.getupvalues(module.init)) do
		if type(up) == "function" then
			local name = debug.info(up, "n")
			if name == "place" or name == "sendPostcard" or name == "pickSticker" then
				found[name] = up
			end
		end
	end
	assert(found.place and found.sendPostcard and found.pickSticker, "sticker functions not found (game updated?)")
	stickerInternals = {
		module = module,
		place = found.place,
		send = found.sendPostcard,
		round = function()
			local round = debug.getupvalue(found.pickSticker, 1)
			assert(round == nil or (type(round) == "table" and type(round.stickers) == "table"), "unexpected sticker round")
			return round
		end,
		isOpen = function()
			return debug.getupvalue(module.close, 1) == true
		end,
		userHolding = function()
			return debug.getupvalue(module.close, 2) ~= nil
		end,
	}
	return stickerInternals
end

local function stickerStillValid(g, round)
	return alive and Config.StickerEnabled and g.isOpen() and g.round() == round
end

local function stickerWait(g, round, seconds)
	local untilTime = os.clock() + seconds
	while os.clock() < untilTime do
		if not stickerStillValid(g, round) then
			return false
		end
		task.wait(0.05)
	end
	return stickerStillValid(g, round)
end

local function dragAndPlace(g, round, sticker)
	-- "held" stops a mouse click from grabbing the same sticker mid-drag
	sticker.state = "held"
	local part = sticker.part
	local from = sticker.homeCF.Position
	local goal = sticker.targetCF.Position
	-- the game's own count, so stickers already placed on this card are included
	if round.perfects >= Config.StickerPerfectCount then
		goal += NICE_OFFSET
	end
	local started = os.clock()
	local alpha = 0
	while alpha < 1 do
		if not stickerStillValid(g, round) then
			part.CFrame = sticker.homeCF
			sticker.state = "sheet"
			return false
		end
		alpha = math.min((os.clock() - started) / math.max(Config.StickerDragTime, 0.05), 1)
		local eased = alpha * alpha * (3 - 2 * alpha)
		local position = from:Lerp(goal, eased) + Vector3.new(0, math.sin(alpha * math.pi) * LIFT_HEIGHT, 0)
		part.CFrame = CFrame.new(position) * sticker.homeRot:Lerp(sticker.targetRot, eased)
		RunService.RenderStepped:Wait()
	end
	local ok, placed = pcall(g.place, sticker, goal)
	if not ok or not placed then
		part.CFrame = sticker.homeCF
		sticker.state = "sheet"
		error("game rejected placement: " .. tostring(placed))
	end
	stats.stickersPlaced += 1
	return true
end

-- Performs at most one action and returns how long to wait before the next one.
local function stickerStep()
	local g = resolveStickerInternals()
	if not g.isOpen() then
		if not Config.StickerAutoOpen then
			stats.stickerNote = "waiting for you to open the sticker desk"
		elseif gameApp.mode == "desk" and not gameApp.busy then
			stats.stickerNote = "opening the sticker desk"
			g.module.open()
			return 1.5
		else
			stats.stickerNote = "waiting for the main desk"
		end
		return 0.5
	end
	local round = g.round()
	if not round or round.sliding or round.sending then
		stats.stickerNote = "waiting for the next postcard"
		return 0.2
	end
	if g.userHolding() then
		stats.stickerNote = "paused while you hold a sticker"
		return 0.2
	end
	if round.complete then
		stats.stickerNote = "mailing the postcard"
		if not stickerWait(g, round, Config.StickerPickDelay) or round.sending then
			return 0.2
		end
		local before = Store.money()
		-- the game discards the server's refusal, so record the reply while this one send runs
		local appStore = gameApp.Store
		local originalPostcard = appStore.postcard
		local reply
		local function recordingPostcard(...)
			local results = table.pack(originalPostcard(...))
			reply = results
			return table.unpack(results, 1, results.n)
		end
		appStore.postcard = recordingPostcard
		local sent, sendError = pcall(g.send) -- yields until the server answers and the next card slides in
		if appStore.postcard == recordingPostcard then
			appStore.postcard = originalPostcard
		end
		assert(sent, sendError)
		local earned = Store.money() - before
		if reply and not reply[1] then
			stats.postcardReply = tostring(reply[2])
			warn("[PonyPairs] postcard refused, server reply: " .. stats.postcardReply)
		elseif reply then
			stats.postcardReply = nil
		end
		stats.postcards += 1
		if earned > 0 then
			stats.postcardCoins += earned
			stats.unpaidStreak = 0
		else
			stats.unpaidStreak += 1
			if stats.unpaidStreak >= UNPAID_LIMIT then
				stats.unpaidStreak = 0
				Config.StickerEnabled = false
				stats.stickerNote = "turned off: 2 postcards paid nothing. Server reply: " .. tostring(stats.postcardReply)
			end
		end
		return 0.5
	end
	for _, sticker in ipairs(round.stickers) do
		if sticker.state == "sheet" then
			stats.stickerNote = string.format("placing %d/%d", round.placed + 1, round.k)
			if stickerWait(g, round, Config.StickerPickDelay) and sticker.state == "sheet" and not g.userHolding() then
				dragAndPlace(g, round, sticker)
			end
			return 0.1
		end
	end
	return 0.2
end

task.spawn(function()
	while alive do
		local pause = 0.25
		if unlocked and Config.StickerEnabled then
			local ok, result = pcall(stickerStep)
			if ok then
				pause = result
			else
				Config.StickerEnabled = false
				stats.stickerNote = "turned off after error: " .. tostring(result)
				warn("[PonyPairs] sticker error: " .. tostring(result))
			end
		end
		task.wait(pause)
	end
end)

local UserInputService = game:GetService("UserInputService")
local clickConn = UserInputService.InputBegan:Connect(function(input)
	local t = input.UserInputType
	if (t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch) and Memory.isActive() then
		stats.userClicks += 1
	end
end)

local function step()
	if Config.SlowCapProbe and os.clock() < slowCap.pauseUntil then
		return math.min(slowCap.pauseUntil - os.clock(), 1)
	end
	if Config.Mode == "Turbo" then
		return 0.25
	end
	if not Memory.isActive() then
		if Config.AutoOpen and os.clock() - lastOpenTry > 3 then
			lastOpenTry = os.clock()
			pcall(Memory.open)
		end
		seeded = false
		seedStart = os.clock()
		return 0.3
	end
	if state.finished then
		return 0.25
	end
	if os.clock() < state.readyAt then
		return 0.1
	end

	if not seeded then
		-- joined mid-round: let a mismatched pair flip down, adopt a lone face-up card as the open first
		local ups = collect(function(i)
			return unmatched(i) and (cards[i].state == "up" or cards[i].state == "queued")
		end)
		if #ups > 1 and os.clock() - seedStart < 2.5 then
			return 0.2
		end
		if #ups == 1 and state.openFirst == nil then
			state.openFirst = ups[1]
		end
		seeded = true
	end

	local index, reason = pickNext()
	if not index then
		return 0.25
	end

	local card = cards[index]
	stats.taps += 1
	local failsBefore = stats.failures
	tapCard(card)
	if card.state ~= "queued" then
		rejected += 1
		return 0.2 + math.min(rejected * 0.1, 1)
	end
	rejected = 0

	local t0 = os.clock()
	while card.state == "queued" and alive and os.clock() - t0 < Config.ResolveTimeout do
		task.wait()
	end
	if card.state == "queued" then
		stats.timeouts += 1
		return 1
	end
	if stats.failures > failsBefore then
		return 0.5
	end
	local mode = Modes[Config.Mode] or Modes.Human
	local extra = Config.AdaptiveSlow and penalty or 0
	local jitter = humanSpread(rng, mode.jitter)
	local hesitation = 0
	if rng:NextNumber() < Config.HesitationChance then
		hesitation = rng:NextNumber(Config.HesitationMin, Config.HesitationMax)
	end
	return mode.delay + extra + jitter + hesitation
end

task.spawn(function()
	while alive do
		local waitSeconds = 0.1
		if unlocked and Config.Enabled then
			local ok, result = pcall(step)
			if ok then
				waitSeconds = result or 0.1
			else
				warn("[PonyPairs] step error: " .. tostring(result))
				waitSeconds = 1
			end
		end
		task.wait(waitSeconds)
	end
end)

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------
local api
local destroyGui

----------------------------------------------------------------------
-- GUI
----------------------------------------------------------------------
local WINDUI_URL = "https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"

local GUI_NAME = "DanYss | Peace"
local GUI_VERSION = "v1.0"
local DISCORD_LINK = "https://discord.gg/HvvpEhtHdX"
local EDITION = "Freemium"
local EDITION_GREEN = Color3.fromHex("#10C550")
-- client-side gate only: anyone who can edit this file can remove it
local ACCESS_KEY = "Fluttershy" -- fixed key, used only while KEY_FEED_URL is empty
-- raw address of the bot's keyfeed.json (see the bot's README). Empty = daily bot key not set up yet.
local KEY_FEED_URL = "https://gist.githubusercontent.com/DzanZ333/95a0907fe3b2676b048b1c398f922ffa/raw/keyfeed.json"
-- first game thumbnail returned by thumbnails.roblox.com for universe 10775160561 (read 2026-11-26)
local GAME_THUMBNAIL = "rbxthumb://type=Asset&id=139304562472539&w=768&h=432"

-- server name and icon as returned by Discord's invite lookup on 2026-11-26
local DISCORD_NAME = "Peace Hub"
local DISCORD_ICON_URL = "https://cdn.discordapp.com/icons/1387810609776562316/054a948e53e069f6537536023c3860be.png?size=256"
local DISCORD_ICON_PATH = "PonyPairsSolver/discord-icon.png"

-- returns a local asset id for the server icon, or nil so the menu still works without a picture
local function loadDiscordPicture()
	local ok, asset = pcall(function()
		if not isfile(DISCORD_ICON_PATH) then
			local send = request or http_request or (syn and syn.request)
			local response = send({ Url = DISCORD_ICON_URL, Method = "GET" })
			assert(response.StatusCode == 200, "icon download returned " .. tostring(response.StatusCode))
			assert(response.Body:sub(1, 4) == "\137PNG", "icon download was not a PNG")
			if not isfolder("PonyPairsSolver") then makefolder("PonyPairsSolver") end
			writefile(DISCORD_ICON_PATH, response.Body)
		end
		return getcustomasset(DISCORD_ICON_PATH)
	end)
	if ok then return asset end
	warn("[PonyPairs] Discord picture unavailable: " .. tostring(asset))
	return nil
end

-- Key access. Fixed key: 24 hours from the moment it is typed in.
-- Daily bot key: only the key whose SHA-256 is in the feed, until the time the feed gives.
local KeyGate = { LIFETIME = 24 * 60 * 60, MAX_FEED_SPAN = 48 * 60 * 60, RECHECK = 600,
	RECORD_PATH = "PonyPairsSolver/key-session.json", session = nil, nextRecheck = 0 }
local keyGrantedAt -- os.time() of the accepted entry

function KeyGate.rotating()
	return KEY_FEED_URL ~= ""
end

function KeyGate.sha256(message)
	local K = {
		0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
		0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
		0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
		0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
		0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
		0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
		0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
		0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
	}
	local H = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
	local padded = message .. "\128" .. string.rep("\0", (55 - #message) % 64) .. string.pack(">I8", #message * 8)
	local rrotate, rshift, bxor, band, bnot = bit32.rrotate, bit32.rshift, bit32.bxor, bit32.band, bit32.bnot
	local w = {}
	for chunk = 1, #padded, 64 do
		for i = 1, 16 do
			w[i] = (string.unpack(">I4", padded, chunk + (i - 1) * 4))
		end
		for i = 17, 64 do
			local x, y = w[i - 15], w[i - 2]
			local s0 = bxor(rrotate(x, 7), rrotate(x, 18), rshift(x, 3))
			local s1 = bxor(rrotate(y, 17), rrotate(y, 19), rshift(y, 10))
			w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % 4294967296
		end
		local a, b, c, d, e, f, g, h = table.unpack(H)
		for i = 1, 64 do
			local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
			local choose = bxor(band(e, f), band(bnot(e), g))
			local t1 = (h + S1 + choose + K[i] + w[i]) % 4294967296
			local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
			local majority = bxor(band(a, b), band(a, c), band(b, c))
			local t2 = (S0 + majority) % 4294967296
			h, g, f, e, d, c, b, a = g, f, e, (d + t1) % 4294967296, c, b, a, (t1 + t2) % 4294967296
		end
		for i, v in ipairs({ a, b, c, d, e, f, g, h }) do
			H[i] = (H[i] + v) % 4294967296
		end
	end
	return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", table.unpack(H))
end

-- returns the validated feed, or nil plus a reason
function KeyGate.parseFeed(text)
	local ok, feed = pcall(function() return game:GetService("HttpService"):JSONDecode(text) end)
	if not ok or type(feed) ~= "table" or feed.version ~= 1 then
		return nil, "key feed is not set up yet"
	end
	local hash, issued, expires = feed.sha256, feed.issuedAt, feed.expiresAt
	if type(hash) ~= "string" or #hash ~= 64 or hash:find("[^0-9a-f]") or type(issued) ~= "number" or type(expires) ~= "number"
		or not (expires > issued and expires - issued <= KeyGate.MAX_FEED_SPAN) then
		return nil, "key feed has invalid values"
	end
	if type(feed.accounts) ~= "table" then
		return nil, "key feed has no account list (update the bot)"
	end
	return feed
end

-- 3 accounts per device: the bot enforces the count at /register; the script only runs a listed code.
-- The raw hardware id never leaves the device, only a hash of it inside this code.
function KeyGate.deviceCode()
	local ok, hwid = pcall(function() return gethwid() end)
	if not ok or type(hwid) ~= "string" or hwid == "" then return nil end
	return "DP-" .. KeyGate.sha256("danyss-peace-device:" .. hwid):sub(1, 24) .. "-" .. string.format("%.0f", lp.UserId)
end

-- clones the key window's own copy button, so it looks and sits like the rest of the window
function KeyGate.addCodeButton(linkLabel, code)
	local link = linkLabel:FindFirstAncestorWhichIsA("TextButton")
	if not link then return end
	local copy = link:Clone()
	local copyLabel = copy:FindFirstChildWhichIsA("TextLabel", true)
	if not copyLabel then return end
	-- both buttons share the space left of Submit, so their icons are hidden
	for _, button in ipairs({ link, copy }) do
		for _, item in ipairs(button:GetDescendants()) do
			if item:IsA("ImageLabel") and item.Parent:FindFirstChildOfClass("TextLabel") then item.Visible = false end
			if item:IsA("UIPadding") then item.PaddingLeft, item.PaddingRight = UDim.new(0, 12), UDim.new(0, 12) end
		end
	end
	linkLabel.Text = "Link"
	copyLabel.Text = "Copy code"
	copy.LayoutOrder = link.LayoutOrder + 1
	copy.Parent = link.Parent
	copy.MouseButton1Click:Connect(function()
		local copied = pcall(function() setclipboard(code) end)
		copyLabel.Text = copied and "Copied!" or "Failed"
		task.wait(2)
		copyLabel.Text = "Copy code"
	end)
end

-- WindUI's key window has a fixed size, so a corner handle scales the whole card
function KeyGate.makeResizable(keyFolder)
	local box = keyFolder:FindFirstChildWhichIsA("TextBox", true)
	local screen = keyFolder:FindFirstAncestorWhichIsA("ScreenGui")
	if not (box and screen) then return nil end
	local card = box
	while card.Parent ~= keyFolder do card = card.Parent end
	if card.AbsoluteSize.X >= screen.AbsoluteSize.X then -- a full-screen backdrop: scale what is inside it
		local inner = box
		while inner.Parent ~= card do inner = inner.Parent end
		card = inner
	end
	local scale = card:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Scale = 0.7 -- starting size; the handle still allows 0.5 to 1.5
	scale.Parent = card

	local handle = Instance.new("TextButton")
	handle.Name = "ResizeHandle"
	handle.AnchorPoint = Vector2.new(0.5, 0.5)
	handle.Size = UDim2.fromOffset(32, 32) -- big enough for a finger
	handle.BackgroundColor3 = Color3.fromHex("#10C550")
	handle.TextColor3 = Color3.new(1, 1, 1)
	handle.Text = "\u{2198}"
	handle.TextSize = 20
	handle.ZIndex = 10000
	Instance.new("UICorner").Parent = handle
	local function place()
		local corner = card.AbsolutePosition + card.AbsoluteSize - screen.AbsolutePosition
		handle.Position = UDim2.fromOffset(corner.X, corner.Y)
	end

	local input = game:GetService("UserInputService")
	local dragging, startDistance, startScale
	local function distance(position)
		local center = card.AbsolutePosition + card.AbsoluteSize / 2
		return (Vector2.new(position.X, position.Y) - center).Magnitude
	end
	local connections = {
		card:GetPropertyChangedSignal("AbsoluteSize"):Connect(place),
		card:GetPropertyChangedSignal("AbsolutePosition"):Connect(place),
		card.AncestryChanged:Connect(function()
			if not card:IsDescendantOf(keyFolder) then handle:Destroy() end
		end),
		handle.InputBegan:Connect(function(object)
			if object.UserInputType == Enum.UserInputType.MouseButton1 or object.UserInputType == Enum.UserInputType.Touch then
				dragging, startDistance, startScale = object, math.max(distance(object.Position), 1), scale.Scale
			end
		end),
		input.InputChanged:Connect(function(object)
			if not dragging then return end
			if object == dragging or (dragging.UserInputType == Enum.UserInputType.MouseButton1
				and object.UserInputType == Enum.UserInputType.MouseMovement) then
				scale.Scale = math.clamp(startScale * distance(object.Position) / startDistance, 0.5, 1.5)
			end
		end),
		input.InputEnded:Connect(function(object)
			if dragging and (object == dragging or object.UserInputType == dragging.UserInputType) then dragging = nil end
		end),
	}
	handle.Destroying:Connect(function()
		for _, connection in ipairs(connections) do connection:Disconnect() end
	end)
	handle.Parent = keyFolder
	place()
	return handle
end

-- how often the script has been run on this device, per Roblox account; stays in the executor's workspace
function KeyGate.countRun()
	local ok, err = pcall(function()
		local path, http = "PonyPairsSolver/runs.json", game:GetService("HttpService")
		local runs = isfile(path) and http:JSONDecode(readfile(path)) or {}
		local id = string.format("%.0f", lp.UserId)
		runs[id] = (tonumber(runs[id]) or 0) + 1
		if not isfolder("PonyPairsSolver") then makefolder("PonyPairsSolver") end
		writefile(path, http:JSONEncode(runs))
		local total = 0
		for _, count in pairs(runs) do total += tonumber(count) or 0 end
		KeyGate.runs = { account = runs[id], device = total }
	end)
	if not ok then warn("[PonyPairs] could not count this run: " .. tostring(err)) end
end
KeyGate.countRun()

-- run log for the managers. Left empty here; set_webhook.py fills it into the copy that gets shared.
-- Anyone who reads that copy can find the address, so treat what arrives there as unverified.
KeyGate.WEBHOOK_URL = "https://discord.com/api/webhooks/1575403581761388554/9OiCSVgyjV3AbVFyxd3RtDYzrpn9re6G3CAe7ZoRgVjI_ZHIsBalqny2WSnvGPdJKAtL"

function KeyGate.logRun() -- yields
	if KeyGate.WEBHOOK_URL == "" then return end
	local ok, err = pcall(function()
		local send = request or http_request or (syn and syn.request)
		local response = send({
			Url = KeyGate.WEBHOOK_URL,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = game:GetService("HttpService"):JSONEncode({
				content = string.format("\u{25B6} `%s` (ID %.0f) ran the script \u{2014} run #%s on this device",
					lp.Name, lp.UserId, tostring(KeyGate.runs and KeyGate.runs.account or "?")),
				allowed_mentions = { parse = {} },
			}),
		})
		assert(response.StatusCode >= 200 and response.StatusCode < 300, "status " .. tostring(response.StatusCode))
	end)
	-- the error text is not printed: it could contain the address
	if not ok then warn("[PonyPairs] run log not sent") end
end

function KeyGate.check(key, feed, now)
	if now >= feed.expiresAt then return false, "the feed's key has expired, no new one is published yet" end
	if feed.issuedAt > now + 300 then return false, "key is dated in the future, check the device clock" end
	if KeyGate.sha256(key) ~= feed.sha256 then return false, "not today's key (a new one can take a few minutes to arrive)" end
	local code = KeyGate.deviceCode()
	if not code then return false, "this executor cannot identify the device (no gethwid)" end
	if not table.find(feed.accounts, KeyGate.sha256(code)) then
		return false, "this account is not registered for this device: in Discord use /register with " .. code, code
	end
	return true
end

function KeyGate.fetch() -- yields
	local ok, body = pcall(function()
		local send = request or http_request or (syn and syn.request)
		local response = send({ Url = KEY_FEED_URL .. "?t=" .. os.time(), Method = "GET" })
		assert(response.StatusCode == 200, "status " .. tostring(response.StatusCode))
		return response.Body
	end)
	if not ok then return nil, "cannot reach the key feed: " .. tostring(body) end
	return KeyGate.parseFeed(body)
end

local function keySecondsFrom(grantedAt)
	local age = os.time() - grantedAt
	if age < -60 then return 0 end -- dated in the future: the clock or the file was changed
	return math.max(KeyGate.LIFETIME - age, 0)
end

function KeyGate.secondsLeft()
	if not keyGrantedAt then return 0 end
	if KeyGate.rotating() then
		local session = KeyGate.session
		return (session and not session.revoked) and math.max(session.expiresAt - os.time(), 0) or 0
	end
	return keySecondsFrom(keyGrantedAt)
end

-- while running: notice a key the bot replaced early. A failed download never ends a session.
function KeyGate.recheck()
	local session = KeyGate.session
	if not (KeyGate.rotating() and session) or os.clock() < KeyGate.nextRecheck then return end
	KeyGate.nextRecheck = os.clock() + KeyGate.RECHECK
	task.spawn(function()
		local feed = KeyGate.fetch()
		-- only a newer feed counts, so a stale cached copy cannot end the session
		if feed and feed.issuedAt > session.issuedAt and feed.sha256 ~= session.sha256 then
			session.revoked = true
		elseif feed and feed.issuedAt >= session.issuedAt then
			local wasListed = session.registered
			KeyGate.noteDevice(session, feed)
			-- dropped from the list while running (/unwhitelist or /resetdevice): end the session
			if wasListed and session.registered == false then session.revoked = true end
		end
	end)
end

local function saveKeyRecord(key, grantedAt)
	local ok, err = pcall(function()
		if not isfolder("PonyPairsSolver") then makefolder("PonyPairsSolver") end
		writefile(KeyGate.RECORD_PATH, game:GetService("HttpService"):JSONEncode({ key = key, enteredAt = grantedAt }))
	end)
	if not ok then warn("[PonyPairs] could not remember the key: " .. tostring(err)) end
end

-- what the Status tab shows about this account and device
function KeyGate.noteDevice(session, feed)
	local code = KeyGate.deviceCode()
	if not code then return end
	session.registered = table.find(feed.accounts, KeyGate.sha256(code)) ~= nil
	local device = code:match("^(DP%-%x+)%-")
	local counts = type(feed.devices) == "table" and feed.devices
	session.used = counts and tonumber(counts[KeyGate.sha256(device)] or 0) or nil
	session.checkedAt = os.time()
end

local function startFeedSession(feed)
	KeyGate.session = { sha256 = feed.sha256, issuedAt = feed.issuedAt, expiresAt = feed.expiresAt }
	KeyGate.noteDevice(KeyGate.session, feed)
	KeyGate.nextRecheck = os.clock() + KeyGate.RECHECK
end

local function loadKeyRecord()
	local ok, record = pcall(function()
		return game:GetService("HttpService"):JSONDecode(readfile(KeyGate.RECORD_PATH))
	end)
	if not (ok and type(record) == "table" and type(record.key) == "string" and type(record.enteredAt) == "number") then
		return nil
	end
	if KeyGate.rotating() then
		local feed, reason = KeyGate.fetch()
		local valid = false
		if feed then valid, reason = KeyGate.check(record.key, feed, os.time()) end
		if not valid then
			warn("[PonyPairs] saved key not accepted: " .. tostring(reason))
			return nil
		end
		startFeedSession(feed)
		return record.enteredAt
	end
	if record.key == ACCESS_KEY and keySecondsFrom(record.enteredAt) > 0 then
		return record.enteredAt
	end
	return nil
end

function KeyGate.accept(input) -- called by the key window
	if type(input) ~= "string" then return false end
	local key = input:match("^%s*(.-)%s*$")
	if KeyGate.rotating() then
		local feed, reason = KeyGate.fetch()
		local valid, unregistered = false, nil
		if feed then valid, reason, unregistered = KeyGate.check(key, feed, os.time()) end
		if not valid then
			warn("[PonyPairs] key refused: " .. tostring(reason))
			if unregistered and KeyGate.onUnregistered then KeyGate.onUnregistered(unregistered) end
			return false
		end
		startFeedSession(feed)
	elseif key ~= ACCESS_KEY then
		return false
	end
	keyGrantedAt = os.time()
	saveKeyRecord(key, keyGrantedAt)
	return true
end

local function keyTimeText()
	local left = KeyGate.secondsLeft()
	return string.format("%02d:%02d:%02d (%s)", left // 3600, left % 3600 // 60, left % 60,
		KeyGate.rotating() and "daily bot key" or "fixed key, bot feed not set")
end

local function buildGui()
	local okLib, lib = pcall(function() return loadstring(game:HttpGet(WINDUI_URL, true))() end)
	if not okLib or type(lib) ~= "table" then
		warn("[PonyPairs] WindUI failed to load, running headless: " .. tostring(lib))
		return nil
	end

	-- until the key is accepted, Destroy() has to remove the key window and stop its wait loop
	local buildThread = coroutine.running()
	destroyGui = function()
		for _, name in ipairs({ "ScreenGui", "NotificationGui", "DropdownGui", "TooltipGui" }) do
			local gui = lib[name]
			if typeof(gui) == "Instance" then gui:Destroy() end
		end
		if not unlocked then pcall(task.cancel, buildThread) end
	end

	local discordPicture = loadDiscordPicture()
	-- the key window's own copy button is labelled "Get key"; relabel it once it exists
	local registerCode -- set below when the key screen also needs a "Copy code" button
	local relabel = task.spawn(function()
		local keyFolder = lib.ScreenGui and lib.ScreenGui:FindFirstChild("KeySystem")
		for _ = 1, 100 do
			if not keyFolder or unlocked or not alive then return end
			for _, item in ipairs(keyFolder:GetDescendants()) do
				if item:IsA("TextLabel") and item.Text == "Get key" then
					item.Text = "Copy link"
					-- WindUI crops the thumbnail to its tall panel; fit shows the whole server picture
					for _, picture in ipairs(keyFolder:GetDescendants()) do
						if picture:IsA("ImageLabel") and picture.Image == discordPicture then picture.ScaleType = Enum.ScaleType.Fit end
					end
					local sized, handle = pcall(KeyGate.makeResizable, keyFolder)
					if sized then KeyGate.resizeHandle = handle else warn("[PonyPairs] key window resize unavailable: " .. tostring(handle)) end
					if registerCode then
						local ok, err = pcall(KeyGate.addCodeButton, item, registerCode)
						if not ok then warn("[PonyPairs] copy-code button unavailable: " .. tostring(err)) end
					end
					return
				end
			end
			task.wait(0.1)
		end
	end)

	keyGrantedAt = loadKeyRecord() -- nil means the key window has to be shown

	-- the key was right but this account is not registered: hand the user the code to register
	KeyGate.onUnregistered = function(code)
		local copied = pcall(function() setclipboard(code) end)
		pcall(function()
			lib:Notify({ Title = GUI_NAME, Duration = 30,
				Content = "Key is correct, but this account is not registered. In Discord type /register and paste this code"
					.. (copied and " (copied)" or "") .. ":\n" .. code })
		end)
	end
	registerCode = KeyGate.rotating() and keyGrantedAt == nil and KeyGate.deviceCode() or nil
	local registerNote = ""
	if KeyGate.rotating() then
		registerNote = "\nMax 3 accounts per device (checked with a scrambled device ID).\nRegister once: tap Copy code, then use /register in Discord.\n"
			.. (KeyGate.deviceCode() or "this executor cannot identify the device")
	end
	if KeyGate.WEBHOOK_URL ~= "" then
		registerNote ..= "\nEach run is logged with your Roblox name for the managers."
	end

	local okWin, Window = pcall(function()
		return lib:CreateWindow({
			Title = GUI_NAME,
			Icon = "layers",
			Folder = "PonyPairsSolver",
			NewElements = true,
			KeySystem = (keyGrantedAt == nil) and {
				Title = GUI_NAME .. " " .. EDITION,
				Note = "Free version. Get the key from our Discord:\n" .. DISCORD_LINK .. "\nCopy link puts it on your clipboard.\n"
					.. (KeyGate.rotating() and "The key changes every 24 hours." or "Access lasts 24 hours.") .. registerNote,
				URL = DISCORD_LINK, -- WindUI's "Get key" button copies this to the clipboard
				Thumbnail = discordPicture and { Image = discordPicture, Width = 200 } or nil,
				KeyValidator = KeyGate.accept,
				SaveKey = false, -- the 24 hour record above replaces the library's permanent save
			} or nil,
			HideSearchBar = true,
			OpenButton = {
				Title = "Open " .. GUI_NAME,
				Icon = discordPicture or "layers", -- Peace Hub server picture; plain icon if it cannot load
				CornerRadius = UDim.new(1, 0),
				StrokeThickness = 3,
				Enabled = true,
				Draggable = true,
				OnlyMobile = false,
				Scale = 0.5,
				Color = ColorSequence.new(EDITION_GREEN, Color3.fromHex("#4DFF88")),
			},
			Topbar = { Height = 44, ButtonsType = "Mac" },
		})
	end)
	if KeyGate.resizeHandle then KeyGate.resizeHandle:Destroy() end -- the key window is gone
	if not okWin or type(Window) ~= "table" then
		warn("[PonyPairs] WindUI CreateWindow failed: " .. tostring(Window))
		return nil
	end
	if not alive then
		pcall(function() Window:Destroy() end)
		return nil
	end
	unlocked = true
	task.spawn(KeyGate.logRun)
	task.spawn(function()
		while alive do
			KeyGate.recheck()
			if KeyGate.secondsLeft() <= 0 then
				unlocked = false -- stops every automation loop at once
				pcall(function() if isfile(KeyGate.RECORD_PATH) then delfile(KeyGate.RECORD_PATH) end end)
				warn("[PonyPairs] access ended: key expired or replaced, or removed from the whitelist")
				pcall(function()
					lib:Notify({ Title = GUI_NAME, Content = "Access ended: the key changed or you were removed from the whitelist.", Duration = 20 })
				end)
				task.defer(function() api.Destroy() end)
				return
			end
			task.wait(1)
		end
	end)
	pcall(function()
		Window:Tag({ Title = EDITION, Color = EDITION_GREEN, Border = true })
	end)
	pcall(function()
		Window:Tag({ Title = GUI_VERSION, Color = Color3.fromHex("#1c1c1c"), Border = true })
	end)

	local sets = {}
	for id, set in pairs(CardData.Sets) do
		sets[#sets + 1] = { id = id, name = set.name or id, price = set.price or 0, order = set.order or 0 }
	end
	table.sort(sets, function(x, y) if x.order ~= y.order then return x.order < y.order end return x.id < y.id end)
	local setCardIds = {}
	for cardId, card in pairs(CardData.ById) do
		local list = setCardIds[card.set]
		if not list then list = {} setCardIds[card.set] = list end
		list[#list + 1] = cardId
	end
	local function ownedUnique(setId)
		local list = setCardIds[setId]
		if not list then return 0, 0 end
		local have = 0
		for _, cardId in ipairs(list) do
			local ok, n = pcall(Store.count, cardId)
			if ok and type(n) == "number" and n > 0 then have += 1 end
		end
		return have, #list
	end

	-- sidebar groups
	local overviewGroup = Window:Section({ Title = "Overview", Opened = true })
	local automationGroup = Window:Section({ Title = "Automation", Opened = true })
	local systemGroup = Window:Section({ Title = "System", Opened = true })

	-- About
	local aboutTab = overviewGroup:Tab({ Title = "About", Icon = "info", IconColor = Color3.fromHex("#257AF7"), IconShape = "Square" })
	aboutTab:Section({ Title = GUI_NAME .. " " .. GUI_VERSION .. " | " .. EDITION .. " (free version)" })
	-- a Paragraph thumbnail: the library's Tab:Image never parented its frame in the loaded build
	local okImage, imageError = pcall(function()
		aboutTab:Paragraph({ Title = "My Little Pony Card Opening", Desc = "by Pony Card Club", Thumbnail = GAME_THUMBNAIL, ThumbnailSize = 170 })
	end)
	if not okImage then
		warn("[PonyPairs] thumbnail not added: " .. tostring(imageError))
	end
	aboutTab:Space()
	aboutTab:Paragraph({ Title = "For My Little Pony Card Opening", Desc = "Solves the Pony Pairs memory board and sticker postcards, and opens card packs." })
	aboutTab:Space()
	aboutTab:Paragraph({ Title = "Tabs", Desc = "Profile: your player and game stats.\nStatus: what is happening now and the counters.\nPuzzle: memory board and sticker solvers.\nPacks: pack opening, buying and selling dupes.\nConfig: saved settings.\nDiscord: community and key link.\nOthers: script controls." })

	-- Profile (read-only)
	local profileTab = overviewGroup:Tab({ Title = "Profile", Icon = "user", IconColor = Color3.fromHex("#7775F2"), IconShape = "Square" })
	profileTab:Section({ Title = "Player" })
	local playerNow = profileTab:Paragraph({ Title = lp.DisplayName, Desc = "@" .. lp.Name,
		Image = "rbxthumb://type=AvatarHeadShot&id=" .. lp.UserId .. "&w=150&h=150", ImageSize = 64 })
	local userStatus = profileTab:Paragraph({ Title = "User status", Desc = "..." })
	profileTab:Space()
	profileTab:Section({ Title = "In this game" })
	local collectionNow = profileTab:Paragraph({ Title = "Wallet and collection", Desc = "..." })
	local gameTotals = profileTab:Paragraph({ Title = "Game's saved totals", Desc = "..." })
	local profileSince = os.clock()
	local function readNumber(fn, ...)
		local ok, value = pcall(fn, ...)
		return (ok and type(value) == "number") and tostring(value) or "?"
	end
	local function refreshProfile()
		local premium = lp.MembershipType == Enum.MembershipType.Premium and "Yes" or "No"
		playerNow:SetDesc(string.format("@%s\nUser ID %d\nAccount age %d days | Roblox Premium: %s", lp.Name, lp.UserId, lp.AccountAge, premium))
		local running = {}
		if Config.Enabled then running[#running + 1] = "Puzzle solver" end
		if Config.StickerEnabled then running[#running + 1] = "Sticker solver" end
		if Config.PackAuto then running[#running + 1] = "Pack opening" end
		local up = math.floor(os.clock() - profileSince)
		userStatus:SetDesc(string.format("Edition: %s %s\nKey expires in %s\nGame screen: %s\nAutomation on: %s\nMenu loaded for %02d:%02d:%02d",
			EDITION, GUI_VERSION, keyTimeText(), tostring(gameApp and gameApp.mode or "?"),
			#running > 0 and table.concat(running, ", ") or "none",
			up // 3600, up % 3600 // 60, up % 60))
		local unique, total, copies = 0, 0, 0
		for cardId in pairs(CardData.ById) do
			total += 1
			local ok, n = pcall(Store.count, cardId)
			if ok and type(n) == "number" and n > 0 then
				unique += 1
				copies += n
			end
		end
		collectionNow:SetDesc(string.format("Coins %s\nDifferent cards %d/%d\nCard copies owned %d", readNumber(Store.money), unique, total, copies))
		local saved = type(Store.profile) == "table" and Store.profile.stats
		if type(saved) == "table" then
			gameTotals:SetDesc(string.format("Packs opened %s\nPairs %s\nTrades %s\nCoins earned %s",
				tostring(saved.opened or "?"), tostring(saved.pairs or "?"), tostring(saved.trades or "?"), tostring(saved.earned or "?")))
		else
			gameTotals:SetDesc("not available")
		end
	end
	local profileError
	task.spawn(function()
		while alive do
			local ok, err = pcall(refreshProfile)
			if not ok and tostring(err) ~= profileError then
				profileError = tostring(err)
				warn("[PonyPairs] profile refresh failed: " .. profileError)
			end
			task.wait(1)
		end
	end)

	-- Status
	local statusTab = overviewGroup:Tab({ Title = "Status", Icon = "activity", IconColor = Color3.fromHex("#10C550"), IconShape = "Square" })
	statusTab:Section({ Title = "Key and device" })
	local accessNow = statusTab:Paragraph({ Title = "Access", Desc = "..." })
	statusTab:Paragraph({ Title = "Times script run", Desc = KeyGate.runs
		and string.format("This account %d\nAll accounts on this device %d", KeyGate.runs.account, KeyGate.runs.device)
		or "not available" })
	statusTab:Space()
	statusTab:Section({ Title = "Right now" })
	local solverNow = statusTab:Paragraph({ Title = "Puzzle solver", Desc = "..." })
	local packNow = statusTab:Paragraph({ Title = "Pack opening", Desc = "..." })
	local stickerNow = statusTab:Paragraph({ Title = "Sticker solver", Desc = "..." })
	local walletNow = statusTab:Paragraph({ Title = "Wallet and selected pack", Desc = "..." })
	statusTab:Space()
	statusTab:Section({ Title = "Coin rate" })
	local coinNow = statusTab:Paragraph({ Title = "Average since start (per sec / min / hr)", Desc = "measuring..." })
	local coinRecent = statusTab:Paragraph({ Title = "Last 60 seconds", Desc = "measuring..." })
	local coinTotals = statusTab:Paragraph({ Title = "Estimated total at your average", Desc = "measuring..." })
	statusTab:Button({ Title = "Reset coin rate", Callback = resetCoinMeter })
	statusTab:Space()
	statusTab:Section({ Title = "Stats since this load" })
	local puzzleStats = statusTab:Paragraph({ Title = "Puzzle", Desc = "..." })
	local packStats = statusTab:Paragraph({ Title = "Packs", Desc = "..." })
	local lastPull = statusTab:Paragraph({ Title = "Last pack pulled", Desc = "..." })

	-- Puzzle
	local WARNING_RED = Color3.fromHex("#EF4F1D")
	local puzzleTab = automationGroup:Tab({ Title = "Puzzle", Icon = "puzzle", IconColor = WARNING_RED, IconShape = "Square" })
	puzzleTab:Paragraph({ Title = "Use Human for safer play", Desc = "Human is a slower, paced mode. It is not guaranteed undetectable: any mode, and pack automation, can still get your account banned. Use at your own risk.", Color = WARNING_RED })
	puzzleTab:Paragraph({ Title = "\"Too fast\" warning", Desc = "If the auto puzzle or auto sticker solver says \"a little too fast\", or anything about being too fast, on your first try, it means your account is already banned from getting coins.", Color = WARNING_RED })
	puzzleTab:Space()
	puzzleTab:Section({ Title = "Solver" })
	puzzleTab:Toggle({ Title = "Solver", Value = Config.Enabled, Callback = function(s) Config.Enabled = s end })
	local modeChoices = {
		{ Title = "Human" },
		{ Title = "Blatant", Locked = true },
		{ Title = "Instant", Locked = true },
		{ Title = "Turbo", Locked = true },
	}
	puzzleTab:Dropdown({ Title = "Speed", Desc = "Blatant, Instant and Turbo are locked", Values = modeChoices, Value = modeChoices[1], Callback = function(v)
		local name = type(v) == "table" and v.Title or v
		if name == "Human" then Config.Mode = name end
	end })
	puzzleTab:Toggle({ Title = "Auto-open board", Value = Config.AutoOpen, Callback = function(s) Config.AutoOpen = s end })
	puzzleTab:Toggle({ Title = "Adaptive slow", Desc = "Locked off", Locked = true, Value = false, Callback = function(s) Config.AdaptiveSlow = s end })
	puzzleTab:Toggle({ Title = "Slow-cap probe (experimental)", Desc = "Locked off", Locked = true, Value = false, Callback = function(s) Config.SlowCapProbe = s end })
	puzzleTab:Space()
	puzzleTab:Section({ Title = "Sticker postcards" })
	local stickerToggle = puzzleTab:Toggle({ Title = "Auto-solve stickers", Desc = "Fixed Human-style pace. Same ban risk as above.", Value = Config.StickerEnabled, Callback = function(s)
		Config.StickerEnabled = s
		if s then stats.unpaidStreak = 0 end
	end })
	local perfectValues, perfectByLabel, perfectLabel = {}, {}, nil
	for n = 0, 5 do
		local text = string.format("%d perfect, %d nice", n, 5 - n)
		perfectValues[#perfectValues + 1] = text
		perfectByLabel[text] = n
		if n == Config.StickerPerfectCount then perfectLabel = text end
	end
	if not perfectLabel then
		Config.StickerPerfectCount = 3
		perfectLabel = perfectValues[4]
	end
	puzzleTab:Dropdown({ Title = "Sticker results (5-sticker card)", Desc = "Perfect drops go first, then nice. A 4-sticker card has one fewer nice.", Values = perfectValues, Value = perfectLabel, Callback = function(v)
		local n = perfectByLabel[v]
		if n then Config.StickerPerfectCount = n end
	end })
	puzzleTab:Toggle({ Title = "Auto-open sticker desk", Desc = "While this is on, pack opening has to wait for the main desk.", Value = Config.StickerAutoOpen, Callback = function(s) Config.StickerAutoOpen = s end })
	puzzleTab:Slider({ Title = "Delay before each sticker (seconds)", Step = 0.1,
		Value = { Min = 0.3, Max = 3, Default = math.clamp(Config.StickerPickDelay, 0.3, 3) },
		Callback = function(v) Config.StickerPickDelay = math.clamp(tonumber(v) or Config.StickerPickDelay, 0.3, 3) end })
	puzzleTab:Slider({ Title = "Sticker drag time (seconds)", Step = 0.1,
		Value = { Min = 0.3, Max = 3, Default = math.clamp(Config.StickerDragTime, 0.3, 3) },
		Callback = function(v) Config.StickerDragTime = math.clamp(tonumber(v) or Config.StickerDragTime, 0.3, 3) end })

	-- Packs
	local packsTab = automationGroup:Tab({ Title = "Packs", Icon = "package", IconColor = Color3.fromHex("#ECA201"), IconShape = "Square" })
	packsTab:Section({ Title = "Pack opening" })
	local packToggle = packsTab:Toggle({ Title = "Auto-open packs", Value = Config.PackAuto, Callback = function(s)
		if s ~= Config.PackAuto then packRun = nil end
		Config.PackAuto = s
	end })
	local values, labelToId, selectedLabel = {}, {}, nil
	for _, s in ipairs(sets) do
		local text = string.format("%s (%s) %dc", s.name, s.id, s.price)
		values[#values + 1] = text
		labelToId[text] = s.id
		if s.id == Config.PackSet then selectedLabel = text end
	end
	packsTab:Dropdown({ Title = "Pack", Values = values, Value = selectedLabel or values[1], Callback = function(v)
		local id = labelToId[v]
		if id then Config.PackSet = id end
	end })
	local AMOUNT_OFF = "Off (open continuously)"
	local amountValues, amountByLabel, amountLabel = { AMOUNT_OFF }, { [AMOUNT_OFF] = 0 }, AMOUNT_OFF
	for _, n in ipairs({ 1, 3, 5, 10, 20, 30, 50, 100 }) do
		local text = n == 1 and "1 pack" or (n .. " packs")
		amountValues[#amountValues + 1] = text
		amountByLabel[text] = n
		if n == Config.PackBuyAmount then amountLabel = text end
	end
	if amountLabel == AMOUNT_OFF then Config.PackBuyAmount = 0 end
	packsTab:Dropdown({ Title = "Packs to buy before opening", Desc = "Choose this, then turn on Auto-open packs. Spends coins.", Values = amountValues, Value = amountLabel, Callback = function(v)
		local n = amountByLabel[v]
		if not n or n == Config.PackBuyAmount then return end
		-- changing the quantity never starts a purchase: auto-open has to be switched on again
		Config.PackBuyAmount = n
		Config.PackAuto = false
		packRun = nil
	end })
	local orderNow = packsTab:Paragraph({ Title = "Order", Desc = "..." })
	packsTab:Toggle({ Title = "Buy when out", Desc = "Spends coins. Only used when the quantity is Off.", Value = Config.PackBuy, Callback = function(s) Config.PackBuy = s end })
	packsTab:Toggle({ Title = "Auto-sell dupes (on-screen mode)", Desc = "Uses the game's Sell dupes rules. Sales cannot be undone.", Value = Config.PackSellDupes, Callback = function(s) Config.PackSellDupes = s end })
	packsTab:Toggle({ Title = "Show opening on screen", Value = Config.PackVisible, Callback = function(s) Config.PackVisible = s end })
	local cardLabels = {}
	for _, v in ipairs({ 0.5, 0.9, 1.5, 2.5 }) do cardLabels[#cardLabels + 1] = tostring(v) .. "s" end
	packsTab:Dropdown({ Title = "Time per card", Values = cardLabels, Value = tostring(Config.PackCardView) .. "s", Callback = function(v)
		Config.PackCardView = tonumber((v:gsub("s$", ""))) or Config.PackCardView
	end })
	local SUMMARY_MIN, SUMMARY_MAX, SUMMARY_STEP = 0.1, 10, 0.1
	Config.PackSummaryView = math.clamp(tonumber(Config.PackSummaryView) or 2, SUMMARY_MIN, SUMMARY_MAX)
	packsTab:Slider({ Title = "Time on summary (seconds)", Step = SUMMARY_STEP,
		Value = { Min = SUMMARY_MIN, Max = SUMMARY_MAX, Default = Config.PackSummaryView },
		Callback = function(v)
			local seconds = tonumber(v)
			if seconds then Config.PackSummaryView = math.clamp(seconds, SUMMARY_MIN, SUMMARY_MAX) end
		end })

	-- Others
	do
		packsTab:Space()
		packsTab:Section({ Title = "Collection duplicates" })
		local sellToggle = packsTab:Toggle({ Title = "Auto-sell collection dupes", Desc = "Sells from your whole collection. Check the preview first. Sales cannot be undone.", Value = Config.CollectionSell, Callback = function(s) Config.CollectionSell = s end })
		local preview = packsTab:Paragraph({ Title = "Preview and result", Desc = "..." })
		local shown = Config.CollectionSell
		task.spawn(function()
			while alive do
				if shown ~= Config.CollectionSell then
					shown = Config.CollectionSell
					pcall(function() sellToggle:Set(shown, false) end)
				end
				local ok, text = pcall(function()
					local plan, reason = collectionPlan()
					if not plan then return reason end
					return string.format("Would sell now: %d cards, about %d coins\nKeeps %d of each (more if placed) | sells %s\nSkips favorites, secrets and gold-record cards\nSold this load: %d cards, %d coins\n%s",
						plan.count, plan.value, plan.keep, plan.ruleText, stats.collectionSold, stats.collectionCoins,
						(Config.CollectionSell and "ON: " or "OFF. Last: ") .. (stats.collectionNote or "nothing sold yet"))
				end)
				pcall(function() preview:SetDesc(ok and text or ("preview failed: " .. tostring(text):gsub("[<>&]", ""))) end)
				task.wait(2)
			end
		end)
	end

	local configTab = systemGroup:Tab({ Title = "Config", Icon = "save", IconColor = Color3.fromHex("#305DFF"), IconShape = "Square" })
	configTab:Section({ Title = "Config" })
	local configNow = configTab:Paragraph({ Title = "Saved settings", Desc = configState.note })
	configTab:Toggle({ Title = "Auto-save settings", Desc = "Saves your choices when they change. Automation on/off switches are not saved to the file.", Value = configState.autoSave, Callback = function(s)
		if s == configState.autoSave then return end
		configState.autoSave = s
		saveConfigFile()
	end })
	configTab:Button({ Title = "Save settings now", Callback = function() saveConfigFile() end })
	configTab:Button({ Title = "Reset saved settings", Desc = "Defaults apply the next time the script loads.", Callback = function()
		local ok, err = pcall(function()
			if isfile(CONFIG_PATH) then delfile(CONFIG_PATH) end
		end)
		if ok then
			configState.autoSave = false
			configState.lastSignature = configSignature()
			env.PonyPairsDiscardSettings = true
			configState.note = "reset: reload the script to get the defaults (auto-save paused until then)"
		else
			configState.note = "reset failed: " .. tostring(err)
		end
	end })
	task.spawn(function()
		-- the first pass records the starting values, writing the file if there is none yet
		if not isfile(CONFIG_PATH) then saveConfigFile() else configState.lastSignature = configSignature() end
		local shownNote
		while alive do
			if configState.autoSave and configSignature() ~= configState.lastSignature then
				saveConfigFile()
			end
			if shownNote ~= configState.note then
				shownNote = configState.note
				pcall(function() configNow:SetDesc(shownNote) end)
			end
			task.wait(1)
		end
	end)

	-- Others
	local discordTab = systemGroup:Tab({ Title = "Discord", Icon = "message-circle", IconColor = Color3.fromHex("#5865F2"), IconShape = "Square" })
	discordTab:Section({ Title = "Community and key" })
	discordTab:Paragraph({
		Title = DISCORD_NAME .. " Discord",
		Desc = "Get your key here\n" .. DISCORD_LINK,
		Image = discordPicture,
		ImageSize = 56,
		Buttons = { { Title = "Copy link", Icon = "copy", Callback = function()
			local ok = setclipboard ~= nil and pcall(setclipboard, DISCORD_LINK)
			pcall(function()
				lib:Notify({ Title = GUI_NAME, Content = ok and "Discord link copied" or ("Copy failed. Link: " .. DISCORD_LINK) })
			end)
		end } },
	})

	do -- live server counts from Discord's public invite lookup (approximate figures, no member names)
		local REFRESH_SECONDS, MANUAL_COOLDOWN = 60, 10
		discordTab:Space()
		discordTab:Section({ Title = "Live members" })
		local membersNow = discordTab:Paragraph({ Title = DISCORD_NAME .. " members", Desc = "loading..." })
		local counts, countsAt, problem
		local nextFetch, lastFetch, fetching = 0, -MANUAL_COOLDOWN, false

		local function refreshMembers()
			if fetching then return end
			fetching, lastFetch = true, os.clock()
			local wait = REFRESH_SECONDS
			local ok, err = pcall(function()
				local send = request or http_request or (syn and syn.request)
				local code = DISCORD_LINK:match("([%w%-]+)$")
				local response = send({ Url = "https://discord.com/api/v10/invites/" .. code .. "?with_counts=true", Method = "GET" })
				if response.StatusCode == 429 then
					wait = 300
					error("Discord asked to slow down, waiting 5 minutes", 0)
				elseif response.StatusCode == 404 then
					wait = 600
					error("invite not found or expired", 0)
				end
				assert(response.StatusCode == 200, "Discord returned " .. tostring(response.StatusCode))
				local data = game:GetService("HttpService"):JSONDecode(response.Body)
				local total, online = data.approximate_member_count, data.approximate_presence_count
				assert(type(total) == "number" and type(online) == "number", "no counts in Discord's reply")
				counts, countsAt = { total = total, online = online }, os.date("%H:%M:%S")
			end)
			problem = (not ok) and tostring(err) or nil
			nextFetch = os.clock() + wait
			fetching = false
		end

		local function showMembers()
			local lines = {}
			if counts then
				lines[#lines + 1] = string.format('<font color="#4DFF88"><b>● Online %d</b></font>', counts.online)
				lines[#lines + 1] = string.format("Members %d", counts.total)
				lines[#lines + 1] = "Updated " .. countsAt .. " (Discord's approximate counts)"
			else
				lines[#lines + 1] = problem and "Counts unavailable" or "loading..."
			end
			if problem then
				lines[#lines + 1] = (counts and "Old numbers, last refresh failed: " or "") .. problem:gsub("[<>&]", "")
			end
			lines[#lines + 1] = string.format("Next refresh in %ds", math.max(0, math.ceil(nextFetch - os.clock())))
			membersNow:SetDesc(table.concat(lines, "\n"))
		end

		discordTab:Button({ Title = "Refresh now", Callback = function()
			-- a 429 or dead invite keeps its longer wait
			if os.clock() - lastFetch >= MANUAL_COOLDOWN and not (problem and nextFetch - os.clock() > REFRESH_SECONDS) then
				nextFetch = 0
			end
		end })

		task.spawn(function()
			while alive do
				if os.clock() >= nextFetch and not fetching then
					task.spawn(refreshMembers)
				end
				pcall(showMembers)
				task.wait(1)
			end
		end)
	end

	local othersTab = systemGroup:Tab({ Title = "Others", Icon = "settings", IconColor = Color3.fromHex("#83889E"), IconShape = "Square" })
	othersTab:Section({ Title = "Script" })
	othersTab:Button({ Title = "Close / Unload", Callback = function() task.defer(function() api.Destroy() end) end })

	local function statusDot(on)
		-- glowDot: RichText only, a translucent outline in the same colour makes the halo
		local color, halo, word = "#FF4D4D", "#FF0000", "OFF"
		if on then
			color, halo, word = "#4DFF88", "#00FF55", "ON"
		end
		return string.format('<stroke color="%s" thickness="2.5" transparency="0.55" joins="round"><font color="%s"><b>● %s</b></font></stroke>', halo, color, word)
	end

	local function refresh()
		local st = api.Status()
		local session = KeyGate.session
		if session and session.checkedAt then
			accessNow:SetDesc(string.format("Account registered %s\nAccounts used on this device %s\nKey expires in %s\nDevice list checked %d min ago",
				statusDot(session.registered), session.used and (session.used .. "/3") or "unknown", keyTimeText(),
				(os.time() - session.checkedAt) // 60))
		else
			accessNow:SetDesc("Key expires in " .. keyTimeText())
		end
		solverNow:SetDesc(string.format("%s | mode %s | board %s | known %d/12", statusDot(st.enabled), Config.Mode, st.boardActive and "open" or "closed", st.knownCards))
		packNow:SetDesc(string.format("%s | %s\nSell dupes %s | Buy when out %s",
			statusDot(Config.PackAuto),
			Config.PackAuto and (stats.packNote or "working") or (stats.packNote or "idle"),
			statusDot(Config.PackSellDupes), statusDot(Config.PackBuy)))
		stickerNow:SetDesc(string.format("%s | %s\nStickers %d | Postcards %d | Coins earned %d",
			statusDot(Config.StickerEnabled), (stats.stickerNote or "idle") .. (stats.postcardReply and ("\nLast refusal: " .. stats.postcardReply) or ""), stats.stickersPlaced, stats.postcards, stats.postcardCoins))
		local sel = CardData.Sets[Config.PackSet]
		local okCount, n = pcall(Store.packCount, Config.PackSet)
		local okMoney, money = pcall(Store.money)
		local have, total = ownedUnique(Config.PackSet)
		local rate = coinReport()
		local total = math.floor(rate.seconds)
		coinNow:SetDesc(string.format("Earned: %.2f /sec | %.1f /min | %.0f /hr\nAfter spending: %.2f /sec | %.1f /min | %.0f /hr\nEarned %d | Spent %d | Net %d | Time %02d:%02d:%02d%s",
			rate.perSecond, rate.perMinute, rate.perHour,
			rate.netPerSecond, rate.netPerMinute, rate.netPerHour,
			rate.earned, rate.spent, rate.net, total // 3600, total % 3600 // 60, total % 60,
			rate.seconds < 300 and "\nUnder 5 minutes of data: rates can swing a lot" or ""))
		local function commas(value)
			local sign = value < 0 and "-" or ""
			local digits = string.format("%.0f", math.abs(value))
			digits = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
			return sign .. digits
		end
		if rate.recentSeconds >= RECENT_WINDOW - 2 then
			local perSecond = rate.recentEarned / rate.recentSeconds
			coinRecent:SetDesc(string.format("Earned: %.2f /sec | %.1f /min | %.0f /hr\n%s coins in the last %.0f seconds",
				perSecond, perSecond * 60, perSecond * 3600, commas(rate.recentEarned), rate.recentSeconds))
		else
			coinRecent:SetDesc(string.format("measuring... %.0f/%d seconds", rate.recentSeconds, RECENT_WINDOW))
		end
		if rate.seconds >= 60 then
			local rows = {}
			for _, span in ipairs({ { "10 minutes", 600 }, { "1 hour", 3600 }, { "6 hours", 21600 }, { "12 hours", 43200 }, { "24 hours", 86400 } }) do
				table.insert(rows, string.format("%s: %s earned | %s after spending", span[1], commas(rate.perSecond * span[2]), commas(rate.netPerSecond * span[2])))
			end
			table.insert(rows, "Estimates only: assumes the same average without stopping")
			coinTotals:SetDesc(table.concat(rows, "\n"))
		else
			coinTotals:SetDesc(string.format("measuring... %.0f/60 seconds", rate.seconds))
		end
		walletNow:SetDesc(string.format("Coins %s\n%s: %s packs owned, price %d\nCards collected %d/%d",
			okMoney and tostring(money) or "?", sel and sel.name or "none", okCount and tostring(n) or "?", sel and sel.price or 0, have, total))
		puzzleStats:SetDesc(string.format("Boards %d | Flips %d | Pairs %d | Misses %d\nSlow %d | Failures %d | Your clicks %d",
			stats.finishedRounds, stats.flips, stats.pairs, stats.misses, stats.slow, stats.failures, stats.userClicks))
		local slowCapText = "off"
		if Config.SlowCapProbe then
			if slowCap.probing then
				slowCapText = string.format("paused, %.0fs left", math.max(0, slowCap.pauseUntil - os.clock()))
			else
				slowCapText = "watching (" .. (slowCap.lastResult or "no result yet") .. ")"
			end
		end
		puzzleStats:SetTitle("Puzzle | slow-cap probe " .. slowCapText)
		packStats:SetDesc(string.format("Opened %d | Bought %d | Spent %d\nCards %d | New %d | Sold %d | Throttled %d",
			stats.packsOpened, stats.packsBought, stats.coinsSpent, stats.cardsPulled, stats.newCards, stats.dupesSold, stats.rateLimited))
		lastPull:SetDesc(stats.lastPull or "nothing yet")
		local amount = Config.PackBuyAmount
		if amount > 0 then
			local price = sel and sel.price or 0
			local cost = price * amount
			local text = string.format("%d x %d = %d coins | you have %s", amount, price, cost, okMoney and tostring(money) or "?")
			if packRun then
				text = string.format("Bought %d/%d | Opened %d", packRun.bought, packRun.amount, packRun.opened)
			elseif okMoney and money < cost then
				text = text .. "\nNot enough coins: nothing will be bought"
			end
			orderNow:SetDesc(text)
		else
			orderNow:SetDesc("No quantity chosen: opens continuously")
		end
	end

	pcall(function() aboutTab:Select() end)
	local stickerShown = Config.StickerEnabled
	local packShown = Config.PackAuto
	local refreshError
	task.spawn(function()
		while alive and Window do
			if stickerShown ~= Config.StickerEnabled then
				stickerShown = Config.StickerEnabled
				pcall(function() stickerToggle:Set(stickerShown, false) end)
			end
			if packShown ~= Config.PackAuto then
				packShown = Config.PackAuto
				pcall(function() packToggle:Set(packShown, false) end)
			end
			local ok, err = pcall(refresh)
			if not ok and tostring(err) ~= refreshError then
				refreshError = tostring(err)
				warn("[PonyPairs] GUI refresh failed: " .. refreshError)
			end
			task.wait(0.25)
		end
	end)

	return function()
		pcall(function() Window:Destroy() end)
	end
end

api = { Config = Config, Modes = Modes, CoinReport = coinReport, CollectionPlan = collectionPlan, SaveConfig = saveConfigFile }

function api.Enable()
	Config.Enabled = true
end

function api.SetMode(name)
	if name == "Human" then
		Config.Mode = name
	end
end

function api.SetPack(id)
	if CardData.Sets[id] then
		Config.PackSet = id
	end
end

function api.Disable()
	Config.Enabled = false
end

function api.Destroy()
	alive = false
	Config.Enabled = false
	clickConn:Disconnect()
	if destroyGui then pcall(destroyGui) destroyGui = nil end
	if Store.memory == wrapper then
		Store.memory = originalMemory
	end
	if env.PonyPairsSolver == api then
		env.PonyPairsSolver = nil
	end
end

function api.Status()
	local known = 0
	for _ in pairs(state.ids) do
		known += 1
	end
	return {
		enabled = Config.Enabled,
		boardActive = Memory.isActive(),
		finished = state.finished,
		knownCards = known,
		openFirst = state.openFirst,
		penalty = penalty,
		stats = table.clone(stats),
	}
end

env.PonyPairsSolver = api
task.spawn(function()
	while alive do
		sampleCoins()
		task.wait(0.1)
	end
end)
-- the key window waits for input, so the menu is built on its own thread
task.spawn(function()
	local cleanup = buildGui()
	if cleanup then destroyGui = cleanup end
end)
log("loaded - waiting for the Pony Pairs board")
