-- Headless servers have no connected LuaPlayer to call use_from_cursor. Expose
-- each capsule's original attack through a gun/ammo pair for the combat oracle.
for _, name in ipairs{"defender-capsule", "distractor-capsule", "destroyer-capsule", "grenade", "cluster-grenade", "poison-capsule", "slowdown-capsule"} do
  local capsule = data.raw.capsule[name]
  local attack = capsule.capsule_action.attack_parameters
  if attack then
    local gun = table.deepcopy(data.raw.gun.pistol)
    gun.name = "nqnp-test-gun-" .. name
    gun.attack_parameters = table.deepcopy(attack)
    gun.attack_parameters.ammo_type = nil
    gun.attack_parameters.ammo_category = "bullet"
    gun.attack_parameters.activation_type = "shoot"
    gun.attack_parameters.range = math.max(20, gun.attack_parameters.range)
    local ammo = table.deepcopy(data.raw.ammo["firearm-magazine"])
    ammo.name = "nqnp-test-" .. name
    ammo.magazine_size = 1
    ammo.ammo_type = table.deepcopy(attack.ammo_type)
    if capsule.capsule_action.type == "use-on-self" then ammo.ammo_type.target_type = "entity" end
    data:extend{gun, ammo}
  end
end
