-- The Word Sense progress box as its own top-level widget. Top-level widgets are
-- painted after the reader and everything it draws (including other plugins'
-- annotations), so the box can never end up underneath them. Taps outside the
-- box pass straight through to the book.
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")

local StatusWidget = InputContainer:extend {
  name = "ai_dictionary_word_sense_status",
  covers_fullscreen = false,
}

-- `view` owns the drawing and the box position; `on_tap` receives each tap.
function StatusWidget:init()
  local status = self.view.status
  self.dimen = Geom:new { x = status.x, y = status.y, w = status.w, h = status.h }
  self.ges_events = { Tap = { GestureRange:new { ges = "tap", range = self.dimen } } }
end

function StatusWidget:paintTo(bb, x, y)
  self.view:paint_status(bb, x or 0, y or 0)
end

function StatusWidget:onTap(_, ges)
  if self.on_tap then self.on_tap(ges) end
  return true
end

return StatusWidget
