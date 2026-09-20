-- Always Legendary (No Quality)
--
-- Strategy:
--   1. The QualityPrototype drives the engine's quality scaling through:
--      `level` (engine-side per-level scaling) plus explicit multiplier/bonus
--      fields. So flattening ALL quality prototypes to the stats of the
--      highest-level quality ("legendary" in vanilla) makes every item and
--      factory entity behave as legendary. The exclusion list compensates
--      enemies and world objects so they keep their normal stats.
--   2. Hiding every quality (like the base game hides "normal") removes the
--      quality UI: no quality badges, no quality selectors, no Factoriopedia
--      entries.
--   3. Strip the `quality` effect from all modules. Quality-only modules
--      become inert and are hidden unless kept as crafting ingredients.
--
-- Runs in data-final-fixes, after dependent mods have defined their recipes.

local util = require("util") -- do not rely on another mod having loaded it first

local qualities = data.raw.quality
if not qualities then return end

------------------------------------------------------------------------------
-- 1. Flatten all qualities to the best one's stats
------------------------------------------------------------------------------

-- Template = highest-level quality present (vanilla: legendary, level 5).
local template
for _, q in pairs(qualities) do
  if not template or (q.level or 0) > (template.level or 0) then
    template = q
  end
end
if not template then return end

require("preserve-world-stats")(qualities.normal, template)

-- Identity/cosmetic/progression keys that must NOT be copied between qualities.
local skip = {
  type = true, name = true, order = true, subgroup = true,
  icon = true, icons = true, icon_size = true, color = true,
  localised_name = true, localised_description = true,
  factoriopedia_description = true, factoriopedia_simulation = true,
  factoriopedia_alternative = true, custom_tooltip_fields = true,
  hidden = true, hidden_in_factoriopedia = true, parameter = true,
  next = true, next_probability = true, chain_probability = true,
  previous_probability = true, previous_chain_probability = true,
  draw_sprite_by_default = true,
}

for _, q in pairs(qualities) do
  if q ~= template then
    -- Remove stat keys the template does not have...
    for k in pairs(q) do
      if not skip[k] then q[k] = nil end
    end
    -- ...then copy every stat key from the template (covers any future
    -- multiplier/bonus Wube or mods add, without a mod update).
    for k, v in pairs(template) do
      if not skip[k] then q[k] = util.table.deepcopy(v) end
    end
  end
end

-- Hide the mechanic: no badges, no selector entries, no quality chain.
for _, q in pairs(qualities) do
  q.hidden = true
  q.hidden_in_factoriopedia = true
  q.draw_sprite_by_default = false
  q.next = nil
  q.next_probability = nil
  q.chain_probability = nil
  q.previous_probability = nil
  q.previous_chain_probability = nil
end

------------------------------------------------------------------------------
-- 2. Retain useful crafting ingredients as ordinary items; remove quality effects
------------------------------------------------------------------------------

local hidden_recipes, module_recipes = require("quality-module-ingredients")()

------------------------------------------------------------------------------
-- 3. Clean the technology tree
------------------------------------------------------------------------------

local hidden_techs, module_techs = {}, {}
for tname, t in pairs(data.raw.technology or {}) do
  if t.effects then
    local kept, removed_any = {}, false
    local has_module_unlock, has_other_effect = false, false
    for _, eff in ipairs(t.effects) do
      if eff.type == "unlock-recipe" and module_recipes[eff.recipe] then
        has_module_unlock = true
      elseif eff.type ~= "unlock-quality" then
        has_other_effect = true
      end
      if eff.type == "unlock-quality"
        or (eff.type == "unlock-recipe" and hidden_recipes[eff.recipe]) then
        removed_any = true
      else
        kept[#kept + 1] = eff
      end
    end
    -- Only these technologies switch between hidden and researchable. Mixed
    -- technologies stay available in both modes and need no runtime reset.
    if has_module_unlock and not has_other_effect then module_techs[tname] = true end
    if removed_any then
      t.effects = kept
      if #kept == 0 then -- tech existed only for quality: hide it
        t.hidden = true
        t.enabled = false
        hidden_techs[tname] = true
      end
    end
  end
end

data:extend({{
  type = "mod-data",
  name = "no-quality-no-problem-module-unlocks",
  data = {recipes = module_recipes, hidden_recipes = hidden_recipes, technologies = module_techs},
}})

-- Splice hidden quality techs out of other techs' prerequisite chains.
if next(hidden_techs) then
  for tname, t in pairs(data.raw.technology or {}) do
    if not hidden_techs[tname] and t.prerequisites then
      local new, seen = {}, {}
      local function add(p, visiting)
        if seen[p] or visiting[p] then return end
        if hidden_techs[p] then
          visiting[p] = true
          local ht = data.raw.technology[p]
          for _, pp in ipairs((ht and ht.prerequisites) or {}) do
            add(pp, visiting)
          end
          visiting[p] = nil
        else
          seen[p] = true
          new[#new + 1] = p
        end
      end
      for _, p in ipairs(t.prerequisites) do add(p, {}) end
      t.prerequisites = new
    end
  end
end

------------------------------------------------------------------------------
-- 4. Remove quality tips-and-tricks and hide the quality signal
------------------------------------------------------------------------------

local tip_items = data.raw["tips-and-tricks-item"] or {}
local removed_tips = {}
for name, tip in pairs(tip_items) do
  if tip.category == "quality" then
    removed_tips[name] = true
  end
end
for name in pairs(removed_tips) do
  tip_items[name] = nil
end
-- Strip dangling dependencies on removed tips.
for _, tip in pairs(tip_items) do
  if tip.dependencies then
    local deps = {}
    for _, d in ipairs(tip.dependencies) do
      if not removed_tips[d] then deps[#deps + 1] = d end
    end
    tip.dependencies = deps
  end
end
local tip_categories = data.raw["tips-and-tricks-item-category"]
if tip_categories then tip_categories["quality"] = nil end

local sig = data.raw["virtual-signal"] and data.raw["virtual-signal"]["signal-any-quality"]
if sig then
  sig.hidden = true
  sig.hidden_in_factoriopedia = true
end
