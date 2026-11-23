-- Persistent Word Sense results: one file per book inside <plugin>/word_sense/.
-- Records are whole request chunks (id, pos0, pos1, entries), kept sorted in
-- document order so any word can be matched to its stored chunk with a binary
-- search. Files are plain Lua data tables, loaded in an empty environment.
local logger = require("logger")
local DataDir = require("data_dir")

local Store = {}
Store.__index = Store

local FORMAT_VERSION = 1
local DIR_NAME = "word_sense"
local MAX_FILE_BYTES = 32 * 1024 * 1024
local MAX_MEANING_BYTES = 240

local function lfs_module()
  local ok, lfs = pcall(require, "libs/libkoreader-lfs")
  return ok and lfs or nil
end

local function sanitize(text, limit)
  return (tostring(text):gsub("[^%w%-_]", "_")):sub(1, limit)
end

local function basename(file)
  return file:match("([^/\\]+)$") or file
end

-- A stable id for the book: KOReader's partial MD5 when available (survives
-- renames and moves), otherwise the sanitized file name plus its size.
function Store.book_key(file)
  local ok, md5 = pcall(function() return require("util").partialMD5(file) end)
  if ok and type(md5) == "string" and md5:match("^%x+$") then return md5 end
  local lfs = lfs_module()
  local size = lfs and lfs.attributes(file, "size") or 0
  return sanitize(basename(file), 60) .. "_" .. tostring(size)
end

local function encode_value(value, out)
  local kind = type(value)
  if kind == "string" then
    out[#out + 1] = string.format("%q", value)
  elseif kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      error("cannot save a non-finite number")
    end
    if value % 1 == 0 and math.abs(value) < 2 ^ 53 then
      out[#out + 1] = string.format("%d", value)
    else
      out[#out + 1] = string.format("%.17g", value)
    end
  elseif kind == "boolean" then
    out[#out + 1] = tostring(value)
  elseif kind == "table" then
    out[#out + 1] = "{"
    local count = #value
    for i = 1, count do
      encode_value(value[i], out)
      out[#out + 1] = ","
    end
    for key, item in pairs(value) do
      local in_array = type(key) == "number" and key % 1 == 0 and key >= 1 and key <= count
      if not in_array then
        if type(key) ~= "string" then error("cannot save a non-string table key") end
        out[#out + 1] = "[" .. string.format("%q", key) .. "]="
        encode_value(item, out)
        out[#out + 1] = ","
      end
    end
    out[#out + 1] = "}"
  else
    error("cannot save a value of type " .. kind)
  end
end

function Store.encode(data)
  local out = { "return " }
  encode_value(data, out)
  return table.concat(out)
end

-- Data files can only ever evaluate to a table: no globals, no bytecode.
function Store.decode(text)
  if type(text) ~= "string" or text:sub(1, 1) == "\27" then return end
  local chunk
  if setfenv then
    chunk = loadstring(text)
    if chunk then setfenv(chunk, {}) end
  else
    chunk = load(text, "=word_sense", "t", {})
  end
  if not chunk then return end
  local ok, value = pcall(chunk)
  if ok and type(value) == "table" then return value end
end

local function valid_position(pos)
  return type(pos) == "string" or type(pos) == "table"
end

local function valid_entry(entry)
  return type(entry) == "table" and valid_position(entry.pos0) and valid_position(entry.pos1)
    and type(entry.meaning) == "string" and #entry.meaning <= MAX_MEANING_BYTES
end

local function valid_record(record)
  if type(record) ~= "table" or type(record.id) ~= "string"
      or not valid_position(record.pos0) or not valid_position(record.pos1)
      or type(record.entries) ~= "table" then
    return false
  end
  for _, entry in ipairs(record.entries) do
    if not valid_entry(entry) then return false end
  end
  return true
end

local function ensure_dir(dir)
  local lfs = lfs_module()
  if not lfs then error("filesystem access is unavailable") end
  if lfs.attributes(dir, "mode") == "directory" then return end
  local ok, err = lfs.mkdir(dir)
  if not ok and lfs.attributes(dir, "mode") ~= "directory" then error(err or "could not create directory") end
end

local function write_atomic(path, text)
  local temporary = path .. ".tmp"
  local file, open_error = io.open(temporary, "wb")
  if not file then error(open_error) end
  local written, write_error = file:write(text)
  file:close()
  if not written then os.remove(temporary); error(write_error) end
  local renamed, rename_error = os.rename(temporary, path)
  if not renamed then
    os.remove(path)
    renamed, rename_error = os.rename(temporary, path)
  end
  if not renamed then os.remove(temporary); error(rename_error) end
end

-- Returns nil when persistence is impossible (no plugin folder or book file).
function Store.new(plugin_path, file, source)
  if type(plugin_path) ~= "string" or plugin_path == "" or type(file) ~= "string"
      or file == "" or not source then
    return
  end
  local dir = DataDir.folder(plugin_path, DIR_NAME)
  return setmetatable({
    dir = dir, path = dir .. "/" .. Store.book_key(file) .. ".lua",
    title = basename(file), source = source,
    records = {}, by_id = {}, dirty = 0, complete = false, skipped = false,
  }, Store)
end

function Store:count()
  return #self.records
end

-- Loads stored results made with the same reading level and output language.
-- A file made with other settings is ignored until new results replace it.
function Store:load(scope)
  self.scope, self.records, self.by_id, self.dirty, self.complete = scope, {}, {}, 0, false
  self.skipped = false
  local file = io.open(self.path, "rb")
  if not file then return false end
  local text = file:read("*a")
  file:close()
  if type(text) ~= "string" or #text > MAX_FILE_BYTES then return false end
  local data = Store.decode(text)
  if not data or data.version ~= FORMAT_VERSION or data.scope ~= scope or type(data.records) ~= "table" then
    return false
  end
  for _, record in ipairs(data.records) do
    if valid_record(record) and not self.by_id[record.id] then
      self.records[#self.records + 1] = record
      self.by_id[record.id] = record
    end
  end
  self.complete = data.complete == true
  self.skipped = data.skipped == true
  return true
end

-- Stored positions that the engine rejects belong to a different version of the
-- book. Drop them and let fresh results overwrite the file.
function Store:reset(reason)
  logger.warn("AI Dictionary Word Sense: discarding saved results: " .. tostring(reason))
  self.records, self.by_id, self.complete = {}, {}, false
  self.dirty = self.dirty + 1
end

-- The stored record covering the given word, if any.
function Store:find(word)
  local records, source = self.records, self.source
  if #records == 0 then return end
  local ok, result = pcall(function()
    local low, high, found = 1, #records, 0
    while low <= high do
      local middle = math.floor((low + high) / 2)
      if source:compare(records[middle].pos0, word.pos0) <= 0 then
        found, low = middle, middle + 1
      else
        high = middle - 1
      end
    end
    for index = found, math.max(1, found - 1), -1 do
      local record = records[index]
      if record and source:compare(word.pos1, record.pos1) <= 0 then return record end
    end
  end)
  if ok then return result end
  self:reset(result)
end

function Store:put(record)
  if not valid_record(record) then return false end
  local stored = { id = record.id, pos0 = record.pos0, pos1 = record.pos1, entries = record.entries }
  local ok, err = pcall(function()
    local records = self.records
    local existing = self.by_id[stored.id]
    if existing then
      for index, candidate in ipairs(records) do
        if candidate == existing then records[index] = stored; return end
      end
    end
    local low, high = 1, #records
    while low <= high do
      local middle = math.floor((low + high) / 2)
      if self.source:compare(records[middle].pos0, stored.pos0) <= 0 then
        low = middle + 1
      else
        high = middle - 1
      end
    end
    table.insert(records, low, stored)
  end)
  if not ok then
    self:reset(err)
    return false
  end
  self.by_id[stored.id] = stored
  self.dirty = self.dirty + 1
  return true
end

-- The reader chose to use Word Sense before the whole book was prepared.
function Store:skip()
  if self.skipped then return end
  self.skipped = true
  self.dirty = self.dirty + 1
end

function Store:unskip()
  if not self.skipped then return end
  self.skipped = false
  self.dirty = self.dirty + 1
end

function Store:mark_complete()
  if self.complete then return end
  self.complete = true
  self.dirty = self.dirty + 1
end

function Store:flush()
  if self.dirty == 0 or not self.scope then return true end
  local ok, err = pcall(function()
    ensure_dir(self.dir)
    write_atomic(self.path, Store.encode({
      version = FORMAT_VERSION, scope = self.scope, title = self.title,
      complete = self.complete, skipped = self.skipped, records = self.records,
    }))
  end)
  if not ok then
    logger.warn("AI Dictionary Word Sense: could not save results: " .. tostring(err))
    return false
  end
  self.dirty = 0
  return true
end

return Store
