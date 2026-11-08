-- Live game context: keeps the bridge's picture of the game current while you
-- play, so a question asked outside the game (an agent reading the bridge's
-- state) knows where you are without a message having been sent from here.
--
-- An update is one record on the pixel strip for a couple of seconds. It starts
-- no agent run, uses no slot and nothing acknowledges it. To keep the strip off
-- the screen, only the lines that changed go; position, money and XP change all
-- the time, so they wait longer than the rest; and nothing goes while nothing
-- changes. A whole copy goes first and again a while after any update, so one the
-- capture missed (the game was covered, say) can't stay wrong for long.
--
-- Nothing is sent in combat, without the bridge, on the reload transport, or
-- with /ai context off, which is this feature's off switch.
--
-- The game hides some values in boss fights, Mythic+ and PvP ("secret values");
-- comparing one throws an error, so all of this runs under a pcall.

WoWAILive = {}
local M = WoWAILive

local CHECK_SECONDS = 5
local CHANGE_SECONDS = 15 -- at most one update this often
local VOLATILE_SECONDS = 60 -- how often a change to a VOLATILE line alone is worth one
local FULL_SECONDS = 300 -- a whole copy this long after the first update it would repair
local VOLATILE = { Position = true, Money = true, XP = true }

local sent = {} -- label -> line, as the bridge has it; empty means send a whole copy
local firstDiffAt -- when the oldest update since the last whole copy went out
local lastChangeAt, lastVolatileAt = -1e9, -1e9

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
local function Guard(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok and not M.lastError then M.lastError = tostring(err) end
end

-- A context's lines by label, which is everything before the first colon.
local function ByLabel(ctx)
	local out = {}
	for line in ctx:gmatch("[^\n]+") do
		out[line:match("^([^:]+):") or line] = line
	end
	return out
end

-- One line for /wow-ai diag: when an update last went, and what is holding the next.
function M.Diag()
	local age = M.sentAt and (math.floor(GetTime() - M.sentAt) .. " s ago") or "never"
	return "live updates: last sent " .. age
		.. ", blocked by: " .. (M.blocked or "nothing")
		.. ", error: " .. (M.lastError or "none")
end

local function SendWhole(ctx, lines, now)
	WoWAI.ShowLive("h;L", ctx)
	M.sentAt = now
	sent, firstDiffAt = lines, nil
	lastChangeAt, lastVolatileAt = now, now
end

-- Send the lines that differ from what the bridge has, if it is time to.
-- A line that went away is sent as its bare label.
local function SendChanges(lines, now)
	local firm, volatile = false, false
	for label, line in pairs(lines) do
		if sent[label] ~= line then
			if VOLATILE[label] then volatile = true else firm = true end
		end
	end
	for label in pairs(sent) do
		if not lines[label] then firm = true end
	end
	local due = (firm and now - lastChangeAt >= CHANGE_SECONDS) or (volatile and now - lastVolatileAt >= VOLATILE_SECONDS)
	if not due then return end
	local out = {}
	for label, line in pairs(lines) do
		if sent[label] ~= line then
			table.insert(out, line)
			sent[label] = line
		end
	end
	for label in pairs(sent) do
		if not lines[label] then
			table.insert(out, label .. ":")
			sent[label] = nil
		end
	end
	table.sort(out)
	WoWAI.ShowLive("h;l", table.concat(out, "\n"))
	M.sentAt = now
	lastChangeAt = now
	if volatile then lastVolatileAt = now end
	firstDiffAt = firstDiffAt or now
end

local function Tick()
	local s = WoWAIDB and WoWAIDB.settings
	if not (s and s.context and s.mode == "pixel" and WoWAI.IsConnected()) then
		M.blocked = (s and s.context and s.mode == "pixel") and "bridge not connected" or "context off or not pixel mode"
		-- Whatever happens from here on the bridge won't see; start over with a whole copy.
		sent, firstDiffAt = {}, nil
		return
	end
	if Try(UnitAffectingCombat, "player") or Try(InCombatLockdown) then
		M.blocked = "combat"
		return
	end
	local now = GetTime()
	local ctx = WoWAI.GameContext()
	if ctx == "" then
		M.blocked = "empty context"
		return
	end
	M.blocked = nil
	local lines = ByLabel(ctx)
	if not next(sent) or (firstDiffAt and now - firstDiffAt >= FULL_SECONDS) then
		SendWhole(ctx, lines, now)
	else
		SendChanges(lines, now)
	end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function()
	C_Timer.NewTicker(CHECK_SECONDS, function() Guard(Tick) end)
end)
