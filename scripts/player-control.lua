-- Exercise the engine rather than just reading the prototype values. Run the
-- same scenario with baseline best quality and with the mod's normal quality.
local function arena(name)
  local surface = game.create_surface(name, {seed = 42, autoplace_settings = {
    entity = {treat_missing_as_default = false}, decorative = {treat_missing_as_default = false},
  }})
  surface.request_to_generate_chunks({0, 0}, 2)
  surface.force_generate_chunk_requests()
  local tiles = {}
  for x = -48, 48 do for y = -32, 32 do
    tiles[#tiles + 1] = {name = "grass-1", position = {x, y}}
  end end
  surface.set_tiles(tiles)
  return surface
end

script.on_init(function()
  local quality = prototypes.quality.normal
  if not script.active_mods["no-quality-no-problem"] then
    for _, candidate in pairs(prototypes.quality) do
      if candidate.level > quality.level then quality = candidate end
    end
  end
  storage.results = {version = script.active_mods.base, complete = false, quality = quality.name,
    poles = {}, inserters = {}, mining = {}, combat = {}}
  storage.poles, storage.drills, storage.targets, storage.shooters = {}, {}, {}, {}

  for name, prototype in pairs(prototypes.entity) do
    if prototype.type == "electric-pole" then
      local surface = arena("power-" .. name)
      local pole = assert(surface.create_entity{name = name, position = {0, 0}, force = "player", quality = quality})
      local source = assert(surface.create_entity{name = "electric-energy-interface", position = {0, 1}, force = "player"})
      source.power_production, source.electric_buffer_size, source.energy = 1e9, 1e9, 1e9
      local lamps = {}
      -- Place consumers both inside and outside every pole's supply radius.
      for distance = 1, 24 do
        lamps[distance] = assert(surface.create_entity{name = "small-lamp", position = {distance, 0}, force = "player"})
      end
      storage.poles[name] = {source = source, lamps = lamps}
      storage.results.poles[name] = {health = pole.max_health,
        radius = prototype.get_supply_area_distance(quality), wire = prototype.get_max_wire_distance(quality)}
    elseif prototype.type == "inserter" then
      storage.results.inserters[name] = {
        rotation = prototype.get_inserter_rotation_speed(quality),
        extension = prototype.get_inserter_extension_speed(quality),
      }
    elseif prototype.type == "mining-drill" then
      local surface = arena("mining-" .. name)
      local oil = name == "pumpjack"
      local resource = assert(surface.create_entity{name = oil and "crude-oil" or "iron-ore", position = {0, 0}, amount = 100000})
      local drill = assert(surface.create_entity{name = name, position = {0, 0}, force = "player", quality = quality})
      local chest
      if not oil then chest = assert(surface.create_entity{name = "steel-chest", position = drill.drop_position, force = "player"}) end
      if drill.burner then drill.get_fuel_inventory().insert{name = "coal", count = 50} end
      storage.drills[name] = {entity = drill, resource = resource, chest = chest}
    end
  end

  local surface = arena("research")
  local force = game.create_force("research")
  local lab = assert(surface.create_entity{name = "lab", position = {0, 0}, force = force, quality = quality})
  lab.get_inventory(defines.inventory.lab_input).insert{name = "automation-science-pack", quality = quality, count = 10}
  for _, prerequisite in pairs(force.technologies.automation.prerequisites) do prerequisite.researched = true end
  assert(force.add_research("automation"))
  storage.lab, storage.research_force = lab, force

  -- The fixture exposes unmodified capsule attacks as gun/ammo pairs because a
  -- headless server cannot use a connected player's cursor. This exercises the
  -- original projectile -> robot/cloud/explosion chain, including inherited quality.
  for _, name in ipairs{"defender-capsule", "distractor-capsule", "destroyer-capsule",
    "grenade", "cluster-grenade", "poison-capsule", "slowdown-capsule"} do
    local combat_surface = arena("capsule-" .. name)
    local shooter = assert(combat_surface.create_entity{name = "character", position = {0, 0}, force = "player"})
    shooter.destructible = false
    local target = assert(combat_surface.create_entity{name = "character", position = {8, 0}, force = "enemy"})
    target.character_health_bonus = 1000000
    storage.targets[target.unit_number] = name
    storage.results.combat[name] = {hits = 0, damage = {}, robots = {}}
    shooter.get_inventory(defines.inventory.character_guns)[1].set_stack{name = "nqnp-test-gun-" .. name, quality = quality}
    shooter.get_inventory(defines.inventory.character_ammo)[1].set_stack{name = "nqnp-test-" .. name, quality = quality, count = 1}
    shooter.selected_gun_index = 1
    shooter.shooting_state = {state = defines.shooting.shooting_enemies, position = target.position}
    storage.shooters[name] = {entity = shooter, target = target}
  end
end)

script.on_event(defines.events.on_entity_damaged, function(event)
  local name = storage.targets[event.entity.unit_number]
  if not name then return end
  local result = storage.results.combat[name]
  result.hits = result.hits + 1
  if #result.damage < 16 then
    result.damage[#result.damage + 1] = {amount = event.original_damage_amount,
      type = event.damage_type.name, cause = event.cause and event.cause.name or "none"}
  end
  event.entity.health = event.entity.max_health
end)

script.on_event(defines.events.on_tick, function(event)
  storage.lab.energy = 1e9
  for _, test in pairs(storage.poles) do test.source.energy = 1e9 end
  for _, test in pairs(storage.drills) do
    test.entity.energy = 1e9
    -- Force many mining completions to measure resource drain, not RNG luck
    -- from a couple of ordinary mining cycles. Do this identically in both runs.
    test.entity.mining_progress = .999999
    if not test.chest then test.entity.clear_fluid_inside() end
  end
  if event.tick == 120 then
    for name, test in pairs(storage.shooters) do
      local result = storage.results.combat[name]
      for _, robot in pairs(test.entity.surface.find_entities_filtered{type = "combat-robot"}) do
        result.robots[#result.robots + 1] = {name = robot.name, health = robot.max_health}
      end
      table.sort(result.robots, function(a, b) return a.name < b.name end)
      result.stickers = {}
      for _, sticker in pairs(test.target.stickers or {}) do
        result.stickers[sticker.name] = sticker.time_to_live
      end
    end
  end
  if event.tick ~= 1800 then return end
  for name, test in pairs(storage.poles) do
    local lamps = {}
    for _, lamp in ipairs(test.lamps) do
      lamps[#lamps + 1] = {powered = lamp.is_connected_to_electric_network(), energy = lamp.energy}
    end
    storage.results.poles[name].lamps = lamps
  end
  for name, test in pairs(storage.drills) do
    storage.results.mining[name] = {remaining = test.resource.amount,
      products = test.chest and test.chest.get_item_count("iron-ore") or nil}
  end
  storage.results.research = {progress = storage.research_force.research_progress,
    researched = storage.research_force.technologies.automation.researched,
    packs = storage.lab.get_inventory(defines.inventory.lab_input).get_item_count()}
  storage.results.complete = true
  helpers.write_file("player.json", helpers.table_to_json(storage.results))
end)
