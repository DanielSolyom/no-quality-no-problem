-- Measure actual movement and vehicle effects throughout their lifetime.
-- A matching prototype duration alone missed the acid immobilisation bug.
local movement = {}

local function is_enemy_sticker(name)
  return name:find("acid-sticker", 1, true)
    or name == "strafer-sticker" or name == "demolisher-ash-sticker"
end

local function attach(test, name, quality)
  for _, target in ipairs{test.character, test.car} do
    assert(target.surface.create_entity{
      name = name, position = target.position, target = target,
      force = "enemy", quality = quality or "normal",
    })
  end
end

function movement.init(best)
  local cases = {{name = "unaffected"}}
  for name, prototype in pairs(prototypes.entity) do
    if prototype.type == "sticker" and not name:find("behind", 1, true) then
      cases[#cases + 1] = {
        name = name, stickers = {name}, quality = is_enemy_sticker(name) and "normal" or best.name,
      }
    elseif prototype.type == "fire" and name:find("acid-splash", 1, true) then
      cases[#cases + 1] = {name = "puddle/" .. name, fires = {name}}
    end
  end
  local mixed = {}
  local mixed_fires = {}
  for _, size in ipairs{"small", "medium", "big", "behemoth"} do
    local name = "acid-sticker-" .. size
    mixed[#mixed + 1] = name
    mixed_fires[#mixed_fires + 1] = "acid-splash-fire-spitter-" .. size
    cases[#cases + 1] = {name = "refreshed/" .. name, stickers = {name}, refresh = name}
  end
  cases[#cases + 1] = {name = "mixed-acid", stickers = mixed}
  cases[#cases + 1] = {name = "mixed-puddles", fires = mixed_fires}
  table.sort(cases, function(a, b) return a.name < b.name end)

  local surface = game.create_surface("movement", {
    seed = 42, autoplace_settings = {
      entity = {treat_missing_as_default = false},
      decorative = {treat_missing_as_default = false},
    },
  })
  for index in ipairs(cases) do surface.request_to_generate_chunks({32, index * 8}, 2) end
  surface.force_generate_chunk_requests()
  local tiles = {}
  for x = -8, 128 do
    for y = 0, (#cases + 1) * 8 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
  end
  surface.set_tiles(tiles)
  storage.movement = {}
  storage.results.movement = {}
  for index, case in ipairs(cases) do
    local character = assert(surface.create_entity{name = "character", position = {0, index * 8}, force = "player"})
    character.character_health_bonus = 1000000
    -- Wait for ground splashes to become active before trying to walk out.
    character.walking_state = {walking = not case.fires, direction = defines.direction.east}
    local test = {
      character = character, refresh = case.refresh, walk_tick = case.fires and 60 or nil,
      car = assert(surface.create_entity{name = "car", position = {-2, index * 8 + 3}, force = "player"}),
    }
    storage.movement[case.name] = test
    storage.results.movement[case.name] = {}
    for _, sticker in ipairs(case.stickers or {}) do attach(test, sticker, case.quality) end
    for _, fire in ipairs(case.fires or {}) do
      assert(surface.create_entity{name = fire, position = character.position, force = "enemy"})
    end
  end
end

function movement.tick(tick)
  if tick >= 320 then return end
  for name, test in pairs(storage.movement) do
    if test.refresh and tick <= 180 then attach(test, test.refresh) end
    local character = test.character
    if test.walk_tick == tick then
      character.walking_state = {walking = true, direction = defines.direction.east}
    end
    local stickers = {}
    for _, sticker in pairs(character.stickers or {}) do
      stickers[sticker.name] = sticker.time_to_live
    end
    local samples = storage.results.movement[name]
    samples[#samples + 1] = {
      speed = character.character_running_speed, x = character.position.x,
      vehicle = test.car.sticker_vehicle_modifiers, stickers = stickers,
    }
  end
end

return movement
