-- Word Sense is switched on per book, using KOReader's per-book settings (the
-- book's sidecar), so enabling it in one book never affects the others.
local BookSetting = {}

local KEY = "ai_dictionary_word_sense"

-- False in the file manager, where there is no open book to keep a setting for.
function BookSetting.available(ui)
  local settings = ui and ui.doc_settings
  return settings ~= nil and type(settings.isTrue) == "function"
end

function BookSetting.enabled(ui)
  return BookSetting.available(ui) and ui.doc_settings:isTrue(KEY) == true
end

function BookSetting.set(ui, enabled)
  if not BookSetting.available(ui) then return false end
  local settings = ui.doc_settings
  if enabled then settings:makeTrue(KEY) else settings:delSetting(KEY) end
  -- Write it out now so the choice survives a sudden power-off or crash.
  pcall(function() settings:flush() end)
  return true
end

return BookSetting
