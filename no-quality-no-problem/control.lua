-- Prototype changes alone do not restore disabled research in existing saves.
-- Update only the module unlocks we hide; preserve research progress and all
-- unrelated force state. This runs on configuration changes, never each tick.
local function sync_module_unlocks()
  local tracked = prototypes.mod_data["no-quality-no-problem-module-unlocks"].data
  for _, force in pairs(game.forces) do
    for name in pairs(tracked.technologies) do
      force.technologies[name].enabled = prototypes.technology[name].enabled
    end
    for name in pairs(tracked.recipes) do
      force.recipes[name].enabled = prototypes.recipe[name].enabled
    end
    for name, technology in pairs(force.technologies) do
      if technology.researched then
        for _, effect in pairs(prototypes.technology[name].effects) do
          if effect.type == "unlock-recipe" and tracked.recipes[effect.recipe]
            and not tracked.hidden_recipes[effect.recipe] then
            force.recipes[effect.recipe].enabled = true
          end
        end
      end
    end
  end
end

script.on_init(sync_module_unlocks)
script.on_configuration_changed(sync_module_unlocks)
