-- Keep quality-only items only when useful recipes consume them. Module upgrade
-- chains and recycling cannot create demand, but needed tiers keep their inputs.
return function()
  local components = {}
  for name, module in pairs(data.raw.module or {}) do
    local effect = module.effect
    if effect and effect.quality then
      effect.quality = nil
      local useful = (effect.speed and effect.speed > 0)
        or (effect.productivity and effect.productivity > 0)
        or (effect.consumption and effect.consumption < 0)
        or (effect.pollution and effect.pollution < 0)
      if not useful then components[name] = module end
    end
  end

  local function is_recycling(recipe)
    if recipe.name:match("%-recycling$") then return true end
    for _, category in pairs(recipe.categories or {recipe.category or "crafting"}) do
      if category:find("recycling", 1, true) then return true end
    end
    return false
  end

  local function has_output(product)
    return (product.probability or 1) > 0
      and (product.amount or product.amount_max or 1) + (product.extra_count_fraction or 0) > 0
  end

  local needed, producers, pending = {}, {}, {}
  local function need_ingredients(recipe)
    for _, ingredient in pairs(recipe.ingredients or {}) do
      if ingredient.type == "item" and components[ingredient.name] and not needed[ingredient.name] then
        needed[ingredient.name] = true
        pending[#pending + 1] = ingredient.name
      end
    end
  end

  for _, recipe in pairs(data.raw.recipe or {}) do
    if not recipe.hidden and not is_recycling(recipe) then
      local useful = false
      for _, product in pairs(recipe.results or {}) do
        if has_output(product) then
          if product.type == "item" and components[product.name] then
            producers[product.name] = producers[product.name] or {}
            table.insert(producers[product.name], recipe)
          else
            useful = true
          end
        end
      end
      if useful then need_ingredients(recipe) end
    end
  end

  -- Visit each required item once; cycles between module recipes terminate.
  local cursor = 1
  while pending[cursor] do
    for _, recipe in pairs(producers[pending[cursor]] or {}) do need_ingredients(recipe) end
    cursor = cursor + 1
  end

  -- An ordinary item cannot enter a machine's or beacon's module slots.
  -- Keep names and item properties so recipes and existing inventory stacks
  -- continue to refer to the same ingredients.
  local module_fields = {
    "effect", "category", "tier", "requires_beacon_alt_mode", "art_style", "beacon_tint",
    "consumption_quality_multiplier", "speed_quality_multiplier", "productivity_quality_multiplier",
    "pollution_quality_multiplier", "quality_quality_multiplier",
  }
  for name, item in pairs(components) do
    data.raw.module[name] = nil
    item.type = "item"
    for _, field in ipairs(module_fields) do item[field] = nil end
    item.localised_description = {"no-quality-no-problem.quality-module-description"}
    if not needed[name] then
      item.hidden = true
      item.hidden_in_factoriopedia = true
    end
    data:extend({item})
  end

  local hidden_recipes, module_recipes = {}, {}
  for name, recipe in pairs(data.raw.recipe or {}) do
    if recipe.results and #recipe.results > 0 then
      local all_components, any_needed = true, false
      for _, product in ipairs(recipe.results) do
        if product.type ~= "item" or not components[product.name] then all_components = false end
        if needed[product.name] and has_output(product) then any_needed = true end
      end
      if all_components then
        module_recipes[name] = true
        if not any_needed then
          recipe.hidden = true
          recipe.hidden_in_factoriopedia = true
          recipe.enabled = false
          hidden_recipes[name] = true
        end
      end
    end
  end
  return hidden_recipes, module_recipes
end
