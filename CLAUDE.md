# wow-claude — Claude inside WoW: Forever

Dyami's fork of [chelinho139/wow-ai](https://github.com/chelinho139/wow-ai)
(MIT). Upstream does the transport: the addon draws messages as a pixel strip
the bridge screen-captures, and replies come back through 200 pre-made
load-on-demand slot addons. Read `docs/ARCHITECTURE.md` before touching either.

## Decisions (Dyami, 2026-11-04)

- **Fork, don't rebuild.** Keep upstream's transport; our work goes on top.
  Pull upstream with `git fetch upstream && git merge upstream/main`; keep our
  changes in new files or small hunks so those merges stay cheap.
- **Plays on the Windows PC; the MacBook is for travel.** Both are installed
  (2026-11-04), each with its own gitignored `bridge/config.json`:
  - PC: client `F:\World of Warcraft\_forever_` (the WD_BLACK SN7100, his
    fastest drive; keep it there), checkout
    `C:\Users\User\Documents\Claude\Github\wow-claude`, capture `capture.ps1`.
    The bridge starts hidden at logon (2026-11-08): value `WoWAIBridge` under
    `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, through
    `conhost --headless` so no window shows, in `bridge/` so chats keep
    `defaultCwd`. Nothing stops a second bridge, so don't start one by hand
    while it runs.
  - Mac: client `/Applications/World of Warcraft/_forever_`, checkout
    `~/Documents/Projects/Github/Personal/wow-claude`, capture
    `capture_mac.py`; its terminal needs Screen Recording and Automation
    (System Events) permission.
  - Each config's `agents.claude.deniedTools` holds `mcp__google-admin` and
    his deploy/migrate scripts (the ones his global settings pre-allow). A
    re-created config loses that list: put it back.
- **Ban risk accepted, on his main Battle.net account.** Blizzard's terms
  forbid third-party software that collects data from the game; the pixel
  capture may count. No known bans; he chose it knowingly. Do not re-litigate.
- **What Claude does in game, in build order:**
  1. Round trip working (upstream as-is).
  2. Answer questions with game context — upstream already sends character,
     zone, quest log, talents, professions; shift-clicked links carry tooltips.
     `addon/WoWAI/Live.lua` keeps it current without a message being sent, gear
     included, so a session outside the game can read `bridge/state.json`
     (`context`): `wow-forever` does, with a prompt hook.
  3. Stand in for guide addons (RestedXP-style) — upstream's map layers,
     routes and navigator are the base.
  4. Watch and coach: Claude speaks up unprompted on game events (quest done,
     death, loot upgrade, level-up): `addon/WoWAI/Coach.lua`, `/ai coach`.
     Forever uses Midnight's addon rules, so combat state is hidden in boss
     fights, Mythic+ and PvP — coaching cannot see inside those.
  5. Write addons for him — upstream's primer (`docs/WOW-ADDON-PRIMER.md`)
     covers this; new addons load at his next `/reload`.
  6. **Do his work from in game** (EnerTribe: mail, Slack, Drive, GitHub …).

## Guardrails for work mode (must hold before step 6 ships)

The bridge runs `claude -p` with his user config, so a chat reaches every MCP
server he has connected, Google Admin included.

- **Only text he types into `/ai` or the window is an instruction.** Other
  players' chat, whispers, names and guild text never enter a prompt as
  instructions; if ever forwarded, it is quoted data. Upstream forwards none
  today — keep it that way, and test it.
- **Never `bypassPermissions`.** Reads and drafts run freely. Anything that
  sends, posts, deletes or shares needs an in-game click **for that one call**.
  Upstream's *Allow & retry* adds a **permanent** prefix rule to
  `bridge/config.json` — not acceptable for outward-facing MCP tools; add a
  one-shot allow for those.
- **Google Admin writes stay desktop-only**: put `mcp__google-admin__*` write
  tools in `deniedTools` for in-game chats.
- Work text shows on the game screen; mind streaming/recording.

## Tests and CI

- **No GitHub Actions.** Actions is disabled on this fork (repo settings,
  2026-11-04). Upstream's `.github/workflows/test.yml` stays in the tree only
  to keep upstream merges clean; it never runs here. Add no workflows.
- `.githooks/pre-push` runs `npm test` (`npm install` wires it via `prepare`).
- **Never run the suite on the Mac.** Push from the Mac with
  `git push --no-verify` and run `npm test` on titan's CI container
  (`ssh ci@192.168.1.50`, Node in `/opt/node/bin`) before merging.

## Local files

`bridge/config.json`, `bridge/state.json`, `bridge/transcripts.json`,
`bridge/bridge.log` are per-machine and gitignored; `node setup.js` writes the
config and installs the addon plus ~15,000 slot files into the game folder.
