local Config = require("configuration_manager")
local ErrorBoundary = require("error_boundary")
local Cache = require("word_sense_cache")
local Chunk = require("word_sense_chunk")
local Source = require("word_sense_source")
local Store = require("word_sense_store")
local BookSetting = require("word_sense_book")
local StatusWidget = require("word_sense_status_widget")
local Prompt = require("word_sense_prompt")
local Requests = require("word_sense_requests")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local View = require("word_sense_view")
local logger = require("logger")
local queryAI = require("ai_query")

local WordSense = {}
WordSense.__index = WordSense
local MODULE = "ai_dictionary_word_sense"
local PAGE_DELAY = 0.6
local CACHE_SIZE = 16
-- Complete chunks to prefetch after the visible text, in order.
local LOOKAHEAD_CHUNKS = 2
-- Results are written to disk after this many new chunks, and on suspend/close.
local FLUSH_EVERY_CHUNKS = 8
-- Whole-book pass: one request at a time, spaced out, with a growing pause after
-- network failures. Everything it fetches is stored for offline use.
local CRAWL_DELAY_SECONDS = 5
local CRAWL_BACKOFF_START_SECONDS = 30
local CRAWL_BACKOFF_MAX_SECONDS = 300
local CRAWL_STEPS_PER_SCAN = 40

function WordSense.new(plugin)
  if not BookSetting.enabled(plugin.ui) then return end
  local source = Source.new(plugin.ui)
  if not source then return end
  local file = plugin.ui and plugin.ui.document and plugin.ui.document.file
  local store_ok, store = pcall(Store.new, plugin.path, file, source)
  local self = setmetatable({
    ui = plugin.ui, source = source, generation = 0, overlay = View.new(),
    cache = Cache.new(CACHE_SIZE, source),
    requests = Requests.new(5),
    store = store_ok and store or nil,
  }, WordSense)
  self.module = {
    paintTo = ErrorBoundary.wrap("paint Word Sense", function(_, bb, x, y) self:paint(bb, x, y) end),
  }
  self.ui.view:registerViewModule(MODULE, self.module)
  self:install_taps()
  return self
end

function WordSense:signature()
  return self.source:signature(Screen:getWidth(), Screen:getHeight())
end

function WordSense:priority_page(chunk)
  -- Distance belongs to the whole range, not its first paragraph's page.
  -- A long paragraph beginning far behind the viewport is still visible work.
  local current = self.source:current_page()
  return math.max(self.source:page(chunk.pos0), math.min(current, self.source:page(chunk.pos1)))
end

function WordSense:selecting()
  local highlight = self.ui.highlight
  return highlight and (highlight.hold_pos or highlight.selected_text or highlight.select_mode)
end

function WordSense:redraw()
  UIManager:setDirty(self.ui.dialog or self.ui, "ui")
end

function WordSense:stop_scan()
  self.generation = self.generation + 1
  if self.pending then UIManager:unschedule(self.pending); self.pending = nil end
end

function WordSense:cancel()
  self:stop_scan()
  self.requests:cancel_all()
end

function WordSense:schedule(delay, callback)
  if self.pending then UIManager:unschedule(self.pending) end
  self.pending = ErrorBoundary.wrap("scan Word Sense passage", function()
    self.pending = nil
    callback()
  end)
  UIManager:scheduleIn(delay, self.pending)
end

function WordSense:current(generation, signature)
  return not self.closed and not self.suspended and generation == self.generation
    and signature == self:signature()
end

function WordSense:refresh(force)
  if self.closed or self.suspended then return end
  local signature = self:signature()
  if not force and signature == self.page_signature then return end
  self:stop_scan()
  self.overlay:clear()
  self.page_signature = signature
  local configuration = Config.load()
  local model = configuration.word_sense_model ~= "" and configuration.word_sense_model
    or configuration.text_model or "gpt-5-nano"
  local scope = table.concat({
    configuration.word_sense_level, configuration.output_language, model, configuration.text_endpoint or "",
    configuration.word_sense_reasoning_effort, tostring(configuration.word_sense_parameters_json),
    tostring(configuration.text_endpoint_type or configuration.endpoint_type or ""),
    Config.serialize_lua_value(configuration.additional_parameters),
  }, "\n")
  self:sync_store(configuration)
  if scope ~= self.scope then
    self.requests:cancel_all()
    self.cache = Cache.new(CACHE_SIZE, self.source)
    self.crawl = nil
  end
  self.scope, self.configuration = scope, configuration
  self.viewport, self.failed, self.scan_failed, self.nearby = nil, {}, nil, {}
  for _, job in pairs(self.requests.jobs) do
    job.page = self:priority_page(job.chunk)
  end
  self:display()
  self:update_status()
  self:schedule(#self.overlay.boxes > 0 and 0 or PAGE_DELAY, function() self:scan() end)
  self:redraw()
end

-- Saved results depend only on the reading level and language, so switching
-- models or providers keeps everything already fetched.
function WordSense:sync_store(configuration)
  local store = self.store
  if not store then return end
  local scope = configuration.word_sense_level .. "\n" .. configuration.output_language
  if store.scope == scope then return end
  store:flush()
  store:load(scope)
  self.crawl = nil
end

function WordSense:settings_changed()
  self.halted = nil
  -- Only changes affecting meanings invalidate results. Font changes and other
  -- unrelated settings simply rebuild the viewport and geometry.
  self:refresh(true)
end

function WordSense:layout_changed()
  self:refresh(true)
end

function WordSense:protected(chunk)
  local protected = {}
  for id in pairs(self.nearby or {}) do protected[id] = true end
  if self.viewport then
    for _, word in ipairs(self.viewport.words) do
      for _, id in ipairs(self.cache.order) do
        if self.cache:covers(self.cache.records[id], word) then protected[id] = true end
      end
      if chunk and self.cache:covers(chunk, word) then protected[chunk.id] = true end
    end
  end
  return protected
end

function WordSense:display()
  if self:waiting() then
    -- Not usable until the book is prepared (or the reader skips the wait).
    self.overlay:close_popup()
    self.overlay.boxes = {}
  else
    self.overlay.boxes = self.source:boxes(self.cache:entries(), Screen:getWidth(), Screen:getHeight())
  end
  self:redraw()
end

-- A saved chunk covering the word is promoted into the in-memory cache.
function WordSense:stored(word)
  local record = self.store and self.store:find(word)
  if not record then return end
  self.cache:put(record, record.entries, self:protected(record))
  self.cache_changed = true
  return record
end

function WordSense:coverage(word)
  local record = self.cache:find(word)
  if record then return record end
  record = self:stored(word)
  if record then return record end
  for _, job in pairs(self.requests.jobs) do
    if self.cache:covers(job.chunk, word) then return job.chunk, "active" end
  end
  for _, chunk in ipairs(self.failed) do
    if self.cache:covers(chunk, word) then return chunk end
  end
end

-- Returns the next word needing a request, or nil plus "busy" (a request is in
-- flight) or "idle" (the viewport and the chunks after it are all covered).
function WordSense:next_word()
  local last
  self.nearby = {}
  for _, word in ipairs(self.viewport.words) do
    local record, status = self:coverage(word)
    if not record then return word end
    if status == "active" then return nil, "busy" end
    if not last or self.source:compare(last.pos1, record.pos1) < 0 then last = record end
  end
  if not last then return nil, "idle" end
  for _ = 1, LOOKAHEAD_CHUNKS do
    local word = self.source:after(last.pos1)
    if not word then return nil, "idle" end
    local record, status = self:coverage(word)
    if not record then
      -- When an unusually dense viewport already occupies the entire cache,
      -- stop speculative work instead of repeatedly querying rejected entries.
      local count = 0
      for _ in pairs(self:protected()) do count = count + 1 end
      if count >= self.cache.limit then return nil, "idle" end
      return word
    end
    self.nearby[record.id] = true
    if status == "active" then return nil, "busy" end
    last = record
  end
  return nil, "idle"
end

function WordSense:extract(step, done)
  local generation, signature = self.generation, self.page_signature
  local function advance()
    if not self:current(generation, signature) then return end
    -- Extracting reflowable text clears the engine's selection. Pause before every
    -- batch while KOReader owns a live selection.
    if self:selecting() then self:schedule(0.3, advance); return end
    local ok, finished, err = pcall(step)
    if not ok or err then
      self.scan_failed = true
      logger.warn("AI Dictionary Word Sense extraction: " .. tostring(err or finished))
      return
    end
    if finished then done() else self:schedule(0.01, advance) end
  end
  advance()
end

function WordSense:scan()
  if self.closed or self.suspended or self.scan_failed then return end
  if self.page_signature ~= self:signature() then self:refresh(); return end
  if self:selecting() then self:schedule(0.3, function() self:scan() end); return end
  for _, job in pairs(self.requests.jobs) do
    if job.received then self:finished(job, job.chunk, job.response); return end
  end
  if not self.viewport then
    local viewport = self.source:viewport()
    self:extract(function() return self.source:step_viewport(viewport) end, function()
      self.viewport = viewport
      self:display()
      self:wake()
    end)
    return
  end
  local ok, word, reason = pcall(self.next_word, self)
  if not ok then
    self.scan_failed = true
    logger.warn("AI Dictionary Word Sense navigation: " .. tostring(word))
    return
  end
  if self.cache_changed then
    self.cache_changed = false
    self:display()
  end
  if not word then
    if reason == "idle" then self:crawl_step() end
    return
  end
  -- A rejected key or request fails the same way every time; wait for a retry
  -- or a settings change instead of sending more.
  if self.halted then return end
  local chunk = Chunk.new(self.source, word)
  self:extract(function() return Chunk.step(chunk) end, function()
    if chunk.id then self:request(chunk) end
  end)
end

function WordSense:save_chunk(chunk, entries)
  local store = self.store
  if not store then return end
  store:put({ id = chunk.id, pos0 = chunk.pos0, pos1 = chunk.pos1, entries = entries })
  if store.dirty >= FLUSH_EVERY_CHUNKS then store:flush() end
end

function WordSense:flush_store()
  if self.store then self.store:flush() end
end

-- Whole-book pass. It starts at the reading position, runs to the end of the
-- book, then wraps around to the beginning. Progress is derived from what is
-- stored, so an interrupted pass simply continues where the data ends.
function WordSense:crawl_wanted()
  local crawl = self.crawl
  return self.store ~= nil and self.configuration ~= nil
    and self.configuration.word_sense_whole_book ~= false
    and not self.store.complete and not (crawl and crawl.done)
end

-- Meanings stay hidden until the whole book is prepared, unless skipped.
function WordSense:waiting()
  return self:crawl_wanted() and not self.store.skipped
end

local function notify(text)
  pcall(function() require("ui/widget/notification"):notify(text) end)
end

-- Fraction of the book's pages covered by saved results.
function WordSense:progress()
  local store, source = self.store, self.source
  if not store then return 0, 0, 0 end
  local total = source:total_pages()
  if not total or total < 1 then return store.complete and 1 or 0, 0, 0 end
  if store.complete then return 1, total, total end
  local covered, reached = 0, 0
  for _, record in ipairs(store.records) do
    local ok, first, last = pcall(function() return source:page(record.pos0), source:page(record.pos1) end)
    if ok and first and last then
      first = math.max(first, reached + 1)
      if last >= first then covered = covered + (last - first + 1) end
      reached = math.max(reached, last)
    end
  end
  covered = math.min(covered, total)
  return covered / total, covered, total
end

local function percent_of(fraction)
  return math.min(99, math.floor(fraction * 100))
end

-- Taps on the progress box: Retry and Skip act, anything else is swallowed so it
-- never turns the page underneath.
function WordSense:status_tap(ges)
  local button = ges and ges.pos and self.overlay:status_button_at(ges.pos)
  if button == "retry" then
    self:retry_now()
  elseif button == "skip" then
    self:skip_waiting()
  end
end

function WordSense:show_status_widget()
  self:hide_status_widget()
  if not self.overlay.status then return end
  self.status_widget = StatusWidget:new {
    view = self.overlay,
    on_tap = ErrorBoundary.wrap("tap Word Sense progress box", function(ges) self:status_tap(ges) end),
  }
  UIManager:show(self.status_widget, "ui", self.status_widget.dimen)
end

function WordSense:hide_status_widget()
  local widget = self.status_widget
  self.status_widget = nil
  if widget then UIManager:close(widget, "ui", widget.dimen) end
end

-- Shows or removes the progress strip to match the current state.
function WordSense:update_status()
  if self.closed then return end
  if not self:waiting() then
    if self.overlay:clear_status() then self:hide_status_widget() end
    return
  end
  local fraction, covered, total = self:progress()
  local lines = {
    string.format("Word Sense is preparing this book: %d%%", percent_of(fraction)),
    string.format("%d of %d pages", covered, total),
  }
  local buttons = { { id = "skip", label = "Skip" } }
  if self.halted then
    lines[#lines + 1] = self.halted
    lines[#lines + 1] = "Check the settings, then tap Retry now."
    table.insert(buttons, 1, { id = "retry", label = "Retry now" })
  elseif self.crawl and self.crawl.pause_until > os.time() then
    lines[#lines + 1] = self.last_failure or "The request failed."
    lines[#lines + 1] = "It will retry automatically."
    table.insert(buttons, 1, { id = "retry", label = "Retry now" })
  end
  local changed = self.overlay:set_status(lines, fraction, buttons)
  local widget = self.status_widget
  local status = self.overlay.status
  if not widget or widget.dimen.x ~= status.x or widget.dimen.y ~= status.y
      or widget.dimen.w ~= status.w or widget.dimen.h ~= status.h then
    self:show_status_widget() -- first time, after a resume, or a changed screen size
  elseif changed then
    UIManager:setDirty(widget, "ui", widget.dimen)
  end
end

-- Cancels the pause after a network failure and starts working again at once.
function WordSense:retry_now()
  self.halted = nil
  local crawl = self.crawl
  if crawl then crawl.backoff, crawl.pause_until, crawl.next_at = 0, 0, 0 end
  self:refresh(true)
end

function WordSense:skip_waiting()
  if not self.store or self.store.skipped or not self:waiting() then return end
  self.store:skip()
  self.store:flush()
  self:update_status()
  self:display()
  notify("Word Sense is on. The rest of the book keeps preparing in the background.")
end

-- Menu entry: shows progress and brings the progress strip back after a skip.
function WordSense:progress_label()
  if not self.store or not self.configuration or self.configuration.word_sense_whole_book == false then
    return "Word Sense progress: not tracked"
  end
  if self.store.complete then return "Word Sense progress: whole book ready" end
  return string.format("Word Sense progress: %d%%", percent_of(self:progress()))
end

function WordSense:show_progress()
  if not self.store or not self.configuration or self.configuration.word_sense_whole_book == false then
    notify("Whole-book processing is turned off in the settings.")
    return
  end
  if self.store.complete then
    notify("Word Sense: the whole book is ready for offline use.")
    return
  end
  self.store:unskip()
  if self.crawl and self.crawl.done then self.crawl = nil end -- retry what was skipped
  self:display()
  self:update_status()
  self:wake()
end

-- After a skip the pass is silent, so report every 10% with a short notice.
function WordSense:announce_progress()
  local crawl = self.crawl
  if not crawl then return end
  local step = math.floor(percent_of(self:progress()) / 10) * 10
  if step >= 10 and step > (crawl.announced or 0) then
    crawl.announced = step
    notify(string.format("Word Sense: %d%% of the book is ready", step))
  end
end

-- Turns the error text from the request into a short message for the reader and
-- says whether trying again can help. A rejected key or request will fail the
-- same way every time, so those stop the automatic retries.
local function classify_failure(failure)
  local text = type(failure) == "string" and failure or ""
  local first = text:match("^[^\n]*")
  local code = tonumber(first)
  if text == "No API key configured." then
    return { halt = true, text = "No API key is set." }
  elseif code then
    if code == 401 or code == 403 then
      return { halt = true, text = "The API key was rejected (HTTP " .. code .. ")." }
    elseif code == 429 then
      return { text = "Rate limit or quota reached (HTTP 429)." }
    elseif code >= 500 then
      return { text = "The AI service reported an error (HTTP " .. code .. ")." }
    end
    local reason = text:match('"message"%s*:%s*"([^"]+)"')
    return { halt = true, text = "The AI service rejected the request (HTTP " .. code .. ")"
      .. (reason and (": " .. reason:sub(1, 80)) or ".") }
  elseif text:find("^Incomplete AI response") then
    return { text = "The answer was cut off or came too slowly." }
  elseif text:find("^Could not") then
    return { halt = true, text = "The request could not be built. Check the settings." }
  end
  local lowered = first:lower()
  if text == "" or lowered:find("connect") or lowered:find("refused") or lowered:find("closed")
      or lowered:find("host") or lowered:find("timeout") or lowered:find("unreachable")
      or lowered:find("resolve") or lowered:find("network") then
    return { text = "No connection to the AI service." }
  end
  return { text = "The request failed: " .. first:sub(1, 60) }
end

function WordSense:report_failure(text)
  if self:waiting() then return end -- the progress strip already shows it
  local now = os.time()
  if text == self.reported_failure and now - (self.reported_at or 0) < 300 then return end
  self.reported_failure, self.reported_at = text, now
  notify("Word Sense: " .. text)
end

function WordSense:note_failure(failure)
  local info = classify_failure(failure)
  self.last_failure = info.text
  if info.halt then
    self.halted = info.text
  elseif self.crawl then
    local crawl = self.crawl
    crawl.backoff = crawl.backoff == 0 and CRAWL_BACKOFF_START_SECONDS
      or math.min(crawl.backoff * 2, CRAWL_BACKOFF_MAX_SECONDS)
    crawl.pause_until = os.time() + crawl.backoff
  end
  self:report_failure(info.text)
end

function WordSense:note_success()
  self.last_failure, self.halted = nil, nil
  if self.crawl then self.crawl.backoff = 0 end
end

function WordSense:crawl_covered(crawl, word)
  local record = self.store:find(word)
  if record then return record end
  for _, failed in ipairs(crawl.failed) do
    if self.cache:covers(failed, word) then return failed end
  end
end

-- The next word the pass still has to cover, or nil when it is finished or has
-- used up this scan's step budget.
function WordSense:crawl_word(crawl)
  local source = self.source
  for _ = 1, CRAWL_STEPS_PER_SCAN do
    local word
    if crawl.cursor then
      word = source:after(crawl.cursor)
    elseif crawl.phase == "forward" then
      word = source:after(crawl.origin)
    else
      word = source:first()
    end
    if word and crawl.phase == "wrap" and crawl.origin and source:compare(word.pos0, crawl.origin) >= 0 then
      word = nil
    end
    if not word then
      if crawl.phase == "forward" then
        crawl.phase, crawl.cursor = "wrap", nil
      else
        crawl.done = true
        return
      end
    else
      local record = self:crawl_covered(crawl, word)
      if not record then return word end
      crawl.cursor = record.pos1
    end
  end
  self:schedule(0.05, function() self:scan() end)
end

function WordSense:crawl_finished(crawl)
  local complete = #crawl.failed == 0
  if complete then self.store:mark_complete() end
  self.store:flush()
  self:update_status()
  self:display()
  if not complete then
    notify("Word Sense is ready. A few parts could not be prepared and will be retried next time.")
    return
  end
  pcall(function()
    UIManager:show(require("ui/widget/infomessage"):new {
      text = "Word Sense: the whole book is ready for offline use.", timeout = 4,
    })
  end)
end

function WordSense:crawl_step()
  if not self:crawl_wanted() or next(self.requests.jobs) then return end
  if self.halted then
    self:update_status()
    return
  end
  local crawl = self.crawl
  if not crawl then
    local first = self.viewport and self.viewport.words[1]
    crawl = {
      origin = first and first.pos0, phase = first and "forward" or "wrap",
      failed = {}, next_at = 0, pause_until = 0, backoff = 0,
    }
    self.crawl = crawl
  end
  local wait = math.max(crawl.next_at, crawl.pause_until) - os.time()
  if wait > 0 then
    self:update_status()
    self:schedule(wait, function() self:scan() end)
    return
  end
  local ok, word = pcall(self.crawl_word, self, crawl)
  if not ok then
    -- Stored or engine positions are unusable: stop the pass for this session.
    crawl.done = true
    logger.warn("AI Dictionary Word Sense whole-book pass: " .. tostring(word))
    return
  end
  if not word then
    if crawl.done then self:crawl_finished(crawl) end
    return
  end
  local chunk = Chunk.new(self.source, word)
  self:extract(function() return Chunk.step(chunk) end, function()
    if chunk.id then self:request(chunk, true) end
  end)
end

function WordSense:wake()
  if not self.closed and not self.suspended and not self.pending then
    self:schedule(0, function() self:scan() end)
  end
end

function WordSense:finished(job, chunk, response, failure)
  if self.requests.jobs[job.key] ~= job then return end
  if job.received then response = job.response end -- Ignore duplicate transport callbacks.
  -- Recheck the viewport before displaying anything; a page event may be pending.
  self:refresh()
  if self.closed or self.suspended or job.scope ~= self.scope then return end
  -- Range verification clears crengine's selection, just like extraction. Keep
  -- completed responses in the existing job pool until selection has ended.
  if response ~= nil and self:selecting() then
    job.received, job.response = true, response
    self:wake()
    return
  end
  if not self.requests:remove(job) then return end
  local entries, err
  if response ~= nil then entries, err = Prompt.parse(response, chunk.words, self.source) end
  if response == nil then self:note_failure(failure) else self:note_success() end
  if entries then
    self:save_chunk(chunk, entries)
    -- Background chunks only go to disk; they enter the cache when displayed.
    if not job.crawl then
      self.cache:put(chunk, entries, self:protected(chunk))
      self:display()
    end
  else
    -- Only failures suppress a retry for this visit. Successful coverage is
    -- always determined by stored ranges, so eviction cannot create scan gaps.
    self.failed[#self.failed + 1] = { id = chunk.id, pos0 = chunk.pos0, pos1 = chunk.pos1 }
    -- An unusable answer would repeat forever, so the pass skips that chunk
    -- until the next session. A network failure is simply retried after a pause.
    if job.crawl and response ~= nil and self.crawl then
      local failed = self.crawl.failed
      failed[#failed + 1] = { id = chunk.id, pos0 = chunk.pos0, pos1 = chunk.pos1 }
    end
    logger.warn("AI Dictionary Word Sense: " .. (err or "passage request failed."))
  end
  if job.crawl and self.crawl then self.crawl.next_at = os.time() + CRAWL_DELAY_SECONDS end
  self:update_status()
  if job.crawl and not self:waiting() then self:announce_progress() end
  self:wake()
end

function WordSense:request(chunk, crawl)
  local configuration = self.configuration
  local messages = Prompt.messages(chunk, chunk.context,
    configuration.word_sense_level, configuration.output_language)
  local key = self.scope .. "\n" .. chunk.id
  local job = self.requests:reserve(key, self:priority_page(chunk), self.source:current_page())
  if not job then return end -- Retry when a nearer request finishes and frees a slot.
  job.scope, job.chunk, job.crawl = self.scope, chunk, crawl
  local ok, cancel = pcall(queryAI, messages, {
    feature = "word_sense",
    -- Keep compatibility with providers that do not support JSON response mode.
    on_done = ErrorBoundary.wrap("receive Word Sense definitions", function(response)
      self:finished(job, chunk, response)
    end),
    on_error = ErrorBoundary.wrap("Word Sense request error", function(failure)
      self:finished(job, chunk, nil, failure)
    end),
  })
  if not ok then
    self:finished(job, chunk, nil, cancel)
  elseif self.requests.jobs[key] == job and type(cancel) == "function" then
    -- Some callbacks are synchronous; do not retain a finished worker.
    job.cancel = cancel
  end
end

function WordSense:paint(bb, x, y)
  if self.closed or self.suspended then return end
  -- Also catches layout changes and position changes without a reader event.
  self:refresh()
  if not self:selecting() then self.overlay:paint(bb, x, y) end
end

function WordSense:tap(ges)
  if self.closed or self.suspended or not ges or not ges.pos or self:selecting() then return end
  if self.page_signature ~= self:signature() then self:refresh(); return end
  local had_popup = self.overlay.popup ~= nil
  local handled = self.overlay:tap(ges.pos)
  if self.overlay.popup then self:register_popup_taps() end
  if handled or had_popup then self:redraw() end
  return handled
end

function WordSense:close_popup()
  if self.overlay:close_popup() then self:redraw() end
end

function WordSense:register_popup_taps()
  if type(self.ui.registerTouchZones) ~= "function" then return end
  local id = MODULE .. "_popup_tap"
  local overrides = {}
  -- Register when a bubble opens so even zones installed after ReaderReady
  -- (links, menus, page-turn regions and custom gestures) come after dismissal.
  for zone_id, zone in pairs(self.ui._zones or {}) do
    if zone_id ~= id and zone.def and zone.def.ges == "tap" then
      overrides[#overrides + 1] = zone_id
    end
  end
  self.popup_touch_zones = { {
    id = id, ges = "tap",
    screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
    overrides = overrides,
    handler = ErrorBoundary.wrap("tap Word Sense bubble", function(ges)
      if self.overlay.popup then return self:tap(ges) end
    end),
  } }
  self.ui:registerTouchZones(self.popup_touch_zones)
end

function WordSense:install_taps()
  local highlight = self.ui.highlight
  if not highlight then return end
  self.original_tap, self.original_hold = highlight.onTap, highlight.onHold
  self.tap_wrapper = function(widget, arg, ges)
    if self.overlay.popup and ErrorBoundary.call("tap Word Sense bubble", self.tap, self, ges) then
      return true
    end
    -- Saved highlights and selection gestures retain their normal priority.
    local result
    if self.original_tap then result = self.original_tap(widget, arg, ges) end
    if result then return result end
    return ErrorBoundary.call("tap Word Sense", self.tap, self, ges)
  end
  self.hold_wrapper = function(widget, ...)
    ErrorBoundary.call("dismiss Word Sense on hold", self.close_popup, self)
    if self.original_hold then return self.original_hold(widget, ...) end
  end
  highlight.onTap, highlight.onHold = self.tap_wrapper, self.hold_wrapper
end

function WordSense:suspend()
  self.suspended = true
  self:cancel()
  self:flush_store()
  self:hide_status_widget()
  self.overlay:clear()
  self:redraw()
end

function WordSense:resume()
  self.suspended = false
  self:refresh(true)
end

function WordSense:close()
  if self.closed then return end
  self.closed = true
  self:cancel()
  self:flush_store()
  self.crawl = nil
  self:hide_status_widget()
  self.overlay:clear_status()
  self.overlay:clear()
  self.cache = Cache.new(CACHE_SIZE, self.source)
  if self.popup_touch_zones and type(self.ui.unRegisterTouchZones) == "function" then
    self.ui:unRegisterTouchZones(self.popup_touch_zones)
    self.popup_touch_zones = nil
  end
  local modules = self.ui.view.view_modules
  if modules and modules[MODULE] == self.module then modules[MODULE] = nil end
  local highlight = self.ui.highlight
  if highlight then
    -- Leave wrappers installed by another plugin after ours intact.
    if highlight.onTap == self.tap_wrapper then highlight.onTap = self.original_tap end
    if highlight.onHold == self.hold_wrapper then highlight.onHold = self.original_hold end
  end
end

return WordSense
