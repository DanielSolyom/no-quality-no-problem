-- LuaTechnology properties are writable even though the game global is read-only.
local module_names = {"quality-module", "quality-module-2", "quality-module-3", "nqnp-test-quality-module"}
local tech_names = {"quality-module", "quality-module-2", "quality-module-3"}

local function tier()
  return prototypes.mod_data["nqnp-test-module-consumer"].data.tier
end

local function needed(index)
  return tier() > 0 and (index <= tier() or index == 4)
end

local function check_prototypes()
  for i, name in ipairs(module_names) do
    assert(prototypes.item[name].type == "item", name .. " is still a module")
    assert(prototypes.item[name].hidden == not needed(i), name .. " visibility")
    assert(prototypes.recipe[name].hidden == not needed(i), name .. " recipe visibility")
  end
  for i = 1, 2 do
    local name = "nqnp-test-unused-" .. i
    assert(prototypes.item[name].hidden and prototypes.recipe[name].hidden,
      "recycling or an upgrade loop kept an unused module")
  end
  for _, quality in pairs(prototypes.quality) do assert(quality.hidden, "quality became visible") end
  for _, tech in pairs(prototypes.technology) do
    for _, effect in pairs(tech.effects or {}) do
      assert(effect.type ~= "unlock-quality", "quality unlock returned")
    end
  end
  for _, name in ipairs({"speed-module", "nqnp-test-hybrid-module"}) do
    assert(prototypes.item[name].type == "module" and not prototypes.item[name].hidden,
      name .. " lost useful module behavior")
  end
end

local function check_hidden(fresh_only)
  check_prototypes()
  local forces = fresh_only and {game.forces.player} or {game.forces.player, game.forces["modules-researched"]}
  for _, force in ipairs(forces) do
    for _, name in ipairs(tech_names) do
      assert(not force.technologies[name].enabled, name .. " research is enabled")
      assert(not force.recipes[name].enabled, name .. " recipe is enabled")
    end
  end
end

local function check_research_and_crafting()
  check_prototypes()
  local fresh = game.forces.player
  local researched = game.forces["modules-researched"]
  assert(not fresh.technologies.automation.enabled, "unrelated scripted research state was reset")
  for i, name in ipairs(tech_names) do
    assert(researched.technologies[name].researched, name .. " lost saved research")
    assert(fresh.technologies[name].enabled == needed(i), name .. " research availability")
    assert(researched.recipes[name].enabled == needed(i), name .. " saved recipe availability")
    assert(not fresh.technologies[name].researched, name .. " was granted for free")
    assert(not fresh.recipes[name].enabled, name .. " is craftable before research")
    if needed(i) then
      fresh.technologies[name].researched = true -- luacheck: ignore 122
      assert(fresh.recipes[name].enabled, name .. " was not unlocked by research")
    end
  end
  assert(fresh.recipes["nqnp-test-quality-module"].enabled, "modded module not unlocked")
  assert(researched.recipes["nqnp-test-quality-module"].enabled, "modded unlock not restored")
  fresh.technologies["nqnp-test-module-equipment"].researched = true -- luacheck: ignore 122

  local surface = game.surfaces[1]
  storage.machines = {}
  local beacon = assert(surface.create_entity{name = "beacon", position = {36, 0}, force = fresh})
  for i, name in ipairs(module_names) do
    if needed(i) then
      local machine = assert(surface.create_entity{
        name = "assembling-machine-3", position = {i * 6, 0}, force = fresh,
      })
      machine.set_recipe(name)
      for _, ingredient in pairs(fresh.recipes[name].ingredients) do
        assert(ingredient.type == "item", "unexpected fluid in test recipe")
        assert(machine.get_inventory(defines.inventory.crafter_input).insert{
          name = ingredient.name, count = ingredient.amount,
        } == ingredient.amount, "could not supply " .. name)
      end
      assert(machine.get_module_inventory().insert{name = name, count = 1} == 0,
        name .. " fits in machine module slots")
      assert(beacon.get_module_inventory().insert{name = name, count = 1} == 0,
        name .. " fits in beacon module slots")
      storage.machines[name] = machine
    end
  end
  storage.consumer = assert(surface.create_entity{
    name = "assembling-machine-3", position = {0, 6}, force = fresh,
  })
  storage.consumer.set_recipe("nqnp-test-module-equipment")
  local speed = storage.consumer.crafting_speed
  for _, name in ipairs({"speed-module", "nqnp-test-hybrid-module"}) do
    local slots = storage.consumer.get_module_inventory()
    assert(slots.insert{name = name, count = 1} == 1)
    assert(storage.consumer.crafting_speed > speed, name .. " lost its useful effect")
    assert((storage.consumer.effects.quality or 0) == 0, name .. " still affects quality")
    slots.clear()
  end
  storage.started, storage.supplied, storage.complete = game.tick, false, false
end

script.on_init(function()
  local researched = game.create_force("modules-researched")
  for _, name in ipairs(tech_names) do researched.technologies[name].researched = true end
  game.forces.player.technologies.automation.enabled = false -- luacheck: ignore 122
  storage.chest = assert(game.surfaces[1].create_entity{
    name = "steel-chest", position = {0, 12}, force = "player",
  })
  for _, name in ipairs(module_names) do assert(storage.chest.insert{name = name, count = 2} == 2) end
  if not script.active_mods["no-quality-no-problem"] then
    storage.legacy = assert(game.surfaces[1].create_entity{
      name = "assembling-machine-3", position = {0, 18}, force = "player",
    })
    storage.legacy.set_recipe("iron-gear-wheel")
    assert(storage.legacy.get_module_inventory().insert{name = "quality-module", count = 1} == 1)
    log("MODULES LEGACY SAVE CREATED")
  elseif tier() > 0 then
    check_research_and_crafting()
  else
    check_hidden(true)
    log("MODULES NO CONSUMER PASSED")
  end
end)

script.on_configuration_changed(function()
  -- Scenario callbacks precede mod callbacks. Observe the finished update next tick.
  storage.configuration_changed = true
end)

script.on_event(defines.events.on_tick, function()
  if storage.configuration_changed then
    storage.configuration_changed = nil
    if storage.legacy then
      -- The engine can retain old stacks in their slots after an item type
      -- change. They must lose all module effects, including cached penalties.
      for effect, value in pairs(storage.legacy.effects) do
        assert(value == 0, "old installed item still applies " .. effect)
      end
      assert(not storage.legacy.get_module_inventory().can_insert{name = "quality-module", count = 1},
        "converted item can still be installed")
    end
    for _, name in ipairs(module_names) do
      assert(storage.chest.get_inventory(defines.inventory.chest).get_item_count(name) == 2,
        name .. " inventory stack lost during conversion")
    end
    if tier() > 0 then
      check_research_and_crafting()
      log("MODULES EXISTING SAVE RESEARCH PASSED")
    else
      check_hidden()
      storage.started = nil
      log("MODULES REMOVED CONSUMER PASSED")
    end
  end
  if not storage.started or storage.complete then return end
  for _, machine in pairs(storage.machines) do machine.energy = 1e9 end
  storage.consumer.energy = 1e9
  if not storage.supplied then
    local ready = true
    for _, ingredient in pairs(game.forces.player.recipes["nqnp-test-module-equipment"].ingredients) do
      if storage.machines[ingredient.name].get_output_inventory().get_item_count(ingredient.name) < ingredient.amount then
        ready = false
      end
    end
    if ready then
      local input = storage.consumer.get_inventory(defines.inventory.crafter_input)
      for _, ingredient in pairs(game.forces.player.recipes["nqnp-test-module-equipment"].ingredients) do
        local stack = {name = ingredient.name, count = ingredient.amount}
        assert(storage.machines[ingredient.name].get_output_inventory().remove(stack) == ingredient.amount)
        assert(input.insert(stack) == ingredient.amount)
      end
      storage.supplied = true
    end
  end
  if storage.consumer.get_output_inventory().get_item_count("exoskeleton-equipment") == 1 then
    assert(storage.supplied, "equipment created without module ingredients")
    assert(storage.consumer.get_inventory(defines.inventory.crafter_input).is_empty(),
      "module ingredients were not consumed")
    storage.complete = true
    log("MODULES CRAFTING PASSED")
  elseif game.tick - storage.started >= 2400 then
    error("module or equipment crafting did not finish")
  end
end)
