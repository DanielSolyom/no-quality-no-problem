-- Run unchanged with the mod disabled/enabled; compare the engine's results.
local movement = require("movement")

local function snapshot()
  helpers.write_file("exclusions.json", helpers.table_to_json(storage.results))
end

local function arena(name)
  local surface = game.create_surface(name, {
    seed = 42,
    autoplace_settings = {
      entity = {treat_missing_as_default = false},
      decorative = {treat_missing_as_default = false},
    },
  })
  surface.request_to_generate_chunks({0, 0}, 2)
  surface.force_generate_chunk_requests()
  local tiles = {}
  for x = -64, 63 do
    for y = -64, 63 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
  end
  surface.set_tiles(tiles)
  return surface
end

script.on_init(function()
  storage.results = {
    health = {}, inventories = {}, attractors = {}, stickers = {}, combat = {}, healing = {},
    smoke_lifetimes = {}, fire_lifetimes = {},
  }
  storage.targets = {}
  storage.healers = {}
  storage.fires = {}
  local results = storage.results
  local best = prototypes.quality.normal
  for _, quality in pairs(prototypes.quality) do
    if quality.level > best.level then best = quality end
  end
  local s = game.surfaces[1]
  for name, p in pairs(prototypes.entity) do
    local health = p.get_max_health("normal")
    if health > 0 then
      results.health[name] = {type = p.type, normal = health, best = p.get_max_health(best)}
    end
    -- Check actual instances of every asteroid, not only prototype lookups.
    if p.type == "asteroid" then
      local entity = assert(s.create_entity{name = name, position = {0, 0}, force = "enemy"})
      results.health[name].instance = entity.max_health
      entity.destroy()
    end
    if p.type == "container" then
      results.inventories[name] = {
        normal = p.get_inventory_size(defines.inventory.chest, "normal"),
        best = p.get_inventory_size(defines.inventory.chest, best),
      }
    elseif p.type == "lightning-attractor" then
      results.attractors[name] = {
        range = p.get_attraction_range_elongation(),
        efficiency = p.get_energy_distribution_efficiency(),
      }
    elseif p.type == "sticker" then
      results.stickers[name] = {normal = p.get_duration(), best = p.get_duration(best)}
    elseif p.type == "smoke-with-trigger" then
      local entity = assert(s.create_entity{
        name = name, position = {0, 0}, force = "enemy", quality = name == "poison-cloud" and best or "normal",
      })
      results.smoke_lifetimes[name] = entity.time_to_live
      entity.destroy()
    end
  end

  -- Each attacker gets its own surface, avoiding crossfire and spawned wrigglers
  -- disturbing other cases. Restore target health after each hit.
  local attackers = {}
  for name, prototype in pairs(prototypes.entity) do
    if name ~= "dummy-spider-unit" and (prototype.type == "unit" or prototype.type == "spider-unit"
      or prototype.type == "segmented-unit" or prototype.type == "turret") then
      attackers[#attackers + 1] = name
    end
  end
  table.sort(attackers)
  for _, name in ipairs(attackers) do
    local surface = arena(name)
    local target = assert(surface.create_entity{name = "character", position = {8, 0}, force = "player"})
    target.character_health_bonus = 1000000
    local attacker = assert(surface.create_entity{name = name, position = {0, 0}, force = "enemy"})
    storage.targets[target.unit_number] = name
    results.combat[name] = {samples = {}}
    if attacker.commandable then
      attacker.commandable.set_command{type = defines.command.attack, target = target, distraction = defines.distraction.none}
    elseif attacker.type == "segmented-unit" then
      -- Provoke its revenge attack in addition to normal territorial behaviour.
      attacker.damage(1, "player", "physical", target, target)
    end
  end

  -- Drive each asteroid into an identical chest. Use best quality in the
  -- baseline too: collision damage is capped by the target's actual health.
  for name, prototype in pairs(prototypes.entity) do
    if prototype.type == "asteroid" then
      -- Asteroids collide with structures on space platforms, not ground maps.
      local platform = assert(game.forces.player.create_space_platform{
        name = "impact-" .. name, planet = "nauvis", starter_pack = {name = "space-platform-starter-pack", quality = best},
      })
      platform.apply_starter_pack()
      local surface = platform.surface
      surface.request_to_generate_chunks({48, 0}, 1)
      surface.force_generate_chunk_requests()
      surface.set_tiles{{name = "space-platform-foundation", position = {48, 0}}}
      local target = assert(surface.create_entity{name = "steel-chest", position = {48.5, 0.5}, force = "player", quality = best})
      storage.targets[target.unit_number] = "impact-" .. name
      results.combat["impact-" .. name] = {samples = {}}
      local asteroid = assert(surface.create_entity{name = name, position = {32.5, 0.5}, force = "enemy"})
      asteroid.set_movement({1, 0}, 0.2)
    end
  end

  -- A worm must hit just inside normal range and never hit outside it. This
  -- catches fixing damage while accidentally retaining legendary attack range.
  for _, distance in ipairs({24, 28}) do
    local name = "worm-range-" .. distance
    local surface = arena(name)
    local target = assert(surface.create_entity{name = "character", position = {distance, 0}, force = "player"})
    assert(surface.create_entity{name = "small-worm-turret", position = {0, 0}, force = "enemy"})
    storage.targets[target.unit_number] = name
    results.combat[name] = {samples = {}}
  end

  for _, name in ipairs({
    "fire-flame", "lightning", "acid-cloud", "poison-cloud",
    "crash-site-fire-smoke", "crash-site-fire-flame",
    "small-demolisher-ash-cloud", "small-demolisher-ash-cloud-trail",
    "small-demolisher-expanding-ash-cloud-1", "medium-demolisher-ash-cloud", "big-demolisher-ash-cloud",
  }) do
    local surface = arena(name)
    local is_ash = name:find("ash-cloud", 1, true)
    local player_weapon = name == "poison-cloud"
    local target = assert(surface.create_entity{
      name = is_ash and "construction-robot" or "character", position = {0, 0},
      force = player_weapon and "enemy" or "player",
    })
    storage.targets[target.unit_number] = name
    results.combat[name] = {samples = {}}
    assert(surface.create_entity{
      name = name, position = target.position, target = target,
      force = player_weapon and "player" or "enemy", quality = player_weapon and best or "normal",
    })
  end

  for _, name in ipairs({"behemoth-biter", "small-strafer-pentapod", "small-demolisher"}) do
    local surface = arena("healing-" .. name)
    local entity = assert(surface.create_entity{name = name, position = {0, 0}, force = "enemy"})
    if entity.type == "segmented-unit" then entity = entity.segmented_unit end
    entity.health = entity.max_health / 2
    storage.healers[name] = {entity = entity, initial = entity.health}
  end

  local fire_names = {}
  for name, prototype in pairs(prototypes.entity) do
    if prototype.type == "fire" and (name:find("acid-splash", 1, true)
      or name == "fire-flame" or name == "crash-site-fire-flame") then
      fire_names[#fire_names + 1] = name
    end
  end
  table.sort(fire_names)
  local surface = arena("fire-lifetimes")
  for index, name in ipairs(fire_names) do
    storage.fires[name] = assert(surface.create_entity{
      name = name, position = {-40 + (index % 5) * 20, -40 + math.floor(index / 5) * 20}, force = "enemy",
    })
  end
  movement.init(best)
  snapshot()
end)

script.on_event(defines.events.on_entity_damaged, function(event)
  local name = storage.targets[event.entity.unit_number]
  if not name then return end
  local samples = storage.results.combat[name].samples
  if #samples < 16 then
    samples[#samples + 1] = {
      damage = event.final_damage_amount,
      type = event.damage_type.name,
      cause = event.cause and event.cause.valid and event.cause.name or "none",
    }
  end
  event.entity.health = event.entity.max_health
end)

script.on_event(defines.events.on_tick, function(event)
  movement.tick(event.tick)
  for name, fire in pairs(storage.fires) do
    if not fire.valid and not storage.results.fire_lifetimes[name] then
      storage.results.fire_lifetimes[name] = event.tick
    end
  end
  if event.tick == 1 then
    for name, item in pairs(storage.healers) do
      assert(item.entity.valid, "healing subject disappeared: " .. name)
      storage.results.healing[name] = item.entity.health - item.initial
    end
  end
  if event.tick == 2400 then snapshot() end
end)
