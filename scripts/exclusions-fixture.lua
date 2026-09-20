-- A non-vanilla quality multiplier and modded enemies prevent hardcoded 2.5x
-- fixes and lists of vanilla enemy names from passing the regression checks.
local quality = table.deepcopy(data.raw.quality.legendary)
quality.name = "test-mythic"
quality.level = 7
quality.default_multiplier = 4
quality.range_multiplier = 1.8
data:extend{quality}

local biter = table.deepcopy(data.raw.unit["small-biter"])
biter.name = "test-biter"
biter.max_health = 123
data:extend{biter}

local asteroid = table.deepcopy(data.raw.asteroid["small-metallic-asteroid"])
asteroid.name = "test-asteroid"
asteroid.max_health = nil -- Exercise the engine's default health as well.
data:extend{asteroid}

-- Exercise all interpolated slow fields, including non-default end values.
local sticker = table.deepcopy(data.raw.sticker["acid-sticker-small"])
sticker.name = "acid-sticker-test"
sticker.target_movement_modifier_from = 0.3
sticker.target_movement_modifier_to = 0.8
sticker.target_movement_max_from = 0.06
sticker.target_movement_max_to = 0.15
sticker.vehicle_speed_modifier_from = 0.2
sticker.vehicle_speed_modifier_to = 0.75
sticker.vehicle_speed_max_from = 0.1
sticker.vehicle_speed_max_to = 0.5
sticker.vehicle_friction_modifier_from = 1.6
sticker.vehicle_friction_modifier_to = 0.8
data:extend{sticker}
