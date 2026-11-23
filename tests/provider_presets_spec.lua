-- Run from the repository root: luajit tests/provider_presets_spec.lua
package.path = "./AI_Dictionary_Plus.koplugin/?.lua;" .. package.path
package.loaded.gettext = function(value) return value end
package.loaded.logger = { err = function(err) error(err) end }
local messages_shown = {}
package.loaded["ui/uimanager"] = { show = function() end, close = function() end }
package.loaded["ui/widget/infomessage"] = { new = function(_, value) messages_shown[#messages_shown + 1] = value.text; return value end }
package.loaded["ui/widget/inputdialog"] = { new = function(_, value) return value end }

local Presets = require("provider_presets")
local Parameters = require("request_parameters")
local Config = require("configuration_manager")
local Settings = require("settings_menu")

local gemini, openai = Presets.get("gemini"), Presets.get("openai")
assert(gemini and openai and Presets.get("missing") == nil)
assert(Parameters.provider(gemini.text_endpoint) == "gemini", "Gemini preset must be recognised as Gemini")
assert(Parameters.provider(openai.text_endpoint) == "openai")

-- detect: exact endpoint, tolerant of whitespace and trailing slash, nil when custom.
assert(Presets.detect({ text_endpoint = gemini.text_endpoint }) == gemini)
assert(Presets.detect({ text_endpoint = "  " .. gemini.text_endpoint .. "/ " }) == gemini)
assert(Presets.detect({ text_endpoint = "http://localhost:8080/v1/chat/completions" }) == nil)
assert(Presets.detect({}) == nil and Presets.detect(nil) == nil)

-- apply: swaps provider fields, clears stale overrides, keeps unrelated settings.
local old = {
  api_key = "keep-me", output_language = "Bengali",
  text_endpoint = openai.text_endpoint, text_model = "gpt-5-nano",
  dictionary_model = "gpt-5-mini", explain_model = "gpt-5", word_sense_model = "gpt-5-nano",
  dictionary_reasoning_effort = "xhigh", explain_reasoning_effort = "max", word_sense_reasoning_effort = "minimal",
}
local applied = Presets.apply(old, gemini)
assert(applied.text_endpoint == gemini.text_endpoint and applied.text_model == "gemini-flash-latest")
assert(applied.dictionary_reasoning_effort == "low")
-- Word Sense sends long passages, so Gemini must not be left thinking at its default depth.
assert(applied.word_sense_reasoning_effort == "low")
for _, key in ipairs({ "dictionary_model", "explain_model", "word_sense_model",
    "explain_reasoning_effort" }) do
  assert(applied[key] == "", key .. " should be cleared")
end
assert(applied.api_key == "keep-me" and applied.output_language == "Bengali")
assert(Presets.detect(applied) == gemini)

-- The resulting configuration builds a valid Gemini request for every feature.
for _, feature in ipairs(Parameters.FEATURES) do
  local endpoint, body = Parameters.build(Config.normalize(applied), feature, { { role = "user", content = "hi" } })
  assert(endpoint == gemini.text_endpoint and body.model == "gemini-flash-latest" and body.stream == true)
  if feature == "dictionary" or feature == "word_sense" then
    assert(body.reasoning_effort == "low" and body.reasoning == nil and body.thinking == nil)
  else
    assert(body.reasoning_effort == nil, feature .. " should use Gemini's default reasoning")
  end
end

-- Back to OpenAI.
Presets.apply(applied, openai)
assert(applied.text_endpoint == openai.text_endpoint and applied.dictionary_reasoning_effort == "")
assert(applied.word_sense_reasoning_effort == "")

-- Settings menu: a Provider item with one radio choice per preset that saves through the plugin.
local configuration = Config.normalize({ api_key = "k", text_endpoint = openai.text_endpoint, text_model = "gpt-5-nano" })
Config.load = function() return configuration end
local saved
local plugin = { saveConfiguration = function(_, value) saved = value; configuration = Config.normalize(value); return true end }
local item
for _, entry in ipairs(Settings.get_items(plugin)) do
  if entry.text:find("Provider:", 1, true) == 1 then item = entry end
end
assert(item and item.text == "Provider: OpenAI" and item.text_func() == "Provider: OpenAI")
assert(#item.sub_item_table == #Presets.PRESETS)
local choice
for _, c in ipairs(item.sub_item_table) do if c.text == "Google Gemini" then choice = c end end
assert(choice and choice.radio and not choice.checked_func())
choice.callback()
assert(saved and saved.text_endpoint == gemini.text_endpoint and saved.api_key == "k")
assert(choice.checked_func() and item.text_func() == "Provider: Google Gemini")
assert(#messages_shown > 0, "user should be reminded to set the API key")
configuration.text_endpoint = "https://example.test/v1/chat/completions"
assert(item.text_func() == "Provider: Custom")

print("provider_presets_spec: Gemini preset, detection, request building and settings menu passed")
