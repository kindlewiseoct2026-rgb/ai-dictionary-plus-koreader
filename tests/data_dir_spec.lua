-- Run from the repository root: luajit tests/data_dir_spec.lua
package.path = "./AI_Dictionary_Plus.koplugin/?.lua;" .. package.path
package.loaded.logger = { warn = function() end }

local function shell(command) return os.execute(command) end
local function quote(path) return "'" .. path .. "'" end
-- A small filesystem layer backed by the shell, standing in for libkoreader-lfs.
package.loaded["libs/libkoreader-lfs"] = {
  attributes = function(path, what)
    if what == "size" then return 0 end
    local pipe = io.popen("if [ -d " .. quote(path) .. " ]; then echo directory; elif [ -f " .. quote(path) .. " ]; then echo file; fi")
    local mode = pipe:read("*l")
    pipe:close()
    return mode ~= "" and mode or nil
  end,
  mkdir = function(path) return shell("mkdir " .. quote(path) .. " 2>/dev/null") ~= nil end,
  rmdir = function(path) return shell("rmdir " .. quote(path) .. " 2>/dev/null") ~= nil end,
  dir = function(path)
    local pipe = io.popen("ls -A " .. quote(path))
    local names = { ".", ".." }
    for name in pipe:lines() do names[#names + 1] = name end
    pipe:close()
    local index = 0
    return function() index = index + 1; return names[index] end
  end,
}

local function temporary_directory()
  local name = os.tmpname()
  os.remove(name)
  assert(shell("mkdir -p " .. quote(name)))
  return name
end
local function write(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end
local function read(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local text = file:read("*a")
  file:close()
  return text
end
local function exists(path) return io.open(path, "rb") ~= nil end

local koreader, plugin = temporary_directory(), temporary_directory()
local DataDir = require("data_dir")

-- Without KOReader's data folder everything stays in the plugin folder, as before.
assert(DataDir.root() == nil)
assert(DataDir.folder(plugin, "Lookups") == plugin .. "/Lookups")
assert(not exists(plugin .. "/Lookups"), "the fallback creates nothing by itself")
assert(DataDir.folder(nil, "word_sense") == "AI_Dictionary_Plus.koplugin/word_sense")

-- With it, data goes to <koreader>/ai_dictionary/, outside the plugin.
package.loaded.datastorage = { getDataDir = function() return koreader .. "/" end }
assert(DataDir.root() == koreader .. "/ai_dictionary")
assert(DataDir.folder(plugin, "Lookups") == koreader .. "/ai_dictionary/Lookups")
assert(DataDir.folder(plugin, "word_sense") == koreader .. "/ai_dictionary/word_sense")
assert(io.open(koreader .. "/ai_dictionary/Lookups/.", "r"), "folders are created")

-- Data that an older plugin version kept inside its own folder is moved over once.
assert(shell("mkdir -p " .. quote(plugin .. "/Lookups") .. " " .. quote(plugin .. "/word_sense")))
write(plugin .. "/Lookups/Lookups.txt", "old lookups")
write(plugin .. "/word_sense/book.lua", "return {}")
package.loaded.data_dir = nil
DataDir = require("data_dir")
local lookups = DataDir.folder(plugin, "Lookups")
local senses = DataDir.folder(plugin, "word_sense")
assert(read(lookups .. "/Lookups.txt") == "old lookups" and read(senses .. "/book.lua") == "return {}")
assert(not exists(plugin .. "/Lookups/Lookups.txt") and not exists(plugin .. "/word_sense/book.lua"))

-- Moving never overwrites newer data that is already in the new folder.
package.loaded.data_dir = nil
DataDir = require("data_dir")
assert(shell("mkdir -p " .. quote(plugin .. "/Lookups")))
write(plugin .. "/Lookups/Lookups.txt", "stale copy")
write(lookups .. "/Lookups.txt", "current data")
DataDir.folder(plugin, "Lookups")
assert(read(lookups .. "/Lookups.txt") == "current data" and read(plugin .. "/Lookups/Lookups.txt") == "stale copy")

-- Everything that stores data uses the new place.
package.loaded.data_dir = nil
local save_lookup = require("lookups_log")
local Report = require("lookups_report")
local Store = require("word_sense_store")
assert(save_lookup(plugin, "serendipity", "A moment of serendipity arrived.") == true)
local logged = read(lookups .. "/Lookups.txt")
assert(logged and logged:find("serendipity", 1, true) and logged:find("current data", 1, true))
assert(#Report.load_entries(plugin, nil) >= 1)
local store = assert(Store.new(plugin, "/books/a.epub", { compare = function() return 0 end }))
assert(store.dir == koreader .. "/ai_dictionary/word_sense", store.dir)

-- Deleting the plugin folder leaves the saved data alone.
assert(shell("rm -rf " .. quote(plugin)))
assert(read(lookups .. "/Lookups.txt"):find("serendipity", 1, true))
assert(read(senses .. "/book.lua") == "return {}")

shell("rm -rf " .. quote(koreader))
print("data_dir_spec: new location, one-time move, no overwriting and plugin deletion passed")
