-- Test ordinary consumers, dependency tiers, hybrids, and useless module loops.
local util = require("util")
local variant = require("variant")
local tier = variant == "high" and 3 or variant == "low" and 1 or 0
local component = util.table.deepcopy(data.raw.module["quality-module"])
component.name = "nqnp-test-quality-module"
component.effect = {quality = 0.03, speed = -0.2, pollution = 0.1}
local hybrid = util.table.deepcopy(component)
hybrid.name = "nqnp-test-hybrid-module"
hybrid.effect = {quality = 0.03, speed = 0.2}
local recipe = util.table.deepcopy(data.raw.recipe["quality-module"])
recipe.name = component.name
recipe.results = {{type = "item", name = component.name, amount = 1}}
data:extend({component, hybrid, recipe, {
  type = "mod-data", name = "nqnp-test-module-consumer", data = {tier = tier},
}})
table.insert(data.raw.technology["quality-module"].effects,
  {type = "unlock-recipe", recipe = component.name})

for i = 1, 2 do
  local item = util.table.deepcopy(component)
  item.name = "nqnp-test-unused-" .. i
  data:extend({item, {
    type = "recipe", name = item.name, enabled = true,
    ingredients = {{type = "item", name = "nqnp-test-unused-" .. (3 - i), amount = 1}},
    results = {{type = "item", name = item.name, amount = 1}},
  }})
end
-- Visible recycling recipes must not create demand, regardless of their names.
data:extend({{
  type = "recipe", name = "nqnp-test-salvage", categories = {"recycling"}, enabled = true,
  ingredients = {{type = "item", name = "nqnp-test-unused-1", amount = 1}},
  results = {{type = "item", name = "electronic-circuit", amount = 1}},
}, {
  type = "recipe", name = "nqnp-test-name-recycling", enabled = true,
  ingredients = {{type = "item", name = "nqnp-test-unused-2", amount = 1}},
  results = {{type = "item", name = "electronic-circuit", amount = 1}},
}, {
  type = "recipe", name = "nqnp-test-hidden-consumer", hidden = true, enabled = false,
  ingredients = {{type = "item", name = "nqnp-test-unused-1", amount = 1}},
  results = {{type = "item", name = "electronic-circuit", amount = 1}},
}})

if tier > 0 then
  local name = tier == 1 and "quality-module" or "quality-module-3"
  data:extend({{
    type = "recipe", name = "nqnp-test-module-equipment", enabled = false, energy_required = 0.5,
    ingredients = {
      {type = "item", name = name, amount = 1},
      {type = "item", name = component.name, amount = 1},
    },
    results = {{type = "item", name = "exoskeleton-equipment", amount = 1}},
  }, {
    type = "technology", name = "nqnp-test-module-equipment",
    icon = "__base__/graphics/technology/exoskeleton-equipment.png", icon_size = 256,
    prerequisites = {name},
    unit = {count = 1, ingredients = {{"automation-science-pack", 1}}, time = 1},
    effects = {{type = "unlock-recipe", recipe = "nqnp-test-module-equipment"}},
  }})
end
