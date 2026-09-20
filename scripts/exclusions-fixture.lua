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
