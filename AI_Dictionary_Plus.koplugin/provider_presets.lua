-- One-tap provider setups for the text (Dictionary / Explain / Simplify / Word Sense) requests.
-- Add a table to PRESETS to offer another OpenAI-compatible Chat Completions provider.
local ProviderPresets = {}

ProviderPresets.PRESETS = {
  {
    id = "gemini",
    name = "Google Gemini",
    -- Google's OpenAI-compatible endpoint; keys come from Google AI Studio.
    text_endpoint = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
    -- Google's alias for the current Flash model, so the preset does not go stale.
    text_model = "gemini-flash-latest",
    -- "low" is accepted by every Gemini thinking model and keeps lookups quick.
    dictionary_reasoning_effort = "low",
    -- Word Sense sends long passages; without this Gemini may think for a long
    -- time before answering and the request runs out of time.
    word_sense_reasoning_effort = "low",
  },
  {
    id = "openai",
    name = "OpenAI",
    text_endpoint = "https://api.openai.com/v1/chat/completions",
    text_model = "gpt-5-nano",
    dictionary_reasoning_effort = "",
    word_sense_reasoning_effort = "",
  },
}

-- Per-feature values that belong to the previous provider and would be rejected by the new one.
local RESET_KEYS = {
  "dictionary_model",
  "explain_model",
  "explain_reasoning_effort",
  "word_sense_model",
}

local function normalize_endpoint(endpoint)
  if type(endpoint) ~= "string" then return "" end
  local trimmed = endpoint:match("^%s*(.-)%s*$")
  return (trimmed:gsub("/+$", ""))
end

function ProviderPresets.get(id)
  for _, preset in ipairs(ProviderPresets.PRESETS) do
    if preset.id == id then return preset end
  end
end

-- Returns the preset whose endpoint is currently configured, or nil for a custom endpoint.
function ProviderPresets.detect(configuration)
  local endpoint = normalize_endpoint(configuration and configuration.text_endpoint)
  for _, preset in ipairs(ProviderPresets.PRESETS) do
    if endpoint == preset.text_endpoint then return preset end
  end
end

-- Mutates and returns the given configuration. The API key, language and
-- other unrelated settings are left alone.
function ProviderPresets.apply(configuration, preset)
  configuration.text_endpoint = preset.text_endpoint
  configuration.text_model = preset.text_model
  configuration.dictionary_reasoning_effort = preset.dictionary_reasoning_effort or ""
  configuration.word_sense_reasoning_effort = preset.word_sense_reasoning_effort or ""
  for _, key in ipairs(RESET_KEYS) do
    configuration[key] = ""
  end
  return configuration
end

return ProviderPresets
