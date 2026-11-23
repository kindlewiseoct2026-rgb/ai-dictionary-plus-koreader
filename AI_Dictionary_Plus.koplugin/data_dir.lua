-- Saved data (lookup history, Word Sense meanings) lives in
-- <KOReader folder>/ai_dictionary/, outside the plugin folder, so deleting or
-- replacing the plugin never removes it. Data left inside an older plugin
-- folder is moved over the first time it is needed.
local DataDir = {}

local FOLDER = "ai_dictionary"
local migrated = {}

local function lfs_module()
  local ok, lfs = pcall(require, "libs/libkoreader-lfs")
  return ok and lfs or nil
end

local function is_directory(lfs, path)
  return lfs.attributes(path, "mode") == "directory"
end

local function ensure_directory(lfs, path)
  if is_directory(lfs, path) then return true end
  lfs.mkdir(path)
  return is_directory(lfs, path)
end

local function move_file(from, to)
  if os.rename(from, to) then return true end
  local input = io.open(from, "rb")
  if not input then return false end
  local data = input:read("*a")
  input:close()
  local output = io.open(to, "wb")
  if not output then return false end
  local written = output:write(data)
  output:close()
  if not written then
    os.remove(to)
    return false
  end
  os.remove(from)
  return true
end

-- Moves files from the old in-plugin folder into the new one without ever
-- overwriting something already there, then removes the old folder if empty.
local function migrate(lfs, legacy, target)
  if not is_directory(lfs, legacy) then return end
  for name in lfs.dir(legacy) do
    if name ~= "." and name ~= ".." then
      local from, to = legacy .. "/" .. name, target .. "/" .. name
      if lfs.attributes(from, "mode") == "file" and not lfs.attributes(to, "mode") then
        move_file(from, to)
      end
    end
  end
  lfs.rmdir(legacy)
end

-- <KOReader folder>/ai_dictionary, or nil when KOReader's data folder is unknown.
function DataDir.root()
  local ok, base = pcall(function() return require("datastorage"):getDataDir() end)
  if ok and type(base) == "string" and base ~= "" then
    return (base:gsub("/+$", "")) .. "/" .. FOLDER
  end
end

-- The folder for `name` ("Lookups" or "word_sense"). It falls back to the plugin
-- folder when KOReader's data folder cannot be used.
function DataDir.folder(plugin_path, name)
  local base = (plugin_path and plugin_path ~= "") and (plugin_path:gsub("/+$", "")) or "AI_Dictionary_Plus.koplugin"
  local legacy = base .. "/" .. name
  local root, lfs = DataDir.root(), lfs_module()
  if not root or not lfs then return legacy end
  local target = root .. "/" .. name
  if not (ensure_directory(lfs, root) and ensure_directory(lfs, target)) then return legacy end
  if not migrated[target] then
    migrated[target] = true
    pcall(migrate, lfs, legacy, target)
  end
  return target
end

return DataDir
