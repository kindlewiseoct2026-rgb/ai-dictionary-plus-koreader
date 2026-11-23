-- Run from the repository root: luajit tests/word_sense_store_spec.lua
package.path = "./AI_Dictionary_Plus.koplugin/?.lua;" .. package.path
local warnings = {}
package.loaded.logger = { warn = function(message) warnings[#warnings + 1] = message end }
package.loaded["libs/libkoreader-lfs"] = {
  attributes = function(path, what)
    -- Book files do not exist in this test; report a fixed size for them.
    if what == "size" then return 123 end
    local handle = io.open(path, "r")
    if not handle then return nil end
    handle:close()
    return "directory"
  end,
  mkdir = function(path) return os.execute("mkdir -p '" .. path .. "'") ~= nil end,
}

local Store = require("word_sense_store")

local function temporary_directory()
  local name = os.tmpname()
  os.remove(name)
  assert(os.execute("mkdir -p '" .. name .. "'"))
  return name
end

-- Reflowable-style positions: strings such as "12s" / "12e" ordered by number.
local function order(position) return tonumber(position:match("^%d+")) * 2 + (position:sub(-1) == "e" and 1 or 0) end
local reflowable = { compare = function(_, a, b)
  local left, right = order(a), order(b)
  return left < right and -1 or left > right and 1 or 0
end }
-- Fixed-layout-style positions: { page, index, box }.
local fixed = { compare = function(_, a, b)
  if a.page ~= b.page then return a.page < b.page and -1 or 1 end
  if a.index ~= b.index then return a.index < b.index and -1 or 1 end
  return 0
end }

local function record(first, last, meaning)
  return { id = first .. "s", pos0 = first .. "s", pos1 = last .. "e",
    entries = { { pos0 = first .. "s", pos1 = first .. "e", meaning = meaning or "short meaning" } } }
end
local function word(first, last) return { pos0 = first .. "s", pos1 = (last or first) .. "e" } end

local dir = temporary_directory()

-- Construction needs a plugin folder, a book file and a source.
assert(Store.new(nil, "book.epub", reflowable) == nil)
assert(Store.new(dir, nil, reflowable) == nil)
assert(Store.new(dir, "book.epub", nil) == nil)
local store = assert(Store.new(dir .. "/", "/books/My Book.epub", reflowable))
assert(store.dir == dir .. "/word_sense", "files live in a folder named word_sense: " .. store.dir)
assert(store.path == store.dir .. "/My_Book_epub_123.lua", store.path)
assert(not store:load("Intermediate\nEnglish") and store:count() == 0)

-- Records stay in document order however they arrive; lookups use whole chunks.
assert(store:put(record(201, 300)) and store:put(record(1, 100)) and store:put(record(101, 200)))
assert(not store:put({ id = "x" }) and not store:put({ id = 5 }))
assert(store:count() == 3 and store.records[1].id == "1s" and store.records[3].id == "201s")
assert(store:find(word(1)).id == "1s" and store:find(word(100)).id == "1s")
assert(store:find(word(150, 160)).id == "101s" and store:find(word(300)).id == "201s")
assert(store:find(word(301)) == nil and store:find(word(0)) == nil)
-- A word that straddles a chunk end is not covered by that chunk.
assert(store:find(word(100, 101)) == nil)
-- Replacing a chunk keeps one record per id.
assert(store:put(record(101, 200, "better meaning")) and store:count() == 3)
assert(store:find(word(150)).entries[1].meaning == "better meaning")

-- Nothing reaches the disk until flushed; then the book gets exactly one file.
assert(io.open(store.path, "r") == nil and store.dirty > 0)
store:mark_complete()
assert(store:flush() and store.dirty == 0)
local handle = assert(io.open(store.path, "rb"))
local text = handle:read("*a")
handle:close()
assert(text:sub(1, 7) == "return " and not text:find("function", 1, true))
assert(io.open(store.path .. ".tmp", "r") == nil, "temporary file must be renamed away")

-- A fresh store reads it back, but only for the same level and language.
local reopened = assert(Store.new(dir, "/books/My Book.epub", reflowable))
assert(reopened:load("Intermediate\nEnglish") and reopened:count() == 3 and reopened.complete == true)
assert(reopened:find(word(150)).entries[1].meaning == "better meaning")
local other_level = assert(Store.new(dir, "/books/My Book.epub", reflowable))
assert(not other_level:load("Advanced\nEnglish") and other_level:count() == 0 and not other_level.complete)
local other_language = assert(Store.new(dir, "/books/My Book.epub", reflowable))
assert(not other_language:load("Intermediate\nBengali") and other_language:count() == 0)
-- Results made with other settings stay on disk until new results replace them.
assert(other_level:flush() and reopened:load("Intermediate\nEnglish") and reopened:count() == 3)

-- Fixed-layout positions (tables with word boxes) survive the round trip.
local pdf_store = assert(Store.new(dir, "/books/scan.pdf", fixed))
local pdf_record = {
  id = "1:1", pos0 = { page = 1, index = 1, box = { x = 10.5, y = 20.25, w = 30, h = 12 } },
  pos1 = { page = 1, index = 9, box = { x = 90, y = 20.25, w = 30, h = 12 } },
  entries = { { pos0 = { page = 1, index = 2, box = { x = 1.5, y = 2, w = 3, h = 4 } },
    pos1 = { page = 1, index = 3, box = { x = 5, y = 2, w = 3, h = 4 } },
    positions = { { page = 1, index = 2, box = { x = 1.5, y = 2, w = 3, h = 4 } },
      { page = 1, index = 3, box = { x = 5, y = 2, w = 3, h = 4 } } },
    meaning = "kept as is" } },
}
assert(pdf_store:load("Basic\nEnglish") == false and pdf_store:put(pdf_record) and pdf_store:flush())
local pdf_again = assert(Store.new(dir, "/books/scan.pdf", fixed))
assert(pdf_again:load("Basic\nEnglish"))
local found = assert(pdf_again:find({ pos0 = { page = 1, index = 4 }, pos1 = { page = 1, index = 4 } }))
assert(found.entries[1].positions[2].box.x == 5 and found.pos0.box.x == 10.5 and found.entries[1].meaning == "kept as is")
assert(pdf_again:find({ pos0 = { page = 2, index = 1 }, pos1 = { page = 2, index = 1 } }) == nil)

-- Corrupt, hostile or outdated files are ignored without errors.
local function overwrite(path, contents)
  local file = assert(io.open(path, "wb"))
  file:write(contents)
  file:close()
end
local function loads(contents)
  overwrite(store.path, contents)
  local probe = assert(Store.new(dir, "/books/My Book.epub", reflowable))
  local ok = probe:load("Intermediate\nEnglish")
  return ok, probe
end
assert(not loads("return {"))
assert(not loads("not lua at all"))
assert(not loads("\27Lua"))
assert(not loads("return 42"))
assert(not loads("return { version = 99, scope = 'Intermediate\\nEnglish', records = {} }"))
local hostile = os.tmpname()
os.remove(hostile)
assert(not loads("os.execute('touch " .. hostile .. "') return {}"))
assert(not loads("return { version = 1, scope = 'Intermediate\\nEnglish', records = { os.execute('touch " .. hostile .. "') } }"))
assert(io.open(hostile, "r") == nil, "data files must not run code")
-- Malformed records are skipped, valid ones kept.
local ok, probe = loads("return { version = 1, scope = 'Intermediate\\nEnglish', complete = true, records = {"
  .. "{ id = '1s', pos0 = '1s', pos1 = '9e', entries = { { pos0 = '2s', pos1 = '2e', meaning = 'fine' } } },"
  .. "{ id = 7 }, { id = '5s', pos0 = '5s', pos1 = '6e', entries = { { pos0 = '5s', pos1 = '5e', meaning = 12 } } },"
  .. "{ id = '1s', pos0 = '1s', pos1 = '9e', entries = {} } } }")
assert(ok and probe:count() == 1 and probe.complete and probe:find(word(3)).entries[1].meaning == "fine")

-- Positions the engine rejects mean the book changed: drop the saved data.
local picky = { compare = function(_, a, b)
  if a == "bad" or b == "bad" then error("Invalid Word Sense document position") end
  return reflowable:compare(a, b)
end }
local stale = assert(Store.new(dir, "/books/My Book.epub", picky))
stale.scope = "Intermediate\nEnglish"
stale.records, stale.by_id = { { id = "bad", pos0 = "bad", pos1 = "bad", entries = {} } }, { bad = true }
stale.complete = true
local before = #warnings
assert(stale:find(word(1)) == nil)
assert(stale:count() == 0 and not stale.complete and #warnings == before + 1 and stale.dirty > 0)

-- Unwritable folders fail softly and keep the data pending.
local blocked = assert(Store.new("/proc/does-not-exist", "/books/x.epub", reflowable))
blocked:load("Basic\nEnglish")
assert(blocked:put(record(1, 2)))
local warned = #warnings
assert(blocked:flush() == false and blocked.dirty == 1 and #warnings == warned + 1)

-- Book ids use KOReader's partial MD5 when it is available.
package.loaded.util = { partialMD5 = function(file) return "0123abcdef" end }
assert(Store.book_key("/books/anything.epub") == "0123abcdef")
package.loaded.util = { partialMD5 = function() return nil end }
assert(Store.book_key("/books/Some Book.epub") == "Some_Book_epub_123")
package.loaded.util = nil

os.execute("rm -rf '" .. dir .. "'")
print("word_sense_store_spec: ordering, lookups, round trips, hostile files and stale data passed")
