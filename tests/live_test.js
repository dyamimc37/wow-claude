// The live game context (addon/WoWAI/Live.lua), end to end: the real addon Lua
// in a Lua VM read back off the pixel strip, and the updates parsed and merged by
// the bridge's protocol code.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const fengari = require('fengari');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = fengari;
const P = require('../bridge/protocol');

const ADDON = path.join(__dirname, '..', 'addon', 'WoWAI');
const CELLS_PER_ROW = 200;

// What the shared stub lacks: gear, combat and secret values.
const LIVE_STUB = `
STUB.worn = {}        -- slot -> item link
STUB.itemLevel = {}   -- item link -> item level
STUB.inCombat = false
STUB.secrets = {}     -- values issecretvalue reports as secret
C_Item.GetDetailedItemLevelInfo = function(link) return STUB.itemLevel[link] end
function GetInventoryItemLink(unit, slot) return STUB.worn[slot] end
function UnitAffectingCombat(unit) return STUB.inCombat end
function issecretvalue(v) return STUB.secrets[v] == true end
`;

function newVM() {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  const run = (code, arg) => {
    if (lauxlib.luaL_loadstring(L, to_luastring(code)) !== lua.LUA_OK) throw new Error('Lua load: ' + to_jsstring(lua.lua_tostring(L, -1)));
    let nargs = 0;
    if (arg !== undefined) { lua.lua_pushstring(L, to_luastring(arg)); nargs = 1; }
    if (lua.lua_pcall(L, nargs, 0, 0) !== lua.LUA_OK) throw new Error('Lua error: ' + to_jsstring(lua.lua_tostring(L, -1)));
  };
  const evaluate = (expr) => {
    run(`local v = (${expr}); if v == nil then RESULT = nil else RESULT = tostring(v) end`);
    lua.lua_getglobal(L, to_luastring('RESULT'));
    const isNil = lua.lua_isnil(L, -1);
    const s = isNil ? null : to_jsstring(lua.lua_tolstring(L, -1));
    lua.lua_pop(L, 1);
    return s;
  };
  run(fs.readFileSync(path.join(__dirname, 'wow_stub.lua'), 'utf8'));
  run(LIVE_STUB);
  for (const f of ['Codec.lua', 'Inbox.lua', 'WoWAI.lua', 'Live.lua']) run(fs.readFileSync(path.join(ADDON, f), 'utf8'), 'WoWAI');
  return { run, evaluate };
}

function stripText(vm) {
  if (vm.evaluate('WoWAIStrip and WoWAIStrip.shown') !== 'true') return '';
  vm.run(`
    local parts = {}
    for _, t in ipairs(WoWAIStrip.textures) do
      if t.shown and t.color then
        local c, r = math.floor(t.x / 4), math.floor(-t.y / 4)
        local v = (t.color[1] >= 0.5 and 4 or 0) + (t.color[2] >= 0.5 and 2 or 0) + (t.color[3] >= 0.5 and 1 or 0)
        parts[#parts + 1] = (r * ${CELLS_PER_ROW} + c) .. ":" .. v
      end
    end
    RESULT = table.concat(parts, ",")`);
  const cells = [];
  for (const p of vm.evaluate('RESULT').split(',')) { const [i, v] = p.split(':').map(Number); cells[i] = v; }
  const bytes = [];
  let acc = 0, nbits = 0;
  for (let i = 0; i < cells.length; i++) {
    acc = (acc << 3) | (cells[i] || 0); nbits += 3;
    while (nbits >= 8) { bytes.push((acc >> (nbits - 8)) & 0xff); nbits -= 8; acc &= (1 << nbits) - 1; }
  }
  const len = bytes[4] * 256 + bytes[5];
  return Buffer.from(bytes.slice(6, 6 + len)).toString('utf8');
}

function records(vm) {
  const text = stripText(vm);
  return text ? P.jobsFromStrip(0, text) : [];
}
const liveNow = (vm) => records(vm).filter(r => r.live);

// Move time on as a real ticker would, and return every live update that went up.
function play(vm, seconds) {
  const seen = new Map();
  for (let t = 0; t < seconds; t += 2) {
    vm.run(`
      STUB.now = STUB.now + 2
      STUB.onLoadAddOn = function() WoWAI_SlotData = { now = time(), cwd = "", replies = {} } end
      STUB.Tick()`);
    for (const r of liveNow(vm)) seen.set(r.id, r);
  }
  return [...seen.values()];
}

// Log in, connect, and return the updates of the first 20 seconds.
function login(vm) {
  vm.run('STUB.FireEvent("ADDON_LOADED", "WoWAI"); STUB.FireEvent("PLAYER_LOGIN")');
  vm.run('STUB.RunTimers()');
  vm.run('STUB.onLoadAddOn = function() WoWAI_SlotData = { now = time(), cwd = "", replies = {} } end');
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.evaluate('WoWAI.IsConnected()'), 'true', 'connected after the hello slot');
  const seen = new Map(liveNow(vm).map(r => [r.id, r]));
  for (const r of play(vm, 20)) seen.set(r.id, r);
  return [...seen.values()];
}

test('the first update is a whole copy, then nothing while nothing changes', () => {
  const vm = newVM();
  const first = login(vm);
  assert.equal(first.length, 1);
  assert.equal(first[0].live, 'L');
  assert.equal(first[0].text, '', 'an update carries no message');
  assert.equal(first[0].ctx, vm.evaluate('WoWAI.GameContext()'));
  assert.deepEqual(play(vm, 700), []);
  assert.deepEqual(liveNow(vm), []);
});

test('only the line that changed goes, and each update has its own id', () => {
  const vm = newVM();
  const first = login(vm);
  vm.run('STUB.subzone = "Raven Hill"');
  const a = play(vm, 20);
  assert.equal(a.length, 1);
  assert.equal(a[0].live, 'l');
  assert.equal(a[0].ctx, `Location: ${vm.evaluate('STUB.zone')} - Raven Hill`);
  vm.run('STUB.level = 17');
  const b = play(vm, 20);
  assert.equal(b.length, 1);
  assert.match(b[0].ctx, /^Character: .*level 17/);
  assert.equal(new Set([first[0].id, a[0].id, b[0].id]).size, 3);
});

test('updates merged by the bridge rebuild what the game says', () => {
  const vm = newVM();
  let ctx = login(vm)[0].ctx;
  for (const change of ['STUB.zone = "Teldrassil"', 'STUB.level = 20', 'STUB.money = 123456']) {
    vm.run(change);
    for (const u of play(vm, 80)) ctx = P.mergeContext(ctx, u.ctx);
    assert.equal(ctx, vm.evaluate('WoWAI.GameContext()'));
  }
});

test('position, money and XP wait, unless something else is going anyway', () => {
  const vm = newVM();
  login(vm);
  vm.run('STUB.money = 999');
  assert.deepEqual(play(vm, 30), [], 'held back under a minute after the last one');
  const held = play(vm, 20);
  assert.equal(held.length, 1);
  assert.match(held[0].ctx, /^Money: /);

  vm.run('STUB.posX = 0.1'); // volatile alone: held
  assert.deepEqual(play(vm, 16), []);
  vm.run('STUB.zone = "Ashenvale"; STUB.subzone = ""'); // goes, and takes the position with it
  const both = play(vm, 6);
  assert.equal(both.length, 1);
  assert.deepEqual(both[0].ctx.split('\n').map(l => l.split(':')[0]), ['Location', 'Position']);
});

test('a whole copy follows a while after an update, once, to repair a missed one', () => {
  const vm = newVM();
  login(vm);
  vm.run('STUB.zone = "Darkshore"');
  assert.equal(play(vm, 20)[0].live, 'l');
  const later = play(vm, 320);
  assert.deepEqual(later.map(u => u.live), ['L']);
  assert.deepEqual(play(vm, 400), [], 'no change, so no more copies');
});

test('nothing goes in combat; the change goes after it', () => {
  const vm = newVM();
  login(vm);
  vm.run('STUB.inCombat = true; STUB.zone = "Darkshore"');
  assert.deepEqual(play(vm, 40), []);
  vm.run('STUB.inCombat = false');
  const after = play(vm, 10);
  assert.equal(after.length, 1);
  assert.equal(after[0].live, 'l');
  assert.match(after[0].ctx, /^Location: Darkshore/);
});

test('/ai context off stops it, and turning it back on sends a whole copy', () => {
  const vm = newVM();
  login(vm);
  vm.run('WoWAIDB.settings.context = false; STUB.zone = "Darkshore"');
  assert.deepEqual(play(vm, 40), []);
  vm.run('WoWAIDB.settings.context = true');
  const after = play(vm, 10);
  assert.equal(after.length, 1);
  assert.equal(after[0].live, 'L');
});

test('an error reading the game stays out of sight and clears up by itself', () => {
  const vm = newVM();
  login(vm);
  vm.run('REAL = WoWAI.GameContext; WoWAI.GameContext = function() error("attempt to compare a secret value") end; STUB.zone = "Darkshore"');
  assert.deepEqual(play(vm, 20), []);
  assert.match(vm.evaluate('WoWAILive.lastError'), /secret/);
  vm.run('WoWAI.GameContext = REAL');
  assert.equal(play(vm, 10).length, 1);
});

test('a secret combat flag counts as not knowing, and does not throw', () => {
  const vm = newVM();
  login(vm);
  vm.run('STUB.secrets[true] = true; STUB.inCombat = true; STUB.zone = "Darkshore"');
  assert.equal(play(vm, 10).length, 1);
  assert.equal(vm.evaluate('WoWAILive.lastError'), null);
});

test('an update leaves the strip by itself', () => {
  const vm = newVM();
  login(vm);
  vm.run('WoWAI.ShowLive("h;l", "Location: Darkshore")');
  assert.equal(liveNow(vm).length, 1);
  play(vm, 6);
  assert.equal(stripText(vm), '');
});

test('the player\'s message comes first when the strip is short of room', () => {
  const vm = newVM();
  login(vm);
  vm.run(`WoWAI.Send(string.rep("a", 2700))`);
  vm.run(`WoWAI.ShowLive("h;l", "Location: " .. string.rep("b", 900))`);
  let recs = records(vm);
  assert.equal(recs.filter(r => r.live).length, 0, 'no room for the update');
  assert.equal(recs.filter(r => r.text.startsWith('aaa')).length, 1, 'the message stays whole');
  vm.run(`WoWAI.ShowLive("h;l", "Location: Darkshore")`);
  recs = records(vm);
  assert.equal(recs.filter(r => r.live).length, 1, 'a short update fits beside it');
  assert.equal(recs.filter(r => r.text.startsWith('aaa')).length, 1);
});

test('the gear line names what is worn and what is empty, without the shirt', () => {
  const vm = newVM();
  vm.run(`
    local cap, staff, shirt = "|cffffffff|Hitem:1::::|h[Cap]|h|r", "|cff0070dd|Hitem:2::::|h[Staff: of Power]|h|r", "|cffffffff|Hitem:3::::|h[Shirt]|h|r"
    STUB.worn = { [1] = cap, [4] = shirt, [16] = staff }
    STUB.itemLevel = { [cap] = 12 }`);
  const line = vm.evaluate('WoWAI.GameContext()').split('\n').find(l => l.startsWith('Gear:'));
  assert.equal(line, 'Gear: Head Cap (12), Main Hand Staff: of Power; Empty: Neck, Shoulder, Chest, Waist, Legs, Feet, Wrist, Hands, Ring 1, Ring 2, Trinket 1, Trinket 2, Back, Off Hand, Ranged');
});

test('a live record reads back with its flags and context', () => {
  const [job] = P.jobsFromStrip(0, ['abc', '', '7', '', 'h;l;c', '', 'Location: Darkshore', ''].join('\x1F'));
  assert.equal(job.live, 'l');
  assert.equal(job.hello, true, 'so an older bridge treats it as a hello, not a message to run');
  assert.equal(job.ctx, 'Location: Darkshore');
  assert.equal(job.text, '');
  assert.equal(P.parseFlags('h').live, undefined);
});

test('mergeContext replaces by label, appends new lines and drops bare labels', () => {
  const prev = 'Game: World of Warcraft: Forever\nLocation: Elwynn\nMoney: 1g; XP: 1/2\nPosition: 1, 2';
  assert.equal(P.mergeContext(prev, 'Location: Westfall: Sentinel Hill'), 'Game: World of Warcraft: Forever\nLocation: Westfall: Sentinel Hill\nMoney: 1g; XP: 1/2\nPosition: 1, 2');
  assert.equal(P.mergeContext(prev, 'Position:'), 'Game: World of Warcraft: Forever\nLocation: Elwynn\nMoney: 1g; XP: 1/2');
  assert.equal(P.mergeContext(prev, 'Talents: Fire 3'), prev + '\nTalents: Fire 3');
  assert.equal(P.mergeContext(prev, 'Missing:'), prev);
  assert.equal(P.mergeContext('', 'Location: Elwynn\n\nGame: x'), 'Location: Elwynn\nGame: x');
});

test('an error in the main tick is caught, and diag says what is holding updates', () => {
  const vm = newVM();
  login(vm);
  vm.run('local real = WoWAI.UpdateDot; WoWAI.UpdateDot = function() error("boom") end; STUB.Tick(); WoWAI.UpdateDot = real');
  vm.run('SlashCmdList.WOWAI("diag")');
  const last = 'WoWAIDB.chats[1].history[#WoWAIDB.chats[1].history].text';
  let text = vm.evaluate(last);
  assert.match(text, /main tick errors: 1, last: .*boom/);
  assert.match(text, /live updates: last sent \d+ s ago, blocked by: nothing, error: none/);
  vm.run('STUB.onLoadAddOn = nil; STUB.now = STUB.now + 3600; STUB.Tick(); SlashCmdList.WOWAI("diag")');
  text = vm.evaluate(last);
  assert.match(text, /blocked by: bridge not connected/);
});
