local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Screen = require("device").screen
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")

local View = {}
View.__index = View
-- Minimum gap between the popup and screen edges, scaled for the device.
local POPUP_SCREEN_PADDING = 8

local function scaled(value)
  return math.max(1, math.floor(Screen:scaleBySize(value)))
end

local function inside(box, pos)
  return pos.x >= box.x and pos.x < box.x + box.w
    and pos.y >= box.y and pos.y < box.y + box.h
end

function View.new()
  return setmetatable({ boxes = {} }, View)
end

function View:clear_status()
  local status = self.status
  self.status = nil
  if status then
    for _, line in ipairs(status.lines) do line.widget:free() end
    for _, button in ipairs(status.buttons) do button.label_widget:free() end
  end
  return status ~= nil
end

local STATUS_LINES = 4

local function button_signature(buttons)
  local ids = {}
  for i, button in ipairs(buttons) do ids[i] = button.id .. "=" .. button.label end
  return table.concat(ids, ",")
end

-- A progress strip near the bottom of the page: text lines, then the progress
-- bar, then a row of buttons ({ id, label }). Every part has its own explicit
-- position, stacked top to bottom, so nothing can overlap. Returns true when
-- anything changed.
function View:set_status(lines, fraction, buttons)
  buttons = buttons or {}
  local text = table.concat(lines, "\n")
  local signature = button_signature(buttons)
  local status = self.status
  if status and status.text == text and status.fraction == fraction
      and status.signature == signature then
    return false
  end
  self:clear_status()
  local sw, sh = Screen:getWidth(), Screen:getHeight()
  local padding, border, bar = scaled(10), scaled(2), scaled(8)
  local button_height, button_gap, line_gap = scaled(40), scaled(8), scaled(2)
  local width = math.floor(sw * 0.86)
  local inner = border + padding
  local face = Font:getFace("infofont", 18)
  local cursor = inner
  local laid_lines = {}
  -- The box always reserves room for four lines, so its size never changes while
  -- it is on screen and updating it cannot leave stale pixels behind.
  for i = 1, STATUS_LINES do
    local line = lines[i] or " "
    local widget = TextWidget:new { text = line, face = face, max_width = width - 2 * inner }
    local size = widget:getSize()
    laid_lines[i] = { widget = widget, w = size.w, h = size.h, rel_y = cursor }
    cursor = cursor + size.h + line_gap
  end
  local bar_rel = cursor + padding
  cursor = bar_rel + bar
  local buttons_rel
  if #buttons > 0 then
    buttons_rel = cursor + padding
    cursor = buttons_rel + button_height
  end
  local height = cursor + inner
  local x, y = math.floor((sw - width) / 2), math.floor(sh * 0.86) - height
  local button_width = #buttons > 0
    and math.floor((width - 2 * inner - (#buttons - 1) * button_gap) / #buttons) or 0
  local laid_buttons = {}
  for i, button in ipairs(buttons) do
    laid_buttons[i] = {
      id = button.id, label = button.label,
      x = x + inner + (i - 1) * (button_width + button_gap), y = y + buttons_rel,
      w = button_width, h = button_height,
      label_widget = TextWidget:new { text = button.label, face = Font:getFace("infofont", 20) },
    }
  end
  self.status = {
    text = text, fraction = fraction, signature = signature,
    lines = laid_lines, buttons = laid_buttons, x = x, y = y, w = width, h = height,
    padding = padding, border = border, bar = bar, inner = inner, bar_rel = bar_rel,
  }
  return true
end

function View:status_hit(pos)
  return self.status ~= nil and inside(self.status, pos)
end

-- The id of the strip button under the tap, if any.
function View:status_button_at(pos)
  if not self.status then return end
  for _, button in ipairs(self.status.buttons) do
    if inside(button, pos) then return button.id end
  end
end

function View:close_popup()
  local popup = self.popup
  self.popup = nil
  if popup then popup.frame:free() end
  return popup ~= nil
end

function View:clear()
  self.boxes = {}
  self:close_popup()
end

function View:show_popup(entry, box)
  self:close_popup()
  local sw, sh = Screen:getWidth(), Screen:getHeight()
  local screen_padding = math.max(0, math.floor(Screen:scaleBySize(POPUP_SCREEN_PADDING)))
  local padding, border, margin, tail = scaled(9), scaled(2), scaled(8), scaled(8)
  local face = Font:getFace("infofont", 20)
  local measure = TextWidget:new { text = entry.meaning, face = face }
  local max_width = math.max(1,
    math.min(math.floor(sw * 0.8), sw - 2 * screen_padding) - 2 * (padding + border))
  local width = math.min(max_width, math.max(scaled(80), measure:getSize().w))
  measure:free()
  local frame = FrameContainer:new {
    padding = padding, margin = 0, bordersize = border, radius = scaled(8),
    background = Blitbuffer.COLOR_WHITE, color = Blitbuffer.COLOR_BLACK,
    TextBoxWidget:new { text = entry.meaning, face = face, width = width, alignment = "center" },
  }
  local size = frame:getSize()
  local center = box.x + box.w / 2
  local x = math.max(screen_padding,
    math.min(sw - screen_padding - size.w, math.floor(center - size.w / 2)))
  local below = box.y + box.h + tail + margin + size.h <= sh - screen_padding
  local y = below and (box.y + box.h + tail) or (box.y - tail - size.h)
  -- Include the pointer tail in the screen-edge clearance.
  y = math.max(screen_padding + (below and tail or 0),
    math.min(sh - screen_padding - size.h - (below and 0 or tail), y))
  local tip_x = math.max(x + scaled(16), math.min(x + size.w - scaled(16), center))
  self.popup = {
    frame = frame, x = x, y = y, w = size.w, h = size.h,
    tip_x = math.floor(tip_x), tail = tail, below = below, border = border,
  }
end

function View:tap(pos)
  if self.popup and inside(self.popup, pos) then
    self:close_popup()
    return true
  end
  for _, item in ipairs(self.boxes) do
    if inside(item.box, pos) then
      self:show_popup(item.entry, item.box)
      return true
    end
  end
  -- Consume the dismissal tap so it cannot also turn a page or open a menu.
  -- With no bubble open, ordinary reader taps continue through unchanged.
  return self:close_popup()
end

function View:paint_status(bb, x, y)
  local status = self.status
  if not status then return end
  local left, top = x + status.x, y + status.y
  bb:paintRect(left, top, status.w, status.h, Blitbuffer.COLOR_BLACK)
  bb:paintRect(left + status.border, top + status.border,
    status.w - 2 * status.border, status.h - 2 * status.border, Blitbuffer.COLOR_WHITE)
  for _, line in ipairs(status.lines) do
    line.widget:paintTo(bb, left + math.floor((status.w - line.w) / 2), top + line.rel_y)
  end
  local bar_x, bar_y, bar_w = left + status.inner, top + status.bar_rel, status.w - 2 * status.inner
  bb:paintRect(bar_x, bar_y, bar_w, status.bar, Blitbuffer.COLOR_GRAY)
  bb:paintRect(bar_x, bar_y, math.floor(bar_w * math.max(0, math.min(1, status.fraction))),
    status.bar, Blitbuffer.COLOR_BLACK)
  for _, button in ipairs(status.buttons) do
    local bx, by = x + button.x, y + button.y
    bb:paintRect(bx, by, button.w, button.h, Blitbuffer.COLOR_BLACK)
    bb:paintRect(bx + status.border, by + status.border,
      button.w - 2 * status.border, button.h - 2 * status.border, Blitbuffer.COLOR_WHITE)
    local label = button.label_widget:getSize()
    button.label_widget:paintTo(bb, bx + math.floor((button.w - label.w) / 2),
      by + math.floor((button.h - label.h) / 2))
  end
end

function View:paint(bb, x, y)
  x, y = x or 0, y or 0
  local step, thickness = scaled(2), scaled(1)
  local wave = { 0, 1, 2, 1 }
  for _, item in ipairs(self.boxes) do
    local box = item.box
    if box.h >= thickness + 2 then
      local base_y = box.y + box.h - thickness - 2
      for offset = 0, box.w - 1, step do
        local rise = wave[(math.floor(offset / step) % 4) + 1]
        bb:paintRect(x + box.x + offset, y + base_y + rise,
          math.min(step, box.w - offset), thickness, Blitbuffer.COLOR_GRAY)
      end
    end
  end
  local popup = self.popup
  if not popup then return end
  popup.frame:paintTo(bb, x + popup.x, y + popup.y)
  local tail_y = popup.below and (popup.y - popup.tail + popup.border)
    or (popup.y + popup.h - popup.border)
  -- The triangle's open base merges into the card border.
  for row = 0, popup.tail - 1 do
    local half = popup.below and row or (popup.tail - row - 1)
    bb:paintRect(x + popup.tip_x - half, y + tail_y + row,
      2 * half + 1, 1, Blitbuffer.COLOR_BLACK)
    local inner = half - popup.border
    if inner >= 0 then
      bb:paintRect(x + popup.tip_x - inner, y + tail_y + row,
        2 * inner + 1, 1, Blitbuffer.COLOR_WHITE)
    end
  end
end

return View
