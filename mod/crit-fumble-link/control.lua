-- crit-fumble-link — the platform's service-admin channel into a hosted
-- Factorio server, the factorio analogue of cfg-foundry-plugin's service GM.
--
-- Factorio mods run fully sandboxed: no network, no filesystem reads. So
-- unlike the Foundry plugin, this mod cannot phone home — everything is
-- PULLED by core-server over RCON (container-internal, docker network only):
--
--   /silent-command rcon.print(remote.call("cfg", "status"))
--
-- One call, one JSON line back. Keep it that way: RCON responses must stay
-- single-line, and this mod must stay control-stage only (no data.lua, no
-- prototypes) so that installing or removing it never changes game state and
-- never invalidates a save.
--
-- ⚠️ Version bumps are not free: Factorio requires every connecting client to
-- run the same mod set as the server, so each release forces a "Sync mods
-- with server" on every player. Keep this mod boring and stable.

local function player_row(p)
  return {
    name = p.name,
    connected = p.connected,
    admin = p.admin,
    online_ticks = p.online_time,
    afk_ticks = p.connected and p.afk_time or nil,
  }
end

local iface = {}

-- One-call snapshot for the platform dashboard, roster linking, and the
-- activity probe. Reports facts only — metering, never pricing (billing
-- lives in core, owner rule 2026-08-08).
function iface.status()
  local players = {}
  local online = 0
  for _, p in pairs(game.players) do
    players[#players + 1] = player_row(p)
    if p.connected then online = online + 1 end
  end
  return helpers.table_to_json({
    link_version = script.active_mods["crit-fumble-link"],
    factorio_version = script.active_mods.base,
    tick = game.tick,
    speed = game.speed,
    paused = game.tick_paused,
    online = online,
    players = players,
    mods = script.active_mods,
  })
end

-- Platform → in-game announcement (owner message from the dashboard,
-- shutdown warnings, etc.), visually distinct from player chat.
function iface.announce(message)
  game.print("[CFG] " .. tostring(message), { color = { r = 1, g = 0.62, b = 0.24 } })
  return helpers.table_to_json({ ok = true })
end

remote.add_interface("cfg", iface)
