-- Entities that should retain their original normal-quality stats.
-- Type entries cover every size/variant, including prototypes added by mods.
-- Names and prefixes cover world objects that share a type with factory buildings.
return {
  types = {
    asteroid = true,
    unit = true,
    ["unit-spawner"] = true,
    turret = true, -- worms; player defences use ammo/electric/fluid/artillery-turret
    ["spider-unit"] = true,
    ["segmented-unit"] = true,
    segment = true,
    ["simple-entity-with-owner"] = true,
    ["simple-entity-with-force"] = true,
    market = true,
  },
  names = {
    ["fulgoran-ruin-attractor"] = true,
    ["acid-cloud"] = true, -- nest retaliation; poison-cloud is a player weapon
    ["demolisher-ash-sticker"] = true,
    ["strafer-sticker"] = true,
    ["small-acid-sticker-stomper"] = true,
    ["medium-acid-sticker-stomper"] = true,
    ["big-acid-sticker-stomper"] = true,
  },
  prefixes = {
    "crash-site-", "acid-sticker-",
    "small-demolisher-", "medium-demolisher-", "big-demolisher-",
  },
}
