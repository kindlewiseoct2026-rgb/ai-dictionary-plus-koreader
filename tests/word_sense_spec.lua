-- Run from the repository root: luajit tests/word_sense_spec.lua
-- KOReader geometry, scheduling, JSON decoding and networking are mocked;
-- page extraction, validation, rendering and lifecycle code are real.
package.path = "./AI_Dictionary_Plus.koplugin/?.lua;" .. package.path

local errors, warnings, requests, scheduled, decoded = {}, {}, {}, {}, {}
local draws, frees, encoded = {}, 0, nil
local screen = { width = 600, height = 800 }
function screen:getWidth() return self.width end
function screen:getHeight() return self.height end
function screen:scaleBySize(n) return n * (self.scale or 1) end
package.loaded.device = { screen = screen }
package.loaded["ui/geometry"] = { new = function(_, value) return value or {} end }
package.loaded.logger = {
  err = function(err) errors[#errors + 1] = err end,
  warn = function(err) warnings[#warnings + 1] = err end,
}
package.loaded.json = {
  encode = function(value) encoded = value; return "encoded page" end,
  decode = function(text) assert(decoded[text], "malformed JSON"); return decoded[text] end,
}
local UI = { repaints = 0 }
function UI:scheduleIn(delay, callback) scheduled[callback] = delay end
function UI:unschedule(callback) scheduled[callback] = nil end
function UI:setDirty() self.repaints = self.repaints + 1 end
UI.shown = {}
function UI:show(widget) self.shown[#self.shown + 1] = widget end
function UI:close(widget)
  for index, shown in ipairs(self.shown) do
    if shown == widget then table.remove(self.shown, index); return end
  end
end
package.loaded["ui/uimanager"] = UI
-- Only the progress box counts: other messages shown through the mock are never closed.
local function status_widgets()
  local count = 0
  for _, shown in ipairs(UI.shown) do
    if shown.name == "ai_dictionary_word_sense_status" then count = count + 1 end
  end
  return count
end
package.loaded["ui/gesturerange"] = { new = function(_, value) return value end }
local InputContainer = {}
function InputContainer:extend(class)
  class = class or {}
  class.__index = class
  return setmetatable(class, { __index = self })
end
function InputContainer:new(options)
  local object = setmetatable(options or {}, { __index = self })
  if object.init then object:init() end
  return object
end
package.loaded["ui/widget/container/inputcontainer"] = InputContainer
package.loaded["ffi/blitbuffer"] = { COLOR_WHITE = 0, COLOR_BLACK = 1, COLOR_GRAY = 2 }
package.loaded["ui/font"] = { getFace = function() return {} end }
local Text = {}
function Text:new(options) return setmetatable(options, { __index = self }) end
function Text:getSize()
  local width = self.width or #self.text * 10
  return { w = width, h = math.ceil(#self.text * 10 / width) * 24 }
end
function Text:free() frees = frees + 1 end
function Text:paintTo() end
local Frame = {}
function Frame:new(options) return setmetatable(options, { __index = self }) end
function Frame:getSize()
  local size = self[1]:getSize()
  return { w = size.w + 2 * (self.padding + self.bordersize),
    h = size.h + 2 * (self.padding + self.bordersize) }
end
function Frame:paintTo(_, x, y) self.last_paint = { x = x, y = y } end
function Frame:free() self[1]:free(); frees = frees + 1 end
package.loaded["ui/widget/textwidget"] = Text
package.loaded["ui/widget/textboxwidget"] = Text
package.loaded["ui/widget/container/framecontainer"] = Frame
package.loaded["ui/widget/inputdialog"] = {}
package.loaded["ui/widget/infomessage"] = Text
-- Only directory handling is needed for the saved-results folder; book files are fake.
package.loaded["libs/libkoreader-lfs"] = {
  attributes = function(path, what)
    if what == "size" then return 4096 end
    local handle = io.open(path, "r")
    if not handle then return nil end
    handle:close()
    return "directory"
  end,
  mkdir = function(path) return os.execute("mkdir -p '" .. path .. "'") ~= nil end,
}
package.loaded.gettext = function(text) return text end
package.loaded.ai_query = function(messages, callbacks)
  local request = { messages = messages, callbacks = callbacks, page = encoded, cancels = 0, at = os.time() }
  requests[#requests + 1] = request
  if requests.start_error then error("could not start request") end
  if requests.synchronous_error then callbacks.on_error("connection refused\n\nResponse: ") end
  if requests.synchronous_success then
    decoded.response = { entries = { { first = 1, last = 1, text = encoded.tokens[1].text, meaning = "simple meaning" } } }
    callbacks.on_done("response")
  end
  return function()
    request.cancels = request.cancels + 1
    -- Some transports can still dispatch callbacks when being cancelled.
    if request.on_cancel then request.on_cancel() end
  end
end

local Config = require("configuration_manager")
local configuration
Config.load = function() return Config.normalize(configuration) end
local Page = require("word_sense_page")
local Prompt = require("word_sense_prompt")
local View = require("word_sense_view")
local WordSense = require("word_sense")
local Chunk = require("word_sense_chunk")
local Reflowable = require("word_sense_reflowable")
local Fixed = require("word_sense_fixed")
local Source = require("word_sense_source")
local Cache = require("word_sense_cache")

local function pointer(index, ending) return tostring(index) .. (ending and "e" or "s") end
local function index_of(xp) return tonumber(xp:match("^(%d+)")) end
local function document(pages)
  local doc = { file = "book.EPUB", page = 1, hash = 1, texts = {}, ranges = {}, reads = 0, breaks = {} }
  for i, words in ipairs(pages) do
    doc.ranges[i] = { first = #doc.texts + 1 }
    doc.breaks[#doc.texts + 1] = true
    for _, word in ipairs(words) do doc.texts[#doc.texts + 1] = word end
    doc.ranges[i].last = #doc.texts
  end
  function doc:getCurrentPage() return self.page end
  function doc:getCurrentPos() return self.page * 100 end
  function doc:getDocumentRenderingHash() return self.hash end
  function doc:getPageCount() return #self.ranges end
  function doc:getVisiblePageNumberCount() return self.visible_pages or 1 end
  function doc:getNextPage(p) return p < #self.ranges and p + 1 or 0 end
  function doc:getPageFromXPointer(xp)
    local index = index_of(xp)
    for p, range in ipairs(self.ranges) do
      if index >= range.first and index <= range.last then return p end
    end
    error("invalid pointer")
  end
  function doc:getPageXPointer(p) return pointer(self.ranges[p].first) end
  function doc:getXPointer() return self:getPageXPointer(self.page) end
  function doc:getNextVisibleWordEnd(xp)
    local index = index_of(xp) + (xp:sub(-1) == "e" and 1 or 0)
    if index <= #self.texts then return pointer(index, true) end
  end
  function doc:getPrevVisibleWordStart(xp) return pointer(index_of(xp)) end
  function doc:getPrevVisibleWordEnd(xp)
    local index = index_of(xp) - 1
    if index >= 1 then return pointer(index, true) end
  end
  function doc:compareXPointers(a, b)
    local av = index_of(a) * 2 + (a:sub(-1) == "e" and 1 or 0)
    local bv = index_of(b) * 2 + (b:sub(-1) == "e" and 1 or 0)
    return av < bv and 1 or av > bv and -1 or 0
  end
  function doc:isXPointerInCurrentPage(xp)
    local index, range = index_of(xp), self.ranges[self.page]
    return index >= range.first and index <= range.last
  end
  function doc:getTextFromXPointers(a, b)
    assert(not self.selection_active, "extraction must never clear a live selection")
    self.reads = self.reads + 1
    local text = {}
    for i = index_of(a), index_of(b) do
      if #text > 0 then text[#text + 1] = self.breaks[i] and "\n" or (self.joiners and self.joiners[i] or " ") end
      text[#text + 1] = self.texts[i]
    end
    return table.concat(text)
  end
  function doc:getScreenBoxesFromPositions(a, b)
    self.last_boxes = { a, b }
    if self.box_error then error("bad geometry") end
    if self.boxes then return self.boxes end
    local range = self.ranges[self.page]
    local offset = math.max(0, index_of(a) - range.first)
    return { { x = (offset % 50 + 1) * 10, y = 100 + math.floor(offset / 50) * 24,
      w = (index_of(b) - index_of(a) + 1) * 20, h = 20 } }
  end
  return doc
end

local function make_ui(doc)
  local ui = {
    document = doc, view = { view_mode = "page", view_modules = {} }, highlight = {},
    _zones = {
      readerhighlight_tap = { def = { ges = "tap" } },
      readerlink_tap = { def = { ges = "tap" } },
      readermenu_tap = { def = { ges = "tap" } },
      tap_forward = { def = { ges = "tap" } },
      readerhighlight_hold = { def = { ges = "hold" } },
    },
  }
  function ui.view:registerViewModule(name, module) self.view_modules[name] = module end
  function ui:registerTouchZones(zones)
    for _, zone in ipairs(zones) do self._zones[zone.id] = { def = zone, handler = zone.handler } end
  end
  function ui:unRegisterTouchZones(zones)
    for _, zone in ipairs(zones) do self._zones[zone.id] = nil end
  end
  function ui.highlight:onTap() self.native_taps = (self.native_taps or 0) + 1; return self.native_handled end
  function ui.highlight:onHold(arg, ges)
    self.native_holds = (self.native_holds or 0) + 1
    self.last_hold = { arg, ges }
    self.hold_pos = ges.pos
    doc.selection_active = true
    return "native hold"
  end
  -- KOReader's per-book settings. Word Sense is on for the book unless a test says otherwise.
  ui.doc_settings = {
    enabled = true, flushes = 0,
    isTrue = function(self, key) return key == "ai_dictionary_word_sense" and self.enabled end,
    makeTrue = function(self, key) assert(key == "ai_dictionary_word_sense"); self.enabled = true end,
    delSetting = function(self, key) assert(key == "ai_dictionary_word_sense"); self.enabled = false end,
    flush = function(self) self.flushes = self.flushes + 1 end,
  }
  return ui
end

local function start(pages)
  local ui = make_ui(document(pages or { { "bear", "give", "way", "bear" }, { "rare", "word" } }))
  local controller = assert(WordSense.new { ui = ui })
  controller:refresh()
  return controller, ui
end

local function tick()
  local callback = next(scheduled)
  assert(callback, "expected scheduled work")
  scheduled[callback] = nil
  callback()
end

local function drain()
  for _ = 1, 100 do
    if not next(scheduled) then return end
    tick()
  end
  error("work did not finish")
end

local function complete(request, entries)
  entries = entries or { { first = 1, last = 1, meaning = "large forest animal" } }
  for _, entry in ipairs(entries) do
    if entry.text == nil then
      local parts = {}
      for i = entry.first, entry.last do parts[#parts + 1] = request.page.tokens[i].text end
      entry.text = table.concat(parts, " ")
    end
  end
  local response_key = "response " .. tostring(request)
  decoded[response_key] = { entries = entries }
  request.callbacks.on_done(response_key)
end

local function active_count(controller)
  local count = 0
  for _ in pairs(controller.requests.jobs) do count = count + 1 end
  return count
end

local function many_pages(count)
  local pages = {}
  for i = 1, count do pages[i] = { "page" .. i } end
  return pages
end

local function turn(controller, ui, page)
  ui.document.page = page
  controller:refresh()
  drain()
end

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name, fn } end

test("reading level defaults and native choice list", function()
  assert(Config.normalize({}).word_sense_level == "Intermediate")
  assert(Config.normalize({ word_sense_level = "invalid" }).word_sense_level == "Intermediate")
  local plugin = { saveConfiguration = function(_, config) configuration = config; return true end }
  local items = require("settings_menu").get_items(plugin)
  local choices
  for _, item in ipairs(items) do
    if item.text:find("Word Sense reading level", 1, true) then choices = item.sub_item_table end
  end
  assert(choices and #choices == 3)
  for i, level in ipairs({ "Basic", "Intermediate", "Advanced" }) do
    assert(choices[i].text == level and choices[i].radio)
    choices[i].callback()
    assert(configuration.word_sense_level == level and choices[i].checked_func())
  end
end)

test("the old global activation setting is ignored and never saved", function()
  assert(Config.normalize({}).word_sense_active == nil)
  local saved_text = Config.serialize_configuration(Config.normalize({ word_sense_active = true }))
  assert(not saved_text:find("word_sense_active", 1, true))
  local ui = make_ui(document({ { "word" } }))
  ui.doc_settings.enabled = false
  configuration = { word_sense_active = true }
  assert(not WordSense.new { ui = ui }, "a global setting must not switch Word Sense on for every book")
end)

test("disabled supported books install no hooks and schedule no scans", function()
  configuration = {}
  local ui = make_ui(document({ { "word" } }))
  local tap, hold = ui.highlight.onTap, ui.highlight.onHold
  ui.doc_settings.enabled = false
  assert(not WordSense.new { ui = ui })
  ui.doc_settings = nil -- file manager: no open book
  assert(not WordSense.new { ui = ui })
  assert(ui.highlight.onTap == tap and ui.highlight.onHold == hold)
  assert(not next(ui.view.view_modules) and not next(scheduled))
  assert(ui.document.reads == 0 and #requests == 0)
end)

test("the activation menu item is a per-book toggle", function()
  configuration = {}
  local ui = make_ui(document({ { "word" } }))
  ui.doc_settings.enabled = false
  local updates = 0
  local plugin = { ui = ui, updateWordSense = function() updates = updates + 1 end,
    saveConfiguration = function() return true end }
  local toggle
  for _, item in ipairs(require("settings_menu").get_items(plugin)) do
    if item.text == "Word Sense for this book" then toggle = item end
  end
  assert(toggle and toggle.enabled_func() and not toggle.checked_func() and not toggle.sub_item_table)
  toggle.callback()
  assert(ui.doc_settings.enabled and toggle.checked_func() and updates == 1 and ui.doc_settings.flushes == 1)
  toggle.callback()
  assert(not ui.doc_settings.enabled and not toggle.checked_func() and updates == 2)
  -- Another book is a separate setting and stays off.
  local other = make_ui(document({ { "word" } }))
  other.doc_settings.enabled = false
  plugin.ui = other
  assert(not toggle.checked_func())
  -- Without an open book (file manager) the item is unavailable and does nothing.
  plugin.ui = {}
  assert(not toggle.enabled_func() and not toggle.checked_func())
  toggle.callback()
  assert(updates == 2)
end)

test("saved activation starts and stops the open reader without restarting", function()
  -- Only dependencies unrelated to Word Sense are stubbed; the plugin's
  -- configuration save, reader events, controller and settings menu are real.
  local stubs = {
    ["ui/widget/container/inputcontainer"] = { new = function(_, value) return value end },
    actions = {}, context = {}, long_press = {}, lookups_report_ui = {},
    query_session = {}, updater = {},
  }
  local originals = {}
  for name, stub in pairs(stubs) do
    originals[name], package.loaded[name] = package.loaded[name], stub
  end
  local ok, Main = pcall(assert(loadfile("./AI_Dictionary_Plus.koplugin/main.lua")))
  for name in pairs(stubs) do package.loaded[name] = originals[name] end
  assert(ok, Main)

  local original_save = Config.save
  Config.save = function(_, value) configuration = value; return true end
  configuration = {}
  local ui = make_ui(document({ { "rare", "word" } }))
  ui.doc_settings.enabled = false
  local tap, hold = ui.highlight.onTap, ui.highlight.onHold
  local plugin = setmetatable({ ui = ui }, { __index = Main })
  plugin:onReaderReady()
  plugin:onPageUpdate()
  assert(not plugin.word_sense and not next(scheduled) and #requests == 0)

  local toggle
  for _, item in ipairs(plugin:getSettingsMenuItems()) do
    if item.text == "Word Sense for this book" then toggle = item end
  end
  toggle.callback()
  local controller = assert(plugin.word_sense)
  drain()
  local request = assert(requests[1])
  assert(ui.highlight.onTap ~= tap and request.cancels == 0)
  assert(plugin:saveConfiguration(configuration) and plugin.word_sense == controller)
  drain()
  assert(#requests == 1)

  Config.save = function() return false, "read-only configuration" end
  assert(not plugin:saveConfiguration({}))
  assert(plugin.word_sense == controller and request.cancels == 0)
  Config.save = function(_, value) configuration = value; return true end

  toggle.callback()
  assert(not plugin.word_sense and controller.closed and request.cancels == 1)
  assert(ui.highlight.onTap == tap and ui.highlight.onHold == hold)
  assert(not next(ui.view.view_modules) and not next(scheduled))
  complete(request)
  plugin:onPageUpdate()
  plugin:onResume()
  assert(#controller.overlay.boxes == 0 and not next(scheduled) and #requests == 1)

  toggle.callback()
  assert(plugin.word_sense and plugin.word_sense ~= controller)
  drain()
  assert(#requests == 2)
  complete(requests[2])
  controller = plugin.word_sense
  assert(#controller.overlay.boxes > 0)
  toggle.callback()
  assert(controller.closed and #controller.overlay.boxes == 0 and not plugin.word_sense)
  Config.save = original_save
end)

test("unsupported documents do not install hooks or schedule requests", function()
  local ui = make_ui(document({ { "word" } }))
  for _, file in ipairs({ "book.fb2", "book.azw", "book.cbz", "book.epub.zip", "book.epub.tmp", "book" }) do
    ui.document.file = file
    assert(not WordSense.new { ui = ui })
  end
  ui.document.file, ui.document.getNextVisibleWordEnd = "book.epub", false
  assert(not WordSense.new { ui = ui })
  assert(not next(scheduled) and not next(ui.view.view_modules))
end)

test("Word Sense model setting is optional, editable and saved as a string", function()
  assert(Config.normalize({}).word_sense_model == "")
  for _, invalid in ipairs({ false, {}, 12, " \t ", "bad\nmodel" }) do
    assert(Config.normalize({ word_sense_model = invalid }).word_sense_model == "")
  end
  local model = "deepseek/deepseek-v4.1-flash"
  local normalized = Config.normalize({ word_sense_model = "  " .. model .. "  " })
  assert(normalized.word_sense_model == model)
  local saved = assert(loadstring(Config.serialize_configuration(normalized)))()
  assert(saved.word_sense_model == model)
  assert(Config.display_value("word_sense_model", "") == "Use default text model")
  local edited
  local items = require("settings_menu").get_items({
    editConfigurationValue = function(_, key, literal) edited = { key = key, literal = literal } end,
  })
  for _, item in ipairs(items) do
    if item.text == "Word Sense model: Use default text model" then item.callback() end
  end
  assert(edited and edited.key == "word_sense_model" and edited.literal == false)
end)

test("visible extraction keeps first and last words and exact occurrences", function()
  local doc = document({ { "bear", "give", "way", "bear" }, { "unseen" } })
  local page = Page.new(make_ui(doc))
  assert(not Page.step(doc, page, 2) and #page.words == 2)
  assert(not Page.step(doc, page, 2) and #page.words == 4)
  assert(Page.step(doc, page, 2) and #page.words == 4)
  assert(page.words[1].pos0 == "1s" and page.words[4].pos1 == "4e")
  assert(Page.context(doc, page) == "bear give way bear")
  doc.page = 2
  page = Page.new(make_ui(doc))
  assert(Page.step(doc, page, 24) and #page.words == 1) -- final book page
end)

test("parser validates definitions, phrase spans, overlap and repeated words", function()
  local doc = document({ { "bear", "give", "way", "bear" } })
  local page = Page.new(make_ui(doc)); assert(Page.step(doc, page, 24))
  decoded.valid = { entries = {
    { first = 2, last = 3, text = "give way", meaning = "  stop\nresisting " },
    { first = 1, last = 1, text = "bear", meaning = "forest animal" },
    { first = 4, last = 4, text = "bear", meaning = "endure" },
    { first = 2, last = 2, text = "give", meaning = "overlap" },
    { first = 5, last = 5, meaning = "out of bounds" },
    { first = 1.5, last = 2, meaning = "fraction" },
    { first = 1, last = 1, meaning = "one two three four five six" },
  } }
  local entries = assert(Prompt.parse("```json\nvalid\n```", page.words, Reflowable.new(make_ui(doc))))
  assert(#entries == 3 and entries[1].meaning == "stop resisting")
  assert(entries[1].pos0 == "2s" and entries[1].pos1 == "3e")
  assert(entries[2].pos0 == "1s" and entries[3].pos0 == "4s")
  assert(not Prompt.parse("malformed", page.words))
  assert(not Prompt.parse(string.rep("x", 65537), page.words))
  assert(not Prompt.validate({ entries = { first = 1, last = 1, meaning = "wrong shape" } }, page.words))
  assert(not Prompt.validate({ entries = { { first = -1, last = 1, meaning = "bad" } } }, page.words))
  assert(not Prompt.validate({ entries = { { first = 1, last = 1, meaning = "one two three four five six" } } }, page.words))
  assert(#assert(Prompt.validate({ entries = {} }, page.words)) == 0)
  local messages = Prompt.messages(page, "context", "Basic", "Persian")
  assert(messages[1].content:find("Persian", 1, true) and messages[1].content:find("basic proficiency", 1, true))
  assert(encoded.tokens[4].id == 4 and encoded.tokens[4].text == "bear")
  assert(messages[1].content:find('"text":"give way"', 1, true))
end)

test("unmatched selections are cached without underlines or retry loops", function()
  local controller, ui = start({ { "bear" } }); drain()
  complete(requests[1], { { first = 1, last = 1, text = "missing", meaning = "no match" } })
  drain()
  assert(#controller.overlay.boxes == 0 and #controller.cache.order == 1 and #warnings == 0)
  controller:refresh(true); drain()
  assert(#requests == 1 and #controller.overlay.boxes == 0)
  controller:close()
end)

test("verification waits for selection and cancelled completed responses stay discarded", function()
  local controller, ui = start({ { "bear" } }); drain()
  ui.document.selection_active, ui.highlight.hold_pos = true, {}
  local reads = ui.document.reads
  complete(requests[1]); tick()
  requests[1].callbacks.on_error("late transport error")
  assert(ui.document.reads == reads and #controller.overlay.boxes == 0 and active_count(controller) == 1)
  ui.document.selection_active, ui.highlight.hold_pos = false, nil
  drain()
  assert(#controller.overlay.boxes == 1 and active_count(controller) == 0)
  controller:close()

  controller, ui = start({ { "bear" } }); drain()
  ui.document.selection_active, ui.highlight.hold_pos = true, {}
  complete(requests[#requests]); tick()
  controller:suspend()
  ui.document.selection_active, ui.highlight.hold_pos = false, nil
  assert(not next(scheduled) and active_count(controller) == 0)
  controller:close()
end)

test("priority protects nearer work, and cancel callbacks cannot release replacement jobs", function()
  local pool = require("word_sense_requests").new(2)
  local first = assert(pool:reserve("first", 10, 10))
  local second = assert(pool:reserve("second", 11, 10))
  assert(not pool:reserve("distant", 20, 10))
  assert(not pool:reserve("first", 10, 10))
  first.cancel = function() assert(not pool:remove(first)) end
  assert(pool:reserve("replacement", 12, 12))
  assert(not pool.jobs.first and pool.jobs.second == second)
  assert(not pool:remove(first))
  local replacement = assert(pool:reserve("first", 10, 10))
  assert(not pool:remove(first) and pool.jobs.first == replacement)
  pool:cancel_all(); assert(not next(pool.jobs))
end)

test("tap bubbles preserve native taps, saved highlights and long presses", function()
  local controller, ui = start(); drain(); complete(requests[1])
  local gesture = { pos = { x = 15, y = 110 } }
  assert(ui.highlight:onTap(nil, gesture) == true and controller.overlay.popup)
  local hold_gesture = { pos = { x = 15, y = 110 } }
  assert(ui.highlight:onHold("argument", hold_gesture) == "native hold")
  assert(not controller.overlay.popup and ui.highlight.native_holds == 1)
  assert(ui.highlight.last_hold[1] == "argument" and ui.highlight.last_hold[2] == hold_gesture)
  ui.highlight.hold_pos = nil; ui.document.selection_active = false
  ui.highlight.native_handled = "saved highlight"
  assert(ui.highlight:onTap(nil, gesture) == "saved highlight" and not controller.overlay.popup)
  ui.highlight.native_handled = nil
  assert(not ui.highlight:onTap(nil, { pos = { x = 500, y = 500 } }))
  controller:close()
end)

test("an outside tap dismisses the bubble before other reader tap zones", function()
  local controller, ui = start(); drain(); complete(requests[1])
  assert(requests[1].callbacks.feature == "word_sense")
  assert(requests[1].callbacks.reasoning_effort == nil and requests[1].callbacks.provider_sort == nil)
  local word = { pos = { x = 15, y = 110 } }
  local outside = { pos = { x = 500, y = 500 } }
  assert(ui.highlight:onTap(nil, word) and controller.overlay.popup)
  local zone = assert(ui._zones.ai_dictionary_word_sense_popup_tap)
  local overrides = {}
  for _, id in ipairs(zone.def.overrides) do overrides[id] = true end
  assert(overrides.readerhighlight_tap and overrides.readerlink_tap
    and overrides.readermenu_tap and overrides.tap_forward)
  assert(not overrides.readerhighlight_hold and zone.def.ges == "tap")
  assert(zone.def.screen_zone.ratio_w == 1 and zone.def.screen_zone.ratio_h == 1)
  local repaints = UI.repaints
  assert(zone.handler(outside) == true and not controller.overlay.popup)
  assert(UI.repaints > repaints, "dismissal must erase the painted bubble")
  assert(not zone.handler(outside), "normal reader taps must pass through when no bubble is open")

  -- Even the highlight-wrapper fallback must dismiss before a saved highlight.
  assert(ui.highlight:onTap(nil, word))
  ui.highlight.native_handled = "saved highlight"
  assert(ui.highlight:onTap(nil, outside) == true and not controller.overlay.popup)
  assert(ui.highlight:onTap(nil, outside) == "saved highlight")
  ui.highlight.native_handled = nil

  -- A later-installed zone is covered when the next bubble opens.
  ui._zones.custom_tap = { def = { ges = "tap" } }
  assert(ui.highlight:onTap(nil, word))
  zone = ui._zones.ai_dictionary_word_sense_popup_tap
  local found
  for _, id in ipairs(zone.def.overrides) do if id == "custom_tap" then found = true end end
  assert(found)
  assert(zone.handler(word) == true and controller.overlay.popup, "marked-word taps can switch definitions")
  controller:close()
  assert(not ui._zones.ai_dictionary_word_sense_popup_tap and ui._zones.readerlink_tap)
end)

test("wrapped phrase boxes are clipped and bad geometry is isolated", function()
  local doc = document({ { "give", "way" } })
  local entry = { pos0 = "1s", pos1 = "2e", meaning = "stop resisting" }
  doc.boxes = {
    { x = 550, y = 100, w = 80, h = 20 }, { x = 10, y = 125, w = 30, h = 20 },
    { x = -80, y = 100, w = 20, h = 20 }, { x = 10, y = 900, w = 20, h = 20 },
  }
  local boxes = Page.boxes(doc, { entry }, 600, 800)
  assert(#boxes == 2 and boxes[1].box.w == 50 and boxes[1].entry == boxes[2].entry)
  doc.box_error = true; assert(#Page.boxes(doc, { entry }, 600, 800) == 0)
end)

test("bubble placement respects scaled screen padding and painting does not query or select", function()
  local view = View.new()
  local entry = { meaning = "very lengthy contextual vocabulary definition" }
  -- The screen gap is deliberately tunable in the script, not fixed by this test.
  local view_file = assert(io.open("./AI_Dictionary_Plus.koplugin/word_sense_view.lua", "r"))
  local view_source = view_file:read("*a")
  view_file:close()
  local popup_padding = assert(tonumber(view_source:match("local POPUP_SCREEN_PADDING%s*=%s*(%d+)")))
  for _, scale in ipairs({ 1, 2 }) do
    screen.scale = scale
    local gap = popup_padding * scale
    for _, box in ipairs({
      { x = 0, y = 0, w = 20, h = 20 }, { x = 580, y = 0, w = 20, h = 20 },
      { x = 0, y = 775, w = 20, h = 20 }, { x = 580, y = 775, w = 20, h = 20 },
    }) do
      view.boxes = { { box = box, entry = entry } }
      assert(view:tap({ x = box.x + 1, y = box.y + 1 }))
      local bubble = view.popup
      assert(bubble.x >= gap and bubble.y >= gap
        and bubble.x + bubble.w <= 600 - gap and bubble.y + bubble.h <= 800 - gap)
      assert(box.x == 0 and bubble.x == gap or box.x == 580 and bubble.x + bubble.w == 600 - gap)
      view:paint({ paintRect = function(_, x, y, w, h, color)
        assert(x >= 0 and y >= 0 and x + w <= 600 and y + h <= 800)
        if color ~= package.loaded["ffi/blitbuffer"].COLOR_GRAY then
          assert(x >= gap and y >= gap and x + w <= 600 - gap and y + h <= 800 - gap,
            "the popup tail must also respect the screen padding")
        end
        draws[#draws + 1] = { x, y, w, h }
      end }, 0, 0)
      assert(view:tap({ x = bubble.x + 1, y = bubble.y + 1 }) and not view.popup)
    end
  end
  screen.scale = nil
  assert(#draws > 0 and frees > 0 and #requests == 0)
  view.boxes = { { box = { x = 0, y = 0, w = 20, h = 1 }, entry = entry } }
  view:paint({ paintRect = function() error("clipped text has no visible underline") end }, 0, 0)
end)

-- Chunk and document-range lifecycle regression checks.

local function vocabulary(count, prefix)
  local words = {}
  for i = 1, count do words[i] = (prefix or "word") .. i end
  return words
end

local function chunk_at(doc, index)
  local source = Reflowable.new(make_ui(doc))
  local chunk = Chunk.new(source, assert(source:word(pointer(index, true))))
  for _ = 1, 10000 do
    local done, err = Chunk.step(chunk)
    assert(not err, err)
    if done then return chunk end
  end
  error("chunk extraction stalled")
end

local function paragraph_pages(count)
  local pages = {}
  for i = 1, count do pages[i] = vocabulary(301, "p" .. i .. "w") end
  return pages
end

local function ready(pages)
  local controller, ui = start(pages or paragraph_pages(5))
  drain()
  return controller, ui
end

test("eligible reflowable formats share extraction caching and layout handling", function()
  for _, file in ipairs({ "book.epub", "book.EPUB", "book.epub3", "book.EPUB3",
    "book.kepub", "book.KEPUB", "book.kepub.epub", "book.KEPUB.EPUB",
    "book.mobi", "book.MOBI", "book.txt", "book.TXT", "book.htm", "book.HTM",
    "book.html", "book.HTML", "book.xhtml", "book.XHTML" }) do
    local doc = document({ { "difficult", "give", "way" } })
    doc.file = file
    local ui = make_ui(doc)
    local before = #requests
    local controller = assert(WordSense.new { ui = ui }, file)
    assert(getmetatable(controller.source) == Reflowable, file)
    controller:refresh(); drain()
    assert(#requests == before + 1 and #requests[#requests].page.tokens == 3, file)
    complete(requests[#requests], { { first = 2, last = 3, meaning = "stop resisting" } }); drain()
    assert(#controller.overlay.boxes == 1 and controller.overlay.boxes[1].entry.pos0 == "2s", file)
    doc.hash = 2
    controller:layout_changed(); drain()
    assert(#requests == before + 1 and #controller.overlay.boxes == 1, file)
    controller:close()
  end
end)

test("eligible extensions do not bypass missing text or view capabilities", function()
  for _, method in ipairs({ "getNextVisibleWordEnd", "getPrevVisibleWordEnd",
    "getPageFromXPointer", "compareXPointers", "getTextFromXPointers", "getScreenBoxesFromPositions" }) do
    local ui = make_ui(document({ { "word" } }))
    ui.document.file = "book.mobi"
    ui.document[method] = false
    assert(not Source.new(ui) and not WordSense.new { ui = ui }, method)
    assert(not next(ui.view.view_modules))
  end
  local ui = make_ui(document({ { "word" } }))
  ui.document.file = "book.kepub"
  ui.view.registerViewModule = false
  assert(not Source.new(ui))
  assert(not Source.new(nil) and not Source.new({}) and not Source.new({ document = {} }))
  assert(#requests == 0 and not next(scheduled))
end)

local function settle()
  for _ = 1, 100 do
    drain()
    local active
    for _, request in ipairs(requests) do
      if not request.done and request.cancels == 0 then active = request; break end
    end
    if not active then return end
    active.done = true
    complete(active)
  end
  error("request loop")
end

test("chunks include full paragraphs until strictly over 300 words", function()
  local doc = document({ vocabulary(150), vocabulary(150), { "extra" }, { "excluded" } })
  local chunk = chunk_at(doc, 1)
  assert(chunk.count == 301 and #chunk.words == 301 and chunk.pos1 == "301e")
  assert(chunk.context:find("\n", 1, true) and not chunk.context:find("excluded", 1, true))
  doc = document({ vocabulary(125), vocabulary(125), vocabulary(125), { "excluded" } })
  chunk = chunk_at(doc, 1)
  assert(chunk.count == 375 and #chunk.words == 375)
  -- A short final book passage still includes its one complete paragraph.
  chunk = chunk_at(document({ { "last", "paragraph" } }), 2)
  assert(chunk.count == 2 and chunk.pos0 == "1s")
end)

test("one oversized paragraph is never split at a word or page limit", function()
  local doc = document({ vocabulary(1600), { "excluded" } })
  local chunk = chunk_at(doc, 900)
  assert(chunk.count == 1600 and #chunk.words == 1600)
  assert(chunk.pos0 == "1s" and chunk.pos1 == "1600e")
end)

test("inline formatting fragments do not inflate the 300-word threshold", function()
  local first = { "hel", "lo" }
  for i = 1, 299 do first[#first + 1] = "word" .. i end
  local doc = document({ first, { "extra" }, { "excluded" } })
  doc.joiners = { [2] = "" }
  local chunk = chunk_at(doc, 1)
  assert(chunk.count == 301 and #chunk.words == 302)
  assert(chunk.context:sub(1, 5) == "hello" and chunk.pos1 == "302e")
end)

test("a paragraph spanning displayed pages is analyzed once with full context", function()
  local controller, ui = start({ { "give" }, { "way" }, vocabulary(301), { "after" } })
  ui.document.breaks[2], ui.document.breaks[3] = nil, nil
  drain()
  assert(#requests == 1 and #requests[1].page.tokens == 303)
  complete(requests[1], { { first = 1, last = 2, meaning = "stop resisting" } })
  drain() -- the next chunk is a separate query
  assert(#requests == 2)
  local scans = #requests
  turn(controller, ui, 2)
  assert(#requests == scans and #controller.overlay.boxes > 0)
  assert(controller.overlay.boxes[1].entry.pos0 == "1s" and controller.overlay.boxes[1].entry.pos1 == "2e")
  turn(controller, ui, 3)
  assert(#requests == scans, "reuse the whole paragraph on its third displayed page")
  controller:close()
end)

test("phrases spanning multiple pages remain visible between their endpoints", function()
  local doc = document({ { "a" }, { "long" }, { "phrase" } })
  doc.page = 2
  local source = Reflowable.new(make_ui(doc))
  local boxes = source:boxes({ { pos0 = "1s", pos1 = "3e", meaning = "simple meaning" } }, 600, 800)
  assert(#boxes == 1, "the middle page also needs the phrase underline")
end)

test("long paragraphs receive current-page priority even when starting far behind it", function()
  local controller, ui = start(many_pages(10))
  ui.document.page = 8
  assert(controller:priority_page({ pos0 = "1s", pos1 = "8e" }) == 8)
  assert(controller:priority_page({ pos0 = "9s", pos1 = "10e" }) == 9)
  assert(controller:priority_page({ pos0 = "1s", pos1 = "3e" }) == 3)
  controller:close()
end)

test("prefetch processes two chunks sequentially without turning pages", function()
  local controller, ui = ready()
  assert(#requests == 1 and #requests[1].page.tokens == 301)
  complete(requests[1]); drain(); assert(#requests == 2)
  complete(requests[2]); drain(); assert(#requests == 3)
  complete(requests[3]); drain()
  assert(#requests == 3 and active_count(controller) == 0 and ui.document.page == 1)
  assert(#controller.overlay.boxes == 1)
  turn(controller, ui, 2)
  assert(#controller.overlay.boxes == 1 and #requests == 4)
  assert(requests[4].page.tokens[1].text == "p4w1")
  controller:close()
end)

test("every visible chunk is processed before speculative chunks", function()
  local controller, ui = start({ vocabulary(903), vocabulary(301) })
  ui.document.breaks[302], ui.document.breaks[603] = true, true
  drain()
  assert(#requests[1].page.tokens == 301)
  complete(requests[1]); drain()
  assert(requests[2].page.tokens[1].text == "word302")
  complete(requests[2]); drain()
  assert(requests[3].page.tokens[1].text == "word603")
  complete(requests[3]); drain()
  assert(requests[4].page.tokens[1].text == "word1" and #controller.overlay.boxes == 3)
  controller:close()
end)

test("more than 40 pages remain annotated through repeated cache evictions", function()
  local controller, ui = ready(paragraph_pages(45))
  for page = 1, 43 do
    turn(controller, ui, page)
    settle()
    assert(#controller.overlay.boxes == 1, "missing visible definition on page " .. page)
    assert(controller.overlay.boxes[1].entry.pos0 == pointer(ui.document.ranges[page].first))
    assert(#controller.cache.order <= 16)
  end
  local count = #requests
  turn(controller, ui, 1); settle()
  assert(#requests > count and #controller.overlay.boxes == 1, "evicted content must query again")
  controller:close()
end)

test("cache uses recent access and protects visible ranges from late results", function()
  local source = Reflowable.new(make_ui(document({ vocabulary(30) })))
  local cache = Cache.new(16, source)
  local function put(i, protected)
    cache:put({ id = pointer(i), pos0 = pointer(i), pos1 = pointer(i, true) }, {}, protected)
  end
  for i = 1, 16 do put(i) end
  assert(cache:find({ pos0 = "1s", pos1 = "1e" }))
  put(17)
  assert(cache.records["1s"] and not cache.records["2s"])
  for i = 18, 30 do put(i, { ["1s"] = true }) end
  assert(cache.records["1s"] and #cache.order == 16)
end)

test("dense visible text can exceed the cache budget without a prefetch loop", function()
  local controller, ui = start({ vocabulary(903), vocabulary(301) })
  ui.document.breaks[302], ui.document.breaks[603] = true, true
  controller.cache.limit = 2
  settle()
  assert(#requests == 3 and #controller.cache.order == 3 and #controller.overlay.boxes == 3)
  assert(not next(scheduled), "speculative chunks must not be queried and immediately evicted")
  turn(controller, ui, 2); settle()
  assert(#requests == 4 and #controller.cache.order == 2 and #controller.overlay.boxes == 1)
  controller:close()
end)

test("scroll position and two-page spread changes reuse document ranges", function()
  local controller, ui = ready(paragraph_pages(5))
  settle()
  ui.view.view_mode = "scroll"
  controller:layout_changed(); drain()
  assert(#requests == 3 and #controller.overlay.boxes == 1)
  ui.view.view_mode = "page"
  ui.document.visible_pages = 2
  controller:layout_changed(); drain()
  assert(#requests == 4, "the spread is covered and only its following chunk needs a query")
  controller:close()
end)

test("font changes reuse completed and in-flight meanings and rebuild geometry", function()
  local controller, ui = ready()
  complete(requests[1]); drain()
  local active = requests[2]
  ui.document.hash = 2
  ui.document.boxes = { { x = 75, y = 200, w = 45, h = 24 } }
  controller:layout_changed(); drain()
  assert(#requests == 2 and active.cancels == 0 and controller.overlay.boxes[1].box.x == 75)
  complete(active); drain()
  assert(#requests == 3 and #controller.overlay.boxes == 1)
  ui.document.hash = 3
  controller:settings_changed(); drain()
  assert(#requests == 3 and requests[3].cancels == 0)
  controller:close()
end)

test("repagination exposes cached occurrences without a new query", function()
  local controller, ui = ready(paragraph_pages(3))
  complete(requests[1]); drain()
  -- Change a page boundary, keeping document positions intact.
  ui.document.ranges[1].last = 150
  ui.document.ranges[2].first = 151
  ui.document.page, ui.document.hash = 2, 2
  controller:layout_changed(); drain()
  assert(#requests == 2 and requests[2].cancels == 0)
  complete(requests[2], { { first = 1, last = 1, meaning = "contextual meaning" } }); drain()
  assert(#controller.overlay.boxes == 1 and #requests == 3)
  controller:close()
end)

test("meaning settings cancel all requests and reject late callbacks", function()
  local controller, ui = ready()
  for page = 2, 5 do turn(controller, ui, page) end
  assert(active_count(controller) == 5)
  configuration.word_sense_model, configuration.output_language = "different-model", "French"
  controller:settings_changed()
  for _, request in ipairs(requests) do
    assert(request.cancels == 1)
    complete(request)
  end
  assert(#controller.overlay.boxes == 0 and #controller.cache.order == 0)
  drain()
  assert(#requests == 6 and requests[6].callbacks.feature == "word_sense")
  assert(controller.configuration.word_sense_model == "different-model")
  assert(requests[6].messages[1].content:find("French", 1, true))
  controller:close()
end)

test("reasoning and JSON changes invalidate scans while unrelated feature settings do not", function()
  local controller, ui = start(); drain()
  local first = requests[1]
  configuration.dictionary_reasoning_effort = "high"
  configuration.explain_parameters_json = '{"provider":{"sort":"latency"}}'
  controller:settings_changed(); drain()
  assert(#requests == 1 and first.cancels == 0)
  for _, change in ipairs({
      { "word_sense_reasoning_effort", "high" },
      { "word_sense_parameters_json", '{"provider":{"sort":"price"}}' },
      { "text_endpoint_type", "openrouter" },
      { "additional_parameters", { temperature = 0.2 } },
    }) do
    local previous = requests[#requests]
    configuration[change[1]] = change[2]
    controller:settings_changed()
    assert(previous.cancels == 1 and #controller.cache.order == 0)
    complete(previous)
    assert(#controller.overlay.boxes == 0, "stale response survived parameter change")
    drain()
    assert(requests[#requests] ~= previous and requests[#requests].callbacks.feature == "word_sense")
  end
  controller:close()
end)

test("navigation caps active requests and reuses a pending chunk", function()
  local controller, ui = ready(paragraph_pages(10))
  for page = 2, 5 do turn(controller, ui, page) end
  assert(active_count(controller) == 5 and #requests == 5)
  turn(controller, ui, 2)
  assert(#requests == 5)
  turn(controller, ui, 6)
  assert(active_count(controller) == 5 and requests[1].cancels == 1 and #requests == 6)
  complete(requests[1]); assert(#controller.overlay.boxes == 0)
  complete(requests[6]); drain()
  assert(#controller.overlay.boxes == 1)
  controller:close()
end)

test("selection pauses every extraction batch and navigation abandons old extraction", function()
  local controller, ui = start(paragraph_pages(3))
  ui.highlight.selected_text, ui.document.selection_active = {}, true
  tick(); assert(ui.document.reads == 0 and #requests == 0)
  ui.highlight.selected_text, ui.document.selection_active = nil, false
  tick(); local reads = ui.document.reads
  assert(reads == 24 and #requests == 0)
  ui.highlight.hold_pos, ui.document.selection_active = {}, true
  tick(); assert(ui.document.reads == reads)
  ui.highlight.hold_pos, ui.document.selection_active = nil, false
  turn(controller, ui, 2)
  assert(#requests == 1 and requests[1].page.tokens[1].text == "p2w1")
  controller:close()
end)

test("empty responses cache coverage and failed requests retry only on a later visit", function()
  local controller, ui = ready(paragraph_pages(3))
  complete(requests[1], {}); drain()
  requests[2].callbacks.on_error("offline"); drain()
  complete(requests[3]); drain()
  assert(#requests == 3 and #controller.overlay.boxes == 0)
  turn(controller, ui, 2)
  assert(#requests == 4, "failed paragraph retries on its next visit")
  complete(requests[4]); drain()
  turn(controller, ui, 1)
  assert(#requests == 4 and #controller.overlay.boxes == 0, "empty successful response is cached")
  controller:close()
end)

test("startup errors and corrupt extraction stay quiet without automatic retry loops", function()
  requests.start_error = true
  local controller = ready(paragraph_pages(4))
  drain()
  assert(#requests == 3 and active_count(controller) == 0)
  controller:close()
  requests.start_error = nil
  controller = start()
  controller.ui.document.getTextFromXPointers = function() error("bad document") end
  drain()
  assert(controller.scan_failed and #warnings > 0 and not next(scheduled))
  controller:close()
end)

test("synchronous transport completion does not leave jobs or stale scan markers", function()
  requests.synchronous_success = true
  local controller = ready(paragraph_pages(4))
  drain()
  assert(#requests == 3 and active_count(controller) == 0 and #controller.overlay.boxes == 1)
  controller:close()
  requests.synchronous_success, requests.synchronous_error = nil, true
  controller = ready(paragraph_pages(4)); drain()
  assert(#requests == 6 and active_count(controller) == 0)
  controller:close()
end)

test("empty EPUB fragments are skipped and backwards navigation cannot loop", function()
  local doc = document({ { "before", " ", "after" } })
  local chunk = chunk_at(doc, 1)
  assert(#chunk.words == 2 and chunk.words[2].text == "after")
  local source = Reflowable.new(make_ui(doc))
  local last = source:word("3e")
  assert(source:previous(last).text == "before")
  doc.getPrevVisibleWordEnd = function(_, pos) return pos end
  assert(not pcall(source.previous, source, last))
end)

test("suspend and close cancel transport, timers and hooks while resume reuses cache", function()
  local controller, ui = ready()
  complete(requests[1]); drain()
  local tap, hold = controller.original_tap, controller.original_hold
  controller:suspend(); assert(requests[2].cancels == 1 and not next(scheduled))
  complete(requests[2]); assert(#controller.overlay.boxes == 0)
  controller:resume(); drain()
  assert(#requests == 3 and #controller.overlay.boxes == 1)
  controller:close(); controller:close()
  assert(requests[3].cancels == 1 and #controller.cache.order == 0 and not next(scheduled))
  assert(not next(ui.view.view_modules) and ui.highlight.onTap == tap and ui.highlight.onHold == hold)
end)

local function pdf_ui(pages)
  local ui = make_ui(document({ { "unused" } }))
  local doc = { file = "book.PDF", info = { number_of_pages = #pages }, configurable = {} }
  function doc:getPageTextBoxes(number) return pages[number] end
  function doc:nativeToPageRectTransform(_, box)
    if self.transform_error then error("bad transform") end
    if self.configurable.text_wrap == 1 then
      return { x = box.x + 20, y = box.y + 40, w = box.w, h = box.h }
    end
    return box
  end
  ui.document = doc
  ui.view.state = { page = 1, zoom = 1, rotation = 0, offset = { x = 0, y = 0 } }
  ui.view.visible_area = { x = 0, y = 0, w = 600, h = 800 }
  function ui.view:pageToScreenTransform(number, box)
    if not self.page_scroll and number ~= self.state.page then error("offscreen page transformed") end
    return { x = (box.x - self.visible_area.x) * self.state.zoom,
      y = (box.y - self.visible_area.y) * self.state.zoom, w = box.w * self.state.zoom, h = box.h * self.state.zoom }
  end
  return ui
end

local function pdf_line(texts, y, x)
  local line = { x0 = x or 10, y0 = y, x1 = (x or 10) + #texts * 15, y1 = y + 12 }
  for i, word in ipairs(texts) do
    line[i] = { word = word, x0 = line.x0 + (i - 1) * 15, y0 = y, x1 = line.x0 + i * 15, y1 = y + 12 }
  end
  return line
end

test("fixed text endpoints correct by five Unicode characters in either direction", function()
  for _, padding in ipairs({ "four", "éééé", "漢漢漢漢" }) do
    local source = Fixed.new(pdf_ui({ { pdf_line({ padding, "target", padding }, 10) } }))
    local words = source:read_page(1)
    local entries = assert(Prompt.validate({ entries = {
      { first = 1, last = 3, text = "target", meaning = "goal" },
    } }, words, source))
    assert(#entries == 1 and entries[1].pos0.index == 2 and entries[1].pos1.index == 2)
    assert(#entries[1].positions == 1)
    entries = assert(Prompt.validate({ entries = {
      { first = 2, last = 2, text = padding .. " target " .. padding, meaning = "goal" },
    } }, words, source))
    assert(#entries == 1 and entries[1].pos0.index == 1 and entries[1].pos1.index == 3)
    assert(#entries[1].positions == 3 and #source:boxes(entries, 600, 800) == 3)
  end
end)

test("fixed text skips matches beyond five characters, ambiguous words and partial boxes", function()
  for _, texts in ipairs({ { "fives", "target", "four" }, { "four", "target", "fives" },
    { "ééééé", "target", "four" } }) do
    local source = Fixed.new(pdf_ui({ { pdf_line(texts, 10) } }))
    local entries = assert(Prompt.validate({ entries = {
      { first = 1, last = 3, text = "target", meaning = "goal" },
    } }, source:read_page(1), source))
    assert(#entries == 0)
  end
  local source = Fixed.new(pdf_ui({ { pdf_line({ "cat", "x", "cat" }, 10) } }))
  assert(#assert(Prompt.validate({ entries = {
    { first = 2, last = 2, text = "cat", meaning = "animal" },
  } }, source:read_page(1), source)) == 0)
  source = Fixed.new(pdf_ui({ { pdf_line({ "target." }, 10) } }))
  assert(#assert(Prompt.validate({ entries = {
    { first = 1, last = 1, text = "target", meaning = "goal" },
  } }, source:read_page(1), source)) == 0)
end)

test("several completed responses wait together without clearing a live selection", function()
  local controller, ui = ready(paragraph_pages(4))
  turn(controller, ui, 2)
  local first, second = requests[1], requests[2]
  ui.document.selection_active, ui.highlight.hold_pos = true, {}
  complete(first, { { first = 1, last = 1, meaning = "first meaning" } })
  complete(second, { { first = 1, last = 1, meaning = "second meaning" } })
  tick()
  assert(#controller.cache.order == 0)
  ui.document.selection_active, ui.highlight.hold_pos = false, nil
  drain()
  assert(#controller.cache.order == 2 and #controller.overlay.boxes == 1)
  assert(controller.overlay.boxes[1].entry.meaning == "second meaning")
  controller:close()
end)

test("PDF chunks preserve paragraph boundaries and native occurrence coordinates", function()
  local ui = pdf_ui({ { pdf_line(vocabulary(150), 10), pdf_line(vocabulary(150), 50),
    pdf_line({ "extra" }, 90), pdf_line({ "excluded" }, 130) } })
  local source = Fixed.new(ui)
  local chunk = Chunk.new(source, source:word(1, 1))
  while not Chunk.step(chunk) do end
  assert(chunk.count == 301 and #chunk.words == 301 and chunk.pos0.index == 1)
  assert(chunk.context:find("\n\n", 1, true) and not chunk.context:find("excluded", 1, true))
  local entries = assert(Prompt.validate({ entries = { { first = 149, last = 152,
    text = source:text({ chunk.words[149], chunk.words[150], chunk.words[151], chunk.words[152] }),
    meaning = "simple meaning" } } }, chunk.words, source))
  assert(#entries[1].positions == 4 and entries[1].pos0.page == 1)
end)

test("PDF continuation across physical pages includes the whole paragraph", function()
  local ui = pdf_ui({ { pdf_line({ "give" }, 10) }, { pdf_line({ "way" }, 10), pdf_line(vocabulary(301), 50) } })
  local source = Fixed.new(ui)
  local chunk = Chunk.new(source, source:word(2, 1))
  while not Chunk.step(chunk) do end
  assert(chunk.words[1].text == "give" and chunk.words[2].text == "way" and chunk.count == 303)
  local entries = assert(Prompt.validate({ entries = { { first = 1, last = 2, text = "give way", meaning = "stop resisting" } } }, chunk.words, source))
  assert(#entries[1].positions == 2)
  assert(#source:boxes(entries, 600, 800) == 1)
  ui.view.state.page = 2
  assert(#source:boxes(entries, 600, 800) == 1)
end)

test("PDF definitions survive zoom crop and reflow with transformed underlines", function()
  local ui = pdf_ui({ { pdf_line({ "difficult." }, 20) }, { pdf_line({ "another." }, 20) } })
  local controller = assert(WordSense.new { ui = ui })
  controller:refresh(); drain()
  assert(#requests == 1 and #requests[1].page.tokens == 2)
  complete(requests[1]); drain()
  assert(controller.overlay.boxes[1].box.x == 10)
  ui.view.state.zoom = 2
  ui.view.visible_area.x = 5
  controller:refresh(); drain()
  assert(#requests == 1 and controller.overlay.boxes[1].box.x == 10 and controller.overlay.boxes[1].box.w == 30)
  ui.document.configurable.text_wrap = 1
  controller:layout_changed(); drain()
  assert(#requests == 1 and controller.overlay.boxes[1].box.x == 50)
  ui.document.transform_error = true
  controller:layout_changed(); drain(); assert(#controller.overlay.boxes == 0)
  controller:close()
end)

test("PDF scroll signatures include every visible page and its position", function()
  local ui = pdf_ui({ { pdf_line({ "first." }, 10) }, { pdf_line({ "second." }, 10) } })
  ui.view.page_scroll = true
  ui.view.page_states = { { page = 1, zoom = 1, visible_area = { y = 0 } },
    { page = 2, zoom = 1, visible_area = { y = 0 } } }
  local source = Fixed.new(ui)
  local viewport = source:viewport()
  assert(source:step_viewport(viewport) and #viewport.words == 2)
  local signature = source:signature(600, 800)
  ui.view.page_states[2].visible_area.y = 10
  assert(signature ~= source:signature(600, 800))
end)

local function forbid_pdf_ocr(doc)
  local function forbidden() error("Word Sense must only read embedded PDF text") end
  doc.getTextBoxes, doc.getOCRWord, doc.getOCRText = forbidden, forbidden, forbidden
  doc.koptinterface = { getNativeOCRWord = forbidden }
end

test("PDF and DjVu share embedded text extraction and never invoke OCR", function()
  for _, file in ipairs({ "book.pdf", "book.PDF", "book.djvu", "book.DjVu", "book.djv", "book.DJV" }) do
    local ui = pdf_ui({ { pdf_line({ "digital", "text" }, 10) } })
    ui.document.file = file
    forbid_pdf_ocr(ui.document)
    local before = #requests
    local controller = assert(WordSense.new { ui = ui }, file)
    assert(getmetatable(controller.source) == Fixed, file)
    controller:refresh(); drain()
    assert(#requests == before + 1 and requests[#requests].page.tokens[1].text == "digital", file)
    complete(requests[#requests]); drain()
    assert(#controller.overlay.boxes == 1, file)
    ui.view.state.zoom = 2
    controller:layout_changed(); drain()
    assert(#requests == before + 1 and controller.overlay.boxes[1].box.w == 30, file)
    controller:close()
  end
end)

test("alternate providers choose an adapter by document APIs instead of extension", function()
  for _, file in ipairs({ "book.epub", "book.epub3", "book.kepub", "book.mobi", "book.txt", "book.html", "book.xhtml" }) do
    local ui = pdf_ui({ { pdf_line({ "alternate", "provider" }, 10) } })
    ui.document.file = file
    forbid_pdf_ocr(ui.document)
    local before = #requests
    local controller = assert(WordSense.new { ui = ui }, file)
    assert(getmetatable(controller.source) == Fixed, file)
    controller:refresh(); drain()
    assert(#requests == before + 1, file)
    complete(requests[#requests]); drain()
    assert(#controller.overlay.boxes == 1, file)
    controller:close()
  end
end)

test("fixed text routing rejects incomplete APIs and image-only DjVu sends no queries", function()
  for _, method in ipairs({ "getPageTextBoxes", "nativeToPageRectTransform" }) do
    local ui = pdf_ui({ {} })
    ui.document.file = "book.djvu"
    ui.document[method] = false
    assert(not Source.new(ui) and not WordSense.new { ui = ui }, method)
  end
  local ui = pdf_ui({ {} })
  ui.document.file = "book.djvu"
  ui.view.pageToScreenTransform = false
  assert(not Source.new(ui))
  ui = pdf_ui({ {} })
  ui.document.file = "book.djvu"
  forbid_pdf_ocr(ui.document)
  local controller = assert(WordSense.new { ui = ui })
  controller:refresh(); drain()
  assert(#requests == 0 and #controller.overlay.boxes == 0 and not controller.scan_failed)
  controller:close()
end)

test("image-only PDF regions are skipped without any recognition fallback", function()
  local line = pdf_line({ "placeholder" }, 10)
  line[1].word = nil
  local ui = pdf_ui({ { line } })
  forbid_pdf_ocr(ui.document)
  ui.document.configurable.text_wrap = 1
  local source = Fixed.new(ui)
  assert(not source:word(1, 1))
  local controller = assert(WordSense.new { ui = ui })
  controller:refresh(); drain()
  assert(#requests == 0 and #controller.overlay.boxes == 0 and not controller.scan_failed)
  controller:close()
end)

test("embedded PDF text is used even when KOReader has forced OCR enabled", function()
  local ui = pdf_ui({ { pdf_line({ "digital", "text" }, 10) } })
  ui.document.configurable.forced_ocr = 1
  forbid_pdf_ocr(ui.document)
  local controller = assert(WordSense.new { ui = ui })
  controller:refresh(); drain()
  assert(#requests == 1 and requests[1].page.tokens[1].text == "digital")
  complete(requests[1]); drain()
  ui.document.configurable.doc_language = "fra"
  controller:layout_changed(); drain()
  assert(#requests == 1 and #controller.overlay.boxes == 1)
  controller:close()
end)

test("mixed PDF regions keep only embedded words and nil text layers are empty", function()
  local line = pdf_line({ "digital", "placeholder", " ", "text" }, 10)
  line[2].word = nil
  local ui = pdf_ui({ { line }, {} })
  forbid_pdf_ocr(ui.document)
  local source = Fixed.new(ui)
  local viewport = source:viewport(); assert(source:step_viewport(viewport))
  assert(#viewport.words == 2 and source:text(viewport.words) == "digital text")
  assert(viewport.words[2].pos0.box.x == line[4].x0)
  ui.document.getPageTextBoxes = function() return nil end
  source = Fixed.new(ui)
  viewport = source:viewport(); assert(source:step_viewport(viewport) and #viewport.words == 0)
end)

test("PDF hyphenation joins line continuations while preserving paragraph breaks", function()
  local ui = pdf_ui({ { pdf_line({ "hyphen-" }, 10), pdf_line({ "ated" }, 25),
    pdf_line({ "paragraph-" }, 80), pdf_line({ "break" }, 130) } })
  local source = Fixed.new(ui)
  local viewport = source:viewport(); assert(source:step_viewport(viewport))
  assert(source:text(viewport.words) == "hyphenated\n\nparagraph-\n\nbreak")
end)

test("blank PDF pages send no requests and malformed coordinates do not crash the reader", function()
  local ui = pdf_ui({ {}, { pdf_line({ "word" }, 10) } })
  local controller = assert(WordSense.new { ui = ui })
  controller:refresh(); drain(); assert(#requests == 0)
  ui.view.state.page = 2
  controller:refresh(); drain(); assert(#requests == 1)
  controller:close()
  local line = pdf_line({ "word" }, 10)
  line[1].x0 = nil
  ui = pdf_ui({ { line } })
  controller = assert(WordSense.new { ui = ui })
  controller:refresh(); drain()
  assert(controller.scan_failed and #requests == 1 and #warnings > 0)
  controller:close()
end)

-- Saved results and the whole-book background pass.

local function temporary_directory()
  local name = os.tmpname()
  os.remove(name)
  assert(os.execute("mkdir -p '" .. name .. "'"))
  return name
end

local function start_with_store(pages, directory, page)
  local doc = document(pages)
  doc.page = page or 1
  local ui = make_ui(doc)
  local controller = assert(WordSense.new { ui = ui, path = directory })
  controller:refresh()
  return controller, ui
end

-- Runs scheduled work with a fake clock (each scheduled delay really elapses)
-- and answers requests as they appear. Returns false when nothing is left.
local function clock_step(clock)
  local callback, delay = next(scheduled)
  if callback then
    scheduled[callback] = nil
    clock.now = clock.now + (delay or 0)
    callback()
    return true
  end
  for _, request in ipairs(requests) do
    if not request.done and request.cancels == 0 then
      request.done = true
      complete(request)
      return true
    end
  end
  return false
end

local function with_clock(body)
  local clock, real_time, directory = { now = 1000 }, os.time, temporary_directory()
  os.time = function() return clock.now end
  local ok, err = pcall(body, clock, directory)
  os.time = real_time
  os.execute("rm -rf '" .. directory .. "'")
  if not ok then error(err, 0) end
end

local function run_to_end(clock, controller, limit)
  for _ = 1, limit or 3000 do
    if controller and active_count(controller) > 1 then error("background requests must not overlap") end
    if not clock_step(clock) then return end
  end
  error("whole-book pass did not settle")
end

test("results are saved per book and shown offline without new requests", function()
  local directory = temporary_directory()
  configuration.word_sense_whole_book = false
  local controller = start_with_store(paragraph_pages(3), directory)
  settle()
  local path = controller.store.path
  assert(#requests == 3 and controller.store:count() == 3 and not controller.store.complete)
  assert(path:find("/word_sense/", 1, true), "saved results belong in the word_sense folder")
  controller:close()
  assert(io.open(path, "rb"), "closing the book must write its results"):close()
  -- Another model or provider reuses everything that was already fetched.
  configuration.text_model = "another-model"
  local again = start_with_store(paragraph_pages(3), directory)
  settle()
  assert(#requests == 3, "saved chunks must not be requested again")
  assert(#again.overlay.boxes == 1 and again.overlay.boxes[1].entry.meaning == "large forest animal")
  again:close()
  -- A different reading level needs fresh meanings.
  configuration.word_sense_level = "Advanced"
  local advanced = start_with_store(paragraph_pages(3), directory)
  settle()
  assert(#requests > 3)
  advanced:close()
  os.execute("rm -rf '" .. directory .. "'")
end)

test("the whole-book setting is off-switchable and viewed chunks are still saved", function()
  local directory = temporary_directory()
  configuration.word_sense_whole_book = false
  local controller = start_with_store(paragraph_pages(6), directory)
  settle()
  assert(#requests == 3 and controller.crawl == nil and controller.store:count() == 3)
  controller:close()
  os.execute("rm -rf '" .. directory .. "'")
end)

test("the whole-book pass fetches every chunk gradually, then the book works offline", function()
  with_clock(function(clock, directory)
    local shown = {}
    local original_show = UI.show
    UI.show = function(_, widget) shown[#shown + 1] = widget.text end
    local controller, ui = start_with_store(paragraph_pages(8), directory)
    run_to_end(clock, controller)
    UI.show = original_show
    assert(#requests == 8, "one request per chunk, none repeated: " .. #requests)
    for i = 5, 8 do
      assert(requests[i].at - requests[i - 1].at >= 5, "background requests are spaced out")
    end
    assert(controller.store.complete and controller.store:count() == 8 and #controller.overlay.boxes == 1)
    assert(#shown == 1 and shown[1]:find("offline", 1, true), "completion is announced once")
    local path = controller.store.path
    controller:close()
    local saved = assert(io.open(path, "rb"))
    local text = saved:read("*a")
    saved:close()
    assert(text:find('["complete"]=true', 1, true))
    -- Reopened with the network unusable: nothing is requested, meanings still appear.
    requests.start_error = true
    local offline = start_with_store(paragraph_pages(8), directory, 5)
    run_to_end(clock, offline)
    assert(#requests == 8 and offline.store.complete and #offline.overlay.boxes == 1)
    turn(offline, offline.ui, 8)
    assert(#requests == 8 and #offline.overlay.boxes == 1)
    offline:close()
  end)
end)

test("the whole-book pass starts at the reading position, then wraps to the beginning", function()
  with_clock(function(clock, directory)
    local controller = start_with_store(paragraph_pages(6), directory, 4)
    run_to_end(clock, controller)
    assert(#requests == 6)
    local order = {}
    for i, request in ipairs(requests) do order[i] = request.page.tokens[1].text end
    assert(table.concat(order, ",") == "p4w1,p5w1,p6w1,p1w1,p2w1,p3w1", table.concat(order, ","))
    assert(controller.store.complete)
    controller:close()
  end)
end)

test("network failures pause the whole-book pass with growing delays, then it recovers", function()
  with_clock(function(clock, directory)
    requests.synchronous_error = true
    local controller = start_with_store(paragraph_pages(6), directory)
    local pauses = {}
    for _ = 1, 800 do
      if not clock_step(clock) then break end
      local crawl = controller.crawl
      if crawl and crawl.backoff > 0 and pauses[#pauses] ~= crawl.backoff then pauses[#pauses + 1] = crawl.backoff end
      if #pauses == 4 then break end
    end
    assert(table.concat(pauses, ",") == "30,60,120,240", table.concat(pauses, ","))
    assert(not controller.store.complete)
    requests.synchronous_error = nil
    run_to_end(clock, controller)
    assert(controller.store.complete and controller.store:count() == 6 and controller.crawl.backoff == 0)
    controller:close()
  end)
end)

test("closing mid-pass keeps the progress and the next session continues", function()
  with_clock(function(clock, directory)
    local controller = start_with_store(paragraph_pages(6), directory)
    for _ = 1, 3000 do
      assert(clock_step(clock))
      if requests[4] and requests[4].done then break end
    end
    assert(#requests == 4 and not controller.store.complete)
    controller:close()
    local next_session = start_with_store(paragraph_pages(6), directory)
    run_to_end(clock, next_session)
    assert(#requests == 6, "chunks fetched in the first session are not fetched again: " .. #requests)
    assert(next_session.store.complete)
    next_session:close()
  end)
end)

test("a failed whole-book answer skips that chunk and the book is not marked complete", function()
  with_clock(function(clock, directory)
    local controller = start_with_store(paragraph_pages(5), directory)
    for _ = 1, 3000 do
      if #requests == 4 and not requests[4].done then
        -- Valid JSON, but not a vocabulary object.
        requests[4].done = true
        decoded.nonsense = { notes = {} }
        requests[4].callbacks.on_done("nonsense")
      elseif not clock_step(clock) then
        break
      end
    end
    assert(#requests == 5, "the pass moves on after an unusable answer: " .. #requests)
    assert(controller.store:count() == 4 and not controller.store.complete)
    assert(controller.crawl.done and #controller.crawl.failed == 1)
    controller:close()
  end)
end)

local function tap_strip_button(controller, ui, id)
  local widget = assert(controller.status_widget, "the progress box is shown")
  for _, button in ipairs(controller.overlay.status.buttons) do
    if button.id == id then
      assert(widget:onTap(nil, { pos = { x = button.x + button.w / 2, y = button.y + button.h / 2 } }) == true)
      return true
    end
  end
  return false
end

local function shown_count(widget)
  local count = 0
  for _, shown in ipairs(UI.shown) do if shown == widget then count = count + 1 end end
  return count
end

test("meanings stay hidden with a progress strip until the whole book is prepared", function()
  with_clock(function(clock, directory)
    local controller, ui = start_with_store(paragraph_pages(8), directory)
    for _ = 1, 3000 do
      assert(clock_step(clock))
      if requests[5] and requests[5].done then break end
    end
    -- Five of eight equal chunks are stored, but nothing is underlined yet.
    assert(controller.store:count() == 5 and not controller.store.complete)
    assert(#controller.overlay.boxes == 0 and not controller.overlay.popup)
    local status = assert(controller.overlay.status, "a progress strip is visible")
    local fraction, covered, total = controller:progress()
    assert(total == 8 and covered == 5 and math.abs(fraction - 5 / 8) < 1e-9)
    assert(status.text:find("62%", 1, true) and status.text:find("5 of 8 pages", 1, true))
    assert(#status.buttons == 1 and status.buttons[1].id == "skip" and math.abs(status.fraction - 5 / 8) < 1e-9)
    assert(controller:progress_label() == "Word Sense progress: 62%")
    -- Tapping a word does nothing; only the strip's own zone reacts.
    assert(controller.overlay:tap({ x = 10, y = 130 }) == false)
    -- The box is a top-level widget (painted above anything else the reader draws).
    local widget = assert(controller.status_widget)
    assert(shown_count(widget) == 1 and widget.dimen.w == status.w and widget.dimen.h == status.h)
    assert(widget.ges_events.Tap[1].range == widget.dimen and widget.ges_events.Tap[1].ges == "tap")
    -- Painting the box works (frame, bar and button), and the page module no longer paints it.
    local painted = 0
    widget:paintTo({ paintRect = function() painted = painted + 1 end }, 0, 0)
    assert(painted >= 4)
    local page_painted = 0
    controller.overlay:paint({ paintRect = function() page_painted = page_painted + 1 end }, 0, 0)
    assert(page_painted == 0, "the page module paints no part of the box")
    run_to_end(clock, controller)
    -- Complete: the box disappears and the meanings appear.
    assert(controller.store.complete and controller.overlay.status == nil)
    assert(controller.status_widget == nil and shown_count(widget) == 0)
    assert(#controller.overlay.boxes == 1)
    assert(controller:progress_label() == "Word Sense progress: whole book ready")
    controller:close()
  end)
end)

test("the preparation wait can be skipped and the book keeps preparing in the background", function()
  with_clock(function(clock, directory)
    local controller, ui = start_with_store(paragraph_pages(6), directory)
    for _ = 1, 3000 do
      assert(clock_step(clock))
      if requests[4] and requests[4].done then break end
    end
    assert(#controller.overlay.boxes == 0 and controller.overlay.status)
    -- Tapping the strip's text does nothing; the Skip button skips.
    controller.status_widget:onTap(nil, {
      pos = { x = controller.overlay.status.x + 2, y = controller.overlay.status.y + 2 } })
    assert(not controller.store.skipped and controller.overlay.status)
    assert(tap_strip_button(controller, ui, "skip"))
    assert(controller.store.skipped and controller.overlay.status == nil)
    assert(controller.status_widget == nil and status_widgets() == 0)
    assert(#controller.overlay.boxes == 1, "prepared pages are usable right after skipping")
    -- Skipping twice is harmless, and the pass continues to the end.
    controller:skip_waiting()
    run_to_end(clock, controller)
    assert(#requests == 6 and controller.store.complete and #controller.overlay.boxes == 1)
    controller:close()
  end)
end)

test("a skipped, unfinished book reopens without the strip and can bring it back", function()
  with_clock(function(clock, directory)
    local first = start_with_store(paragraph_pages(6), directory)
    for _ = 1, 3000 do
      assert(clock_step(clock))
      if requests[4] and requests[4].done then break end
    end
    first:skip_waiting()
    first:close()
    local second, ui = start_with_store(paragraph_pages(6), directory)
    assert(second.store.skipped and second.overlay.status == nil)
    for _ = 1, 3000 do
      clock_step(clock)
      if #requests == 5 and requests[5].done then break end
    end
    assert(second.overlay.status == nil, "no strip after the reader chose to skip")
    -- The menu item shows the progress and re-opens the strip.
    local plugin = { word_sense = second, saveConfiguration = function() return true end }
    local item
    for _, entry in ipairs(require("settings_menu").get_items(plugin)) do
      if entry.text:find("Word Sense progress", 1, true) == 1 then item = entry end
    end
    assert(item and item.text_func():find("%%"))
    item.callback()
    assert(not second.store.skipped and second.overlay.status and #second.overlay.boxes == 0)
    second:close()
    assert(second.overlay.status == nil and second.status_widget == nil and status_widgets() == 0)
  end)
end)

test("the strip reports a lost connection and the progress menu entry works without Word Sense", function()
  with_clock(function(clock, directory)
    requests.synchronous_error = true
    local controller = start_with_store(paragraph_pages(4), directory)
    for _ = 1, 800 do
      clock_step(clock)
      if controller.crawl and controller.crawl.backoff > 0 then break end
    end
    clock_step(clock)
    assert(controller.overlay.status and controller.overlay.status.text:find("No connection", 1, true))
    requests.synchronous_error = nil
    controller:close()
    local plugin = {}
    for _, entry in ipairs(require("settings_menu").get_items(plugin)) do
      if entry.text:find("Word Sense progress", 1, true) == 1 then
        assert(entry.text_func() == "Word Sense progress: Word Sense is off")
        entry.callback()
      end
    end
  end)
end)

test("Retry now cancels the network pause and resumes work at once", function()
  with_clock(function(clock, directory)
    requests.synchronous_error = true
    local controller, ui = start_with_store(paragraph_pages(4), directory)
    for _ = 1, 800 do
      clock_step(clock)
      if controller.crawl and controller.crawl.backoff >= 60 then break end
    end
    local status = assert(controller.overlay.status)
    assert(status.text:find("No connection", 1, true))
    assert(#status.buttons == 2 and status.buttons[1].id == "retry" and status.buttons[2].id == "skip")
    local pause_left = controller.crawl.pause_until - clock.now
    assert(pause_left > 0)
    requests.synchronous_error = nil
    local before, started = #requests, clock.now
    assert(tap_strip_button(controller, ui, "retry"))
    assert(controller.crawl.backoff == 0 and controller.crawl.pause_until == 0)
    for _ = 1, 50 do
      if #requests > before then break end
      clock_step(clock)
    end
    assert(#requests > before, "work resumed")
    assert(clock.now - started < pause_left, "no waiting for the old pause to expire")
    run_to_end(clock, controller)
    assert(controller.store.complete)
    controller:close()
  end)
end)

-- Failure reasons: the strip and notices say what actually went wrong.

local function run_scheduled(clock, limit)
  for _ = 1, limit or 100 do
    local callback, delay = next(scheduled)
    if not callback then return end
    scheduled[callback] = nil
    clock.now = clock.now + (delay or 0)
    callback()
  end
end

-- Fails every outstanding request with `failure` until `done()` is true.
local function fail_until(clock, failure, done)
  for _ = 1, 60 do
    run_scheduled(clock, 30)
    for _, request in ipairs(requests) do
      if not request.done and request.cancels == 0 then
        request.done = true
        request.callbacks.on_error(failure)
        if done() then return end
      end
    end
    if done() then return end
  end
  error("the expected failure state was never reached")
end

test("an HTTP 429 is reported as a rate limit, not as a lost connection, with a Retry button", function()
  with_clock(function(clock, directory)
    local controller = start_with_store(paragraph_pages(4), directory)
    fail_until(clock, "429\n\nResponse: {}", function() return controller.crawl and controller.crawl.backoff > 0 end)
    local status = assert(controller.overlay.status)
    assert(status.text:find("Rate limit", 1, true) and not status.text:find("No connection", 1, true))
    assert(status.text:find("retry automatically", 1, true) and not controller.halted)
    assert(#status.buttons == 2 and status.buttons[1].id == "retry" and status.buttons[2].id == "skip")
    -- Layout: text lines, then the bar, then the buttons; nothing overlaps or leaves the screen.
    assert(#status.lines == 4)
    for i = 2, #status.lines do
      assert(status.lines[i].rel_y >= status.lines[i - 1].rel_y + status.lines[i - 1].h)
    end
    local last = status.lines[#status.lines]
    assert(status.bar_rel >= last.rel_y + last.h, "the bar sits below the text")
    local button = status.buttons[1]
    assert(button.y >= status.y + status.bar_rel + status.bar, "the buttons sit below the bar")
    local screen_height = require("device").screen:getHeight()
    assert(button.y + button.h <= status.y + status.h and status.y >= 0 and status.y + status.h <= screen_height)
    local rects = {}
    controller.status_widget:paintTo({ paintRect = function(_, x, y, w, h) rects[#rects + 1] = { x = x, y = y, w = w, h = h } end }, 0, 0)
    local bars = 0
    for _, rect in ipairs(rects) do
      if rect.h == status.bar then
        bars = bars + 1
        assert(rect.y >= status.y + status.bar_rel and rect.y + rect.h <= button.y, "the bar is painted above the buttons")
      end
    end
    assert(bars == 2, "a track and a fill")
    controller:close()
  end)
end)

test("a rejected API key stops automatic requests until Retry or a settings change", function()
  with_clock(function(clock, directory)
    local controller, ui = start_with_store(paragraph_pages(4), directory)
    fail_until(clock, "401\n\nResponse: {}", function() return controller.halted end)
    local status = assert(controller.overlay.status)
    assert(status.text:find("API key was rejected", 1, true) and status.text:find("Retry now", 1, true))
    assert(#status.buttons == 2 and status.buttons[1].id == "retry")
    local sent = #requests
    run_scheduled(clock, 100)
    assert(#requests == sent, "nothing more is sent while the key is rejected")
    assert(tap_strip_button(controller, ui, "retry") and controller.halted == nil)
    run_scheduled(clock, 100)
    assert(#requests > sent, "Retry sends requests again")
    -- Fixing the setting resumes by itself.
    fail_until(clock, "401\n\nResponse: {}", function() return controller.halted end)
    sent = #requests
    controller:settings_changed()
    assert(controller.halted == nil)
    run_scheduled(clock, 100)
    assert(#requests > sent)
    controller:close()
  end)
end)

test("slow, cut-off and rejected requests each get an honest message", function()
  with_clock(function(clock, directory)
    local controller = start_with_store(paragraph_pages(4), directory)
    fail_until(clock, "Incomplete AI response: the connection ended before the stream completed.",
      function() return controller.last_failure end)
    assert(controller.last_failure:find("too slowly", 1, true) and not controller.halted)
    controller:close()
    local rejected = start_with_store(paragraph_pages(4), directory)
    fail_until(clock, '400\n\nResponse: [{"error":{"message":"Invalid reasoning effort","status":"INVALID_ARGUMENT"}}]',
      function() return rejected.halted end)
    assert(rejected.halted:find("HTTP 400", 1, true) and rejected.halted:find("Invalid reasoning effort", 1, true))
    rejected:close()
    local keyless = start_with_store(paragraph_pages(4), directory)
    fail_until(clock, "No API key configured.", function() return keyless.halted end)
    assert(keyless.halted == "No API key is set.")
    keyless:close()
  end)
end)

test("after skipping the strip, failures still reach the reader as short notices", function()
  with_clock(function(clock, directory)
    local notices, original = {}, package.loaded["ui/widget/notification"]
    package.loaded["ui/widget/notification"] = { notify = function(_, text) notices[#notices + 1] = text end }
    local controller = start_with_store(paragraph_pages(4), directory)
    controller:skip_waiting()
    assert(controller.overlay.status == nil and #notices == 1)
    fail_until(clock, "401\n\nResponse: {}", function() return controller.halted end)
    local rejected = 0
    for _, text in ipairs(notices) do
      if text == "Word Sense: The API key was rejected (HTTP 401)." then rejected = rejected + 1 end
    end
    assert(rejected == 1, "the reason is shown")
    controller:retry_now()
    fail_until(clock, "401\n\nResponse: {}", function() return controller.halted end)
    rejected = 0
    for _, text in ipairs(notices) do
      if text:find("rejected", 1, true) then rejected = rejected + 1 end
    end
    assert(rejected == 1, "the same notice is not repeated within five minutes")
    package.loaded["ui/widget/notification"] = original
    controller:close()
  end)
end)

test("the progress box keeps one size and one widget while its text changes", function()
  with_clock(function(clock, directory)
    local controller = start_with_store(paragraph_pages(6), directory)
    for _ = 1, 3000 do
      assert(clock_step(clock))
      if requests[2] and requests[2].done then break end
    end
    local widget = assert(controller.status_widget)
    local size = { x = widget.dimen.x, y = widget.dimen.y, w = widget.dimen.w, h = widget.dimen.h }
    assert(#controller.overlay.status.lines == 4, "two text lines still reserve four")
    local repaints = UI.repaints
    fail_until(clock, "429\n\nResponse: {}", function() return controller.crawl and controller.crawl.backoff > 0 end)
    -- Two buttons and extra text appeared, yet it is the same widget at the same place and size.
    assert(controller.status_widget == widget and shown_count(widget) == 1)
    assert(widget.dimen.x == size.x and widget.dimen.y == size.y and widget.dimen.w == size.w and widget.dimen.h == size.h)
    assert(#controller.overlay.status.buttons == 2 and UI.repaints > repaints, "updated in place")
    controller:close()
    assert(status_widgets() == 0)
  end)
end)

for _, spec in ipairs(tests) do
  errors, warnings, requests, scheduled, decoded = {}, {}, {}, {}, {}
  UI.shown = {}
  configuration = { output_language = "English", word_sense_level = "Intermediate" }
  local ok, err = xpcall(spec[2], debug.traceback)
  assert(ok, spec[1] .. "\n" .. tostring(err))
  assert(#errors == 0, spec[1] .. "\n" .. table.concat(errors, "\n"))
  assert(not next(scheduled), spec[1] .. ": leaked scheduled work")
  assert(status_widgets() == 0, spec[1] .. ": leaked a progress box")
  print("PASS: " .. spec[1])
end
print("Word Sense: " .. #tests .. " isolated checks passed")
