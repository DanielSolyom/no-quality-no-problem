local util = require("util")
local exclusions = require("quality-exclusions")

-- These types need named exclusions because they also serve player equipment.
-- Natural simple-entities (including demolisher corpses), trees and plants do
-- not scale health with quality and must not receive health compensation.
local named_types = {
  container = true,
  ["lightning-attractor"] = true,
  ["smoke-with-trigger"] = true,
  sticker = true,
  ["spider-leg"] = true,
}

local function default_multiplier(quality)
  return quality.default_multiplier or (1 + 0.3 * quality.level)
end

local function range_multiplier(quality)
  return quality.range_multiplier or math.min(1 + 0.1 * quality.level, 3)
end

return function(normal, best)
  -- Quality is shared globally, so merely skipping these prototypes would not
  -- exclude them. Offset the engine's new multipliers in their base stats.
  local stat_ratio = default_multiplier(normal) / default_multiplier(best)
  local range_ratio = range_multiplier(normal) / range_multiplier(best)
  local excluded = {}

  for prototype_type, group in pairs(data.raw) do
    for name, prototype in pairs(group) do
      local match = exclusions.types[prototype_type] or exclusions.names[name]
      for _, prefix in ipairs(exclusions.prefixes) do
        if name:sub(1, #prefix) == prefix then match = true end
      end
      if match and (exclusions.types[prototype_type] or named_types[prototype_type]) then
        excluded[prototype] = true
      end
    end
  end

  -- Parts can be shared by excluded enemies and player vehicles (even vanilla's
  -- dummy-spider-unit shares Spidertron legs). Clone only those shared parts.
  local player_legs = {}
  for _, group in pairs(data.raw) do
    for _, prototype in pairs(group) do
      local legs = prototype.spider_engine and prototype.spider_engine.legs
      if legs and not excluded[prototype] then
        if legs.leg then legs = {legs} end
        for _, leg in pairs(legs) do player_legs[leg.leg] = true end
      end
    end
  end

  local parts, copies = {}, {}
  for prototype in pairs(excluded) do
    if prototype.spider_engine then
      prototype.spider_engine = util.table.deepcopy(prototype.spider_engine)
      local legs = prototype.spider_engine.legs
      if legs.leg then legs = {legs} end
      for _, leg in pairs(legs) do
        local p = (data.raw["spider-leg"] or {})[leg.leg]
        if p and player_legs[leg.leg] then
          if not copies[p] then
            local copy = util.table.deepcopy(p)
            copy.name = "nqnp-world-" .. p.name
            data:extend{copy}
            copies[p] = copy
          end
          p = copies[p]
          leg.leg = p.name
        end
        if p then parts[p] = true end
      end
    end
  end
  for part in pairs(parts) do excluded[part] = true end

  local function preserve_attack(attack)
    if not attack then return end
    -- Attack tables can be shared by prototypes from other mods.
    attack = util.table.deepcopy(attack)
    attack.damage_modifier = (attack.damage_modifier or 1) * stat_ratio
    attack.range = attack.range * range_ratio
    return attack
  end

  local fire_copies = {}
  local function preserve_cloud_action(action)
    action = util.table.deepcopy(action)
    local visited, damages = {}, {}
    local function visit(node)
      if type(node) ~= "table" or visited[node] then return end
      visited[node] = true
      if node.type == "damage" and not damages[node.damage] then
        node.damage.amount = node.damage.amount * stat_ratio
        damages[node.damage] = true
      elseif node.type == "create-fire" then
        -- Crash-site smoke passes its multiplier into the fire it creates.
        -- Use a separate fire so directly created fires keep their base damage.
        local fire = (data.raw.fire or {})[node.entity_name]
        if fire then
          local copy = fire_copies[fire.name]
          if not copy then
            copy = util.table.deepcopy(fire)
            fire_copies[fire.name] = copy
            copy.name = "nqnp-world-" .. fire.name
            copy.damage_per_tick.amount = copy.damage_per_tick.amount * stat_ratio
            copy.on_damage_tick_effect = preserve_cloud_action(copy.on_damage_tick_effect)
            copy.on_fuel_added_action = preserve_cloud_action(copy.on_fuel_added_action)
            data:extend{copy}
          end
          node.entity_name = copy.name
        end
      end
      for _, child in pairs(node) do visit(child) end
    end
    visit(action)
    return action
  end

  for prototype in pairs(excluded) do
    if prototype.type == "smoke-with-trigger" then
      -- Smoke applies its own quality multiplier, independently of the attacker.
      prototype.action = preserve_cloud_action(prototype.action)
    elseif prototype.type == "sticker" then
      -- Enemy slow/disruption effects also gain duration from quality. The
      -- prototype requires whole ticks; round down for unusual modded tiers.
      prototype.duration_in_ticks = math.max(1, math.floor(prototype.duration_in_ticks * stat_ratio))
    else
      prototype.max_health = (prototype.max_health or 10) * stat_ratio
      prototype.attack_parameters = preserve_attack(prototype.attack_parameters)
      prototype.revenge_attack_parameters = preserve_attack(prototype.revenge_attack_parameters)
    end

    -- Crash-site chests/spaceship inventories and natural lightning protection
    -- should stay at their normal size, too.
    if prototype.type == "container" then
      if prototype.quality_affects_inventory_size ~= false then
        local multiplier = normal.inventory_size_multiplier or default_multiplier(normal)
        prototype.inventory_size = math.floor(prototype.inventory_size * multiplier)
        prototype.quality_affects_inventory_size = false
      end
    elseif prototype.type == "lightning-attractor" then
      prototype.range_elongation = (prototype.range_elongation or 0) * stat_ratio
      prototype.efficiency = (prototype.efficiency or 0) * stat_ratio
    end
  end
end
