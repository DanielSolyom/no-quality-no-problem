-- Minimal Factorio .luacheckrc (data stage + control stage).
std = "lua52c"
max_line_length = false
ignore = { "212/event", "212/self" }

exclude_files = { ".testrun", "dist", ".build" }

read_globals = {
  -- data stage
  "mods", "settings", "feature_flags", "table_size",
  "log", "localised_print", "serpent",
  -- control stage
  "game", "script", "commands", "remote", "rendering",
  "prototypes", "helpers", "defines", "rcon",
  -- Lua 5.2 extras Factorio keeps
  "table", "string", "math",
}
globals = { "data", "storage" }
