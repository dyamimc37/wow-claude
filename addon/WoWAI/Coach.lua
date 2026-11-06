-- Watch and coach: Claude speaks up without being asked when something happens
-- in the game. Events collect here and go to a chat of their own, in batches.
--
-- A coach message costs a slot, and it starts a run nobody asked for, so it holds
-- back: it waits for events to settle, then for a cooldown, and never sends in
-- combat, without the bridge, on the reload transport (it would reload the UI) or
-- when the slot pool runs low.
--
-- Only the addon's own words and game data go into a coach message. Other
-- players' names and chat text never do: a loot line is used only when it is the
-- player's own, and only its item link is taken from it; a death names the target
-- only when it is an NPC.
--
-- The game hides some values in boss fights, Mythic+ and PvP ("secret values");
-- comparing one throws an error, so every read of the game goes through Try or a
-- pcall, and a read that fails just leaves that detail out.

WoWAICoach = {}
local M = WoWAICoach

local TICK_SECONDS = 2
local DEBOUNCE_SECONDS = 8 -- wait this long after the last event, so one moment makes one message
local DEFAULT_COOLDOWN = 180 -- seconds between coach messages
local MIN_COOLDOWN, MAX_COOLDOWN = 30, 3600
local QUEUE_MAX = 8 -- lines in one message; the oldest go first
local EVENT_MAX_AGE = 600 -- seconds; older events are stale advice
local MIN_FREE_SLOTS = 20 -- leave these for the player's own chats
local MAX_LINKS = 2 -- item links per message; each adds a tooltip to the strip
local ITEM_RETRIES = 15 -- ticks to wait for the client to fetch a new item's data
local CHAT_NAME = "Coach"

local queue = {}
local items = {} -- looted items waiting to be compared with what is worn
local quests = {} -- questID -> { title, complete }; a quest only counts as newly ready once seen incomplete
local questsDirty = true
local lastEventAt = -1e9
local lastSentAt = -1e9

local function Say(text)
	print("|cff66ccff[WoW AI]|r " .. text)
end

local function Secret(v)
	return type(issecretvalue) == "function" and issecretvalue(v)
end

-- One value from a game API, or nil if it's missing, throws, or is a secret.
local function Try(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, v = pcall(fn, ...)
	if ok and not Secret(v) then return v end
	return nil
end

-- Run a handler so a mistake here can never put an error on the player's screen.
-- /wow-ai coach shows the first one.
local function Guard(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok and not M.lastError then M.lastError = tostring(err) end
end

local function Settings()
	WoWAIDB.coach = WoWAIDB.coach or {}
	local s = WoWAIDB.coach
	if s.enabled == nil then s.enabled = true end
	s.cooldown = s.cooldown or DEFAULT_COOLDOWN
	return s
end

---------------------------------------------------------------------------
-- The queue
---------------------------------------------------------------------------

local function Add(key, text)
	lastEventAt = GetTime()
	for _, e in ipairs(queue) do
		if e.key == key then
			e.text, e.at = text, lastEventAt
			return
		end
	end
	table.insert(queue, { key = key, text = text, at = lastEventAt })
	while #queue > QUEUE_MAX do table.remove(queue, 1) end
end

local function Remove(key)
	for i, e in ipairs(queue) do
		if e.key == key then
			table.remove(queue, i)
			return
		end
	end
end

local function ExpireOld(now)
	for i = #queue, 1, -1 do
		if now - queue[i].at > EVENT_MAX_AGE then table.remove(queue, i) end
	end
end

---------------------------------------------------------------------------
-- Quests
---------------------------------------------------------------------------

local function ScanQuests()
	questsDirty = false
	if not C_QuestLog then return end
	local n = Try(C_QuestLog.GetNumQuestLogEntries)
	if type(n) ~= "number" then return end
	for i = 1, n do
		local info = Try(C_QuestLog.GetInfo, i)
		if type(info) == "table" and not info.isHeader and type(info.questID) == "number" and info.questID > 0 then
			local id = info.questID
			local complete = Try(C_QuestLog.IsComplete, id) and true or false
			local known = quests[id]
			if known and not known.complete and complete then
				Add("ready:" .. id, "Quest ready to turn in: " .. tostring(info.title or known.title or id))
			end
			quests[id] = { title = info.title or (known and known.title), complete = complete }
		end
	end
end

local function OnQuestTurnedIn(id, xp)
	if Secret(id) or type(id) ~= "number" then return end
	local title = (quests[id] and quests[id].title) or (C_QuestLog and Try(C_QuestLog.GetTitleForQuestID, id)) or ("quest " .. id)
	quests[id] = nil
	Remove("ready:" .. id)
	local gained = (not Secret(xp) and type(xp) == "number" and xp > 0) and (" (+" .. xp .. " XP)") or ""
	Add("turnin:" .. id, "Quest turned in: " .. tostring(title) .. gained)
end

---------------------------------------------------------------------------
-- Level and death
---------------------------------------------------------------------------

local function OnLevelUp(level)
	if Secret(level) or type(level) ~= "number" then return end
	Add("level", "Reached level " .. level)
end

-- True only when the target is known not to be a player or a player's pet. Any
-- doubt, a secret value included, means no.
local function TargetIsNpc()
	if not Try(UnitExists, "target") then return false end
	local ok, isPlayer = pcall(UnitIsPlayer, "target")
	if not ok or Secret(isPlayer) or isPlayer then return false end
	local ok2, controlled = pcall(UnitPlayerControlled, "target")
	if not ok2 or Secret(controlled) or controlled then return false end
	return true
end

local function OnDeath()
	local zone, sub = Try(GetZoneText), Try(GetSubZoneText)
	local text = "Died"
	if type(zone) == "string" and zone ~= "" then
		text = text .. " in " .. zone
		if type(sub) == "string" and sub ~= "" and sub ~= zone then text = text .. " - " .. sub end
	end
	if TargetIsNpc() then
		local name, level = Try(UnitName, "target"), Try(UnitLevel, "target")
		if type(name) == "string" and name ~= "" then
			text = text .. "; target at the time: " .. name .. (type(level) == "number" and level > 0 and (" (level " .. level .. ")") or "")
		end
	end
	Add("death", text)
end

---------------------------------------------------------------------------
-- Gear upgrades
---------------------------------------------------------------------------

-- Inventory slots an item could go in. Shirts and tabards are left out on purpose.
local SLOTS = {
	INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 },
	INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 }, INVTYPE_WAIST = { 6 },
	INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 },
	INVTYPE_HAND = { 10 }, INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 },
	INVTYPE_CLOAK = { 15 }, INVTYPE_WEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 },
	INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_SHIELD = { 17 },
	INVTYPE_HOLDABLE = { 17 }, INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 },
	INVTYPE_THROWN = { 18 }, INVTYPE_RELIC = { 18 },
}

local function ItemLevel(link, fallback)
	local detailed = C_Item and Try(C_Item.GetDetailedItemLevelInfo, link)
	return type(detailed) == "number" and detailed or fallback
end

-- The line about this item, nil when it is no upgrade, or false when the client
-- has not fetched its data yet.
local function UpgradeLine(item)
	local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	if type(getInfo) ~= "function" then return nil end
	local ok, name, _, _, level, minLevel, _, _, _, equipLoc = pcall(getInfo, item.payload)
	if not ok or Secret(name) then return nil end
	if not name then return false end
	local slots = SLOTS[equipLoc]
	if not slots then return nil end
	if C_Item and C_Item.IsEquippableItem and Try(C_Item.IsEquippableItem, item.payload) == false then return nil end
	local me = Try(UnitLevel, "player")
	if type(minLevel) == "number" and type(me) == "number" and minLevel > me then return nil end
	level = ItemLevel(item.payload, level)
	if type(level) ~= "number" then return false end
	local lowest, lowestName
	for _, slot in ipairs(slots) do
		local worn = Try(GetInventoryItemLink, "player", slot)
		if type(worn) ~= "string" then
			lowest, lowestName = nil, nil
			break
		end
		local _, _, _, _, wornInfoLevel = pcall(getInfo, worn)
		local wornLevel = ItemLevel(worn, wornInfoLevel)
		if type(wornLevel) ~= "number" then return false end
		if not lowest or wornLevel < lowest then
			lowest, lowestName = wornLevel, worn:match("%[([^%]]*)%]")
		end
	end
	local link = "|H" .. item.payload .. "|h[" .. item.name .. "]|h"
	if not lowest then
		return "Looted " .. link .. ", item level " .. level .. ", for an empty slot"
	end
	if level <= lowest then return nil end
	return "Looted " .. link .. ", item level " .. level .. ", over the worn [" .. tostring(lowestName) .. "], item level " .. lowest
end

local function CheckItems()
	for i = #items, 1, -1 do
		local item = items[i]
		local line = UpgradeLine(item)
		if line == false then
			item.tries = item.tries + 1
			if item.tries >= ITEM_RETRIES then table.remove(items, i) end
		else
			table.remove(items, i)
			if line then Add("item:" .. item.payload, line) end
		end
	end
end

local function FormatPrefix(fmt)
	local prefix = type(fmt) == "string" and fmt:match("^(.-)%%") or ""
	return prefix
end

-- Is this loot line the player's own? The sender's GUID says so when the line has
-- one; other players' loot carries theirs. Without one, the wording of the game's
-- own "You receive" formats decides.
local function IsOwnLoot(text, guid)
	if type(guid) == "string" and guid ~= "" then
		return guid == Try(UnitGUID, "player")
	end
	local formats = {
		LOOT_ITEM_SELF or "You receive loot: %s.",
		LOOT_ITEM_SELF_MULTIPLE or "You receive loot: %sx%d.",
		LOOT_ITEM_PUSHED_SELF or "You receive item: %s.",
		LOOT_ITEM_PUSHED_SELF_MULTIPLE or "You receive item: %sx%d.",
	}
	for _, fmt in ipairs(formats) do
		local prefix = FormatPrefix(fmt)
		if prefix ~= "" and text:sub(1, #prefix) == prefix then return true end
	end
	return false
end

local function OnLoot(text, ...)
	if type(text) ~= "string" or Secret(text) then return end
	local guid = select(11, ...)
	if Secret(guid) or not IsOwnLoot(text, guid) then return end
	local payload, name = text:match("|H(item:[^|]+)|h%[([^%]]*)%]|h")
	if payload then table.insert(items, { payload = payload, name = name, tries = 0 }) end
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

local function FindChat()
	for _, c in ipairs(WoWAIDB.chats) do
		-- By name too: a chat the bridge restored comes back without the flag.
		if c.coach or c.name == CHAT_NAME then
			c.coach = true
			return c
		end
	end
end

local function EnsureChat()
	local c = FindChat()
	if c then return c end
	c = WoWAI.AddChat(CHAT_NAME, "")
	if c then
		c.coach = true
		c.agent, c.model, c.effort = "", "", ""
		WoWAI.Render()
	end
	return c
end

-- Can a coach message go out now? Returns the chat, or nil and why not.
local function ReadyToSend()
	if WoWAIDB.settings.mode ~= "pixel" then return nil, "the addon is on the reload transport (/ai mode pixel)" end
	if not WoWAI.IsConnected() then return nil, "not connected to the bridge" end
	if Try(UnitAffectingCombat, "player") or Try(InCombatLockdown) then return nil, "in combat" end
	if WoWAI.SlotsLeft() < MIN_FREE_SLOTS then return nil, "few reply slots left (/ai reload frees them)" end
	local c = EnsureChat()
	if not c then return nil, "no room for a Coach chat (delete one)" end
	if c.pendingId then return nil, "still waiting on its last reply" end
	return c
end

local function Message()
	local lines, links = { "[Game events]" }, 0
	for _, e in ipairs(queue) do
		local text = e.text
		if text:find("|H", 1, true) then
			links = links + 1
			if links > MAX_LINKS then text = text:gsub("|H[^|]+|h(%[[^%]]*%])|h", "%1") end
		end
		table.insert(lines, "- " .. text)
	end
	return table.concat(lines, "\n")
end

local function Tick()
	if not WoWAIDB or not WoWAIDB.settings or not WoWAIDB.chats then return end
	local s = Settings()
	if not s.enabled then return end
	if questsDirty then ScanQuests() end
	if #items > 0 then CheckItems() end
	local now = GetTime()
	ExpireOld(now)
	if #queue == 0 or now - lastEventAt < DEBOUNCE_SECONDS or now - lastSentAt < s.cooldown then return end
	local c = ReadyToSend()
	if not c then return end
	local text = Message()
	wipe(queue)
	lastSentAt = now
	WoWAI.Send(text, nil, c)
end

---------------------------------------------------------------------------
-- /wow-ai coach
---------------------------------------------------------------------------

function M.Command(rest)
	local s = Settings()
	rest = (rest or ""):lower()
	local seconds = rest:match("^cooldown%s+(%d+)$")
	if rest == "on" or rest == "off" then
		s.enabled = rest == "on"
		if not s.enabled then
			wipe(queue)
			wipe(items)
		end
		Say("coach " .. rest)
	elseif seconds then
		s.cooldown = math.max(MIN_COOLDOWN, math.min(MAX_COOLDOWN, tonumber(seconds)))
		Say("coach cooldown: " .. s.cooldown .. " seconds")
	elseif rest == "test" then
		local c, why = ReadyToSend()
		if not c then
			Say("coach can't send right now: " .. why)
			return
		end
		lastSentAt = GetTime()
		WoWAI.Send("Coach test: give me one quick tip for my level and zone.", nil, c)
		Say("coach test sent; the answer shows here and in the Coach chat")
	else
		local parts = {
			"coach is " .. (s.enabled and "on" or "off"),
			"cooldown " .. s.cooldown .. " s",
			#queue .. " event(s) waiting",
		}
		local _, why = ReadyToSend()
		if why then table.insert(parts, "holding: " .. why) end
		Say(table.concat(parts, ", ") .. ". /ai coach on|off|test, /ai coach cooldown <seconds>. To change its model or effort, switch to the Coach chat and use /ai model or /ai effort.")
		if M.lastError then Say("coach error: " .. M.lastError) end
	end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local HANDLERS = {
	QUEST_TURNED_IN = OnQuestTurnedIn,
	PLAYER_LEVEL_UP = OnLevelUp,
	PLAYER_DEAD = OnDeath,
	CHAT_MSG_LOOT = OnLoot,
	QUEST_LOG_UPDATE = function() questsDirty = true end,
}

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
for event in pairs(HANDLERS) do
	pcall(frame.RegisterEvent, frame, event) -- an event this client doesn't have must not stop the addon
end
frame:SetScript("OnEvent", function(_, event, ...)
	if event == "PLAYER_LOGIN" then
		C_Timer.NewTicker(TICK_SECONDS, function() Guard(Tick) end)
		local s = Settings()
		if not s.noted then
			s.noted = true
			Say("the coach is on: Claude will speak up after quests, deaths, level-ups and gear upgrades, in a chat called Coach. /ai coach off stops it.")
		end
		return
	end
	if WoWAIDB and Settings().enabled then Guard(HANDLERS[event], ...) end
end)
