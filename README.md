# AI Dictionary Plus for KOReader (Kindle)

A trimmed-down, extended fork, made for **KOReader on jailbroken Kindle e-readers**, of **[AI Dictionary for KOReader](https://github.com/SahandMalaei/ai-dictionary-koreader)** by [Sahand Malaei](https://github.com/SahandMalaei). **All credit for the original idea, design and code goes to him.** This fork builds on the original **v3.2** and keeps the same license (GPLv3). If you like the concept, please also visit and support the [original project](https://github.com/SahandMalaei/ai-dictionary-koreader).

AI Dictionary Plus lets you look up words and idioms, understand references, and simplify passages **in the context of your book**, and it can mark hard words automatically while you read (Word Sense). It uses your selection, nearby text, and the book's title, author, and chapter.

[What is different](#how-this-fork-differs-from-the-original-v32) · [Features](#features) · [Installation](#installation) · [Settings reference](#settings-reference) · [Vocabulary reports](#vocabulary-reports) · [Updates and saved data](#updates-and-saved-data) · [Troubleshooting](#troubleshooting)

## How this fork differs from the original (v3.2)

| Area | Original v3.2 | AI Dictionary Plus |
| --- | --- | --- |
| **Word Sense scope** | One global on/off switch (`word_sense_active`). | Switched on **per book** with **AI Dictionary settings → Word Sense for this book**. The choice is stored in that book's own KOReader settings; other books send no requests. |
| **Offline use** | Meanings are fetched for the page you read and are not saved. | Every meaning is **saved per book** in `koreader/ai_dictionary/word_sense/`. Reopening a book shows them instantly, offline. |
| **Whole-book preparation** | None. | With `word_sense_whole_book` (default `true`), the whole book is processed in the background, one gentle request about every five seconds, from your position to the end and then from the beginning. Failures are retried with growing delays. |
| **Progress and control** | None. | A progress strip with percentage, the reason for any failure, a **Retry now** button and a **Skip** button, plus a **Word Sense progress** menu entry. |
| **Provider setup** | Edit `configuration.lua` by hand. | **AI Dictionary settings → Provider** fills in the endpoint and model for **Google Gemini** or **OpenAI** in one tap (your API key is kept). |
| **Data location** | `Lookups/` inside the plugin folder. | `koreader/ai_dictionary/` outside the plugin folder, so replacing or updating the plugin never touches your history. Old data is moved automatically. |
| **Request timeout** | 15 seconds. | 40 seconds, because some Gemini models think before answering. |
| **Android support** | Android HTTP helper (Java/DEX), Android-only pronunciation (text-to-speech) button and voice settings, deploy scripts. | All removed. This fork targets Kindle only. The dictionary answer still includes the IPA pronunciation as text. |
| **Developer extras** | VS Code task, agent notes, funding file, Git LFS rules. | Removed to keep the repository small. |
| **Updates** | From the original author's repository. | From **this** repository's GitHub Releases. |
| **Plugin identity** | `AI_Dictionary.koplugin` | `AI_Dictionary_Plus.koplugin` (internal name `aidictionaryplus`, version `1.0.0`). |

> Do not install this plugin together with the original one: both register the same selection actions and menu entries. Remove the original `AI_Dictionary.koplugin` folder first. Your lookup history is kept, because both versions use `koreader/ai_dictionary/`.

## Features

| Action | What it does |
| --- | --- |
| **AI Dictionary** | Defines a word, phrase, or idiom in its current context, with the IPA pronunciation, usage tags, an example, synonyms, a simpler paraphrase, and etymology. |
| **AI Explain** | Explains concepts, characters, places, and allusions in relation to your book. |
| **AI Simplify** | Rewrites a difficult passage in simpler language. |
| **Word Sense** | Automatically underlines difficult words and idioms in the book; tap one to see a short contextual meaning. Works per book and can be prepared for offline use. |
| **Vocabulary reports** | Turns your saved lookups into a learning report with fill-in-the-blank exercises. |

Inside the answer popup:

- Tap **↻** to regenerate an answer, or **✕** to close it.
- Tap a word or select a phrase in a Dictionary answer to look it up. In Explain, the same gesture explores that topic further.
- Use **‹** and **›** at the bottom to revisit answers and their images without querying again.
- Dictionary and Explain can show a relevant **Wikipedia image** when available; tap it to enlarge.

You can choose any language (even fictional ones) for Dictionary and Explain answers with `output_language`; this setting does not change Simplify or vocabulary reports.

## Installation

You'll need a jailbroken Kindle with [KOReader](https://koreader.rocks/) installed, Wi-Fi, and an API key from [Google Gemini](https://aistudio.google.com/apikey), [OpenAI](https://platform.openai.com/), [OpenRouter](https://openrouter.ai/), or another provider supporting streaming OpenAI-compatible Chat Completions. API costs depend on your provider, model, and usage.

1. Download and extract the [latest release](https://github.com/kindlewiseoct2026-rgb/ai-dictionary-plus-koreader/releases/latest) on your computer.
2. Connect the Kindle by USB and copy the **`AI_Dictionary_Plus.koplugin`** folder into the Kindle's `koreader/plugins` directory. The resulting path on the Kindle should be `koreader/plugins/AI_Dictionary_Plus.koplugin/main.lua`.
3. Configure the plugin. Settings are saved in `AI_Dictionary_Plus.koplugin/configuration.lua`. You can rename [configuration.lua.sample](AI_Dictionary_Plus.koplugin/configuration.lua.sample) to `configuration.lua` and edit it (easier), or use the plugin's settings menu inside KOReader.

    A minimal configuration using OpenAI:

    ```lua
    local CONFIGURATION = {
        api_key = "YOUR_API_KEY",
        text_endpoint = "https://api.openai.com/v1/chat/completions",
        text_model = "gpt-5-nano",
    }

    return CONFIGURATION
    ```

    For **Google Gemini directly**, use a key from [Google AI Studio](https://aistudio.google.com/apikey), then either open **AI Dictionary settings → Provider → Google Gemini** and set your API key, or use:

    ```lua
    api_key = "YOUR_GEMINI_API_KEY",
    text_endpoint = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
    text_model = "gemini-flash-latest",
    ```

    Gemini 3 models cannot turn thinking off, so use `"minimal"` or `"low"` reasoning effort for fast lookups.

    For Gemini through [OpenRouter](https://openrouter.ai/google/gemini-2.5-flash), use an OpenRouter key with:

    ```lua
    text_endpoint = "https://openrouter.ai/api/v1/chat/completions",
    text_model = "google/gemini-2.5-flash",
    ```

4. Tap and hold on any word or group of words, and select **AI Dictionary**, **AI Explain**, or **AI Simplify**.

**Tip:** If KOReader's default dictionary opens immediately, disable **Dictionary on single word selection** under **Settings → Taps and gestures → Long-press on text**. In that same menu you can choose **AI Dictionary**, **AI Explain**, or **AI Simplify** to launch a lookup directly when you release a selection. A very-long press still opens the selection popup. Choose **Ask with popup dialog** to return to the normal menu.

## Settings reference

Settings follow the plugin's settings menu order, after **Check for updates now**.

| Setting | Purpose |
| --- | --- |
| `update_check` | **Auto-check for updates:** toggle; checks for a new release at startup when enabled (`true` by default). |
| **Provider** (menu only) | One-tap setup of the text endpoint and model for Google Gemini or OpenAI. Clears per-feature model and reasoning overrides; keeps your API key. |
| `output_language` | Language of Dictionary, Explain, and experimental Word Sense definitions. The default is `"English"`. |
| `images` | Show Wikipedia images in Dictionary and Explain (`true` by default). |
| `api_key` | Your provider's API key. |
| `text_endpoint` | Full Chat Completions URL. |
| `text_model` | Default model ID, used by any text-based feature group whose model is blank. |
| `dictionary_model` | Optional model for Dictionary + Simplify; `""` uses `text_model`. Shares the text endpoint and API key. |
| `dictionary_reasoning_effort` | Reasoning effort for Dictionary + Simplify; `""` sends no automatic reasoning parameters. Select an effort or **Use provider default** in settings. Supported levels depend on the provider and model. |
| `explain_model` | Optional model for Explain + reports; `""` uses `text_model`. Shares the text endpoint and API key. |
| `explain_reasoning_effort` | Reasoning effort for Explain + reports; `""` uses the provider default. Supported levels depend on the provider and model. |
| `word_sense_whole_book` | When Word Sense is on, also fetch meanings for the whole book in the background, one gentle request at a time, so it works offline. `true` by default; set `false` to fetch only the pages you read. Toggle **Word Sense: process whole book for offline use** in the plugin settings. |
| `word_sense_level` | Word Sense reader proficiency: `"Basic"`, `"Intermediate"` (default), or `"Advanced"`. Choose from the reading-level list in the plugin settings. Basic provides the most help. |
| `word_sense_model` | Optional model for Word Sense; `""` uses `text_model`. Shares the text endpoint and API key. |
| `word_sense_reasoning_effort` | Reasoning effort for Word Sense; `""` uses the provider default. Supported levels depend on the provider and model. |
| `debug_mode` | Show the query prompt alongside the answer for troubleshooting (`false` by default). |
| `additional_parameters` | Optional custom setting: a Lua table of extra request fields shared by all text features. Feature-specific JSON overrides shared fields with the same name. Appears in the menu when configured. |
| `dictionary_parameters_json`, `explain_parameters_json`, `word_sense_parameters_json` | **Advanced:** Config-only strings containing extra JSON request fields for each group; `""` adds nothing. Hidden from the settings menu. |



### Custom models and reasoning efforts

Dictionary and Simplify share `dictionary_model` and `dictionary_reasoning_effort`. Explain, its follow-up explorations, and vocabulary reports share the `explain_` settings. Word Sense uses the `word_sense_` settings. Regenerating keeps the same feature group. Blank models fall back to `text_model`, including on updates where the new settings are absent from the existing configuration.

### Word Sense

Word Sense automatically scans book text when enabled, using the configured Word Sense model. It marks difficult words, expressions, and idioms with subtle wavy underlines, with visual inspiration from [Footcream](https://github.com/Fank1/foot-cream), similar to Word Wise on Amazon's Kindle devices. Tap one to see a contextual meaning of up to five words in a small bubble beside the text.

Choose **AI Dictionary settings → Word Sense reading level → Basic / Intermediate / Advanced**. The level describes the reader's proficiency: Advanced marks only the most difficult vocabulary. Meanings follow `output_language`.

Word Sense is off by default and is switched on **per book**: open the book, then tap **AI Dictionary settings → Word Sense for this book**. The choice is stored in that book's own KOReader settings, so other books are never affected and send no requests. (The old global `word_sense_active` setting is ignored.)

**Offline use.** Every meaning Word Sense fetches is saved per book in `koreader/ai_dictionary/word_sense/` (one file per book, named after the book's checksum). Reopening a book shows its saved meanings immediately, with no network and no repeated requests. With **Word Sense: process whole book for offline use** on (the default), Word Sense also walks through the entire book after the pages you are reading are done: from your position to the end, then from the beginning back to your position. It sends one request about every five seconds, pauses with a growing delay when the network fails, and shows a message when the whole book is ready. Saved meanings depend on the reading level and `output_language`; changing either starts a fresh set for that book. Changing the model or provider keeps what was already fetched. Delete a book's file in that folder to regenerate it.

**Progress and skipping.** While the book is being prepared, Word Sense stays off: no underlines and no bubbles. A strip near the bottom of the page shows the percentage and the number of pages done. When a request fails, the strip says why (for example "Rate limit or quota reached (HTTP 429)", "The API key was rejected (HTTP 401)" or "The answer was cut off or came too slowly") and adds a **Retry now** button, which cancels the waiting time and starts again immediately. Temporary problems (no connection, rate limits, server errors, slow answers) are retried automatically after 30 seconds, then 60, 120, 240 and every 5 minutes at most. A rejected key or request (HTTP 400, 401, 403 or no API key) is not retried by itself: fix the setting, or tap Retry now. The box is drawn as its own top-level widget, so it always appears above the page and above anything other plugins draw on it, and taps outside the box go through to the book. Tap **Skip** on the strip to skip the wait: Word Sense starts working immediately on the pages already prepared, the rest continues in the background, and a short notice appears at every 10%. The skip is remembered for that book. **AI Dictionary settings → Word Sense progress** shows the current percentage, and tapping it brings the strip back. Two settings work together: **Word Sense for this book** decides whether Word Sense runs in the open book at all, and **Word Sense: process whole book for offline use** decides whether it prepares the entire book in the background (on) or only the pages you read (off). Pages where the pass could not get an answer are retried the next time the book is opened.

## Vocabulary reports

Open **Search (magnifying glass) → AI Dictionary Lookups Report** in KOReader's top menu, choose a timeframe, and tap **Generate Report**. Options range from **Today** to **All Time**. The AI uses your saved lookups to identify a learning pattern and create up to ten fill-in-the-blank exercises with answers.

## Updates and saved data

Use **AI Dictionary settings → Check for updates now**, or leave **Auto-check for updates** enabled (it checks at startup, at most once a week after you answer a prompt). The plugin reads the newest **GitHub Release** of this repository; if its tag (for example `v1.0.1`) is newer than the installed `version` in `_meta.lua`, you are offered an update. Accept it, then quit and restart KOReader.

**Where your data lives.** Dictionary lookup dates, selected words and surrounding context are stored in `koreader/ai_dictionary/Lookups/Lookups.txt`, and Word Sense meanings in `koreader/ai_dictionary/word_sense/`. Both are outside the plugin folder, so you can delete the plugin folder and copy in a new one without losing anything. Only `configuration.lua` (your settings and API key) is inside the plugin folder; the updater preserves it. If an older version kept data inside the plugin folder (`Lookups/` or `word_sense/`), the new version moves those files to the new place the first time they are needed.

### For maintainers: publishing an update

1. Edit the code, then raise `version` in `AI_Dictionary_Plus.koplugin/_meta.lua` (for example `"1.0.1"`).
2. Commit and push to GitHub.
3. On GitHub, create a **Release** (not only a tag) with a tag that matches the version, for example `v1.0.1`.
4. Devices running the plugin will offer the update at the next startup check or when you use **Check for updates now**.

The repository owner and name used by the updater are set at the top of `AI_Dictionary_Plus.koplugin/updater.lua` (`REPO_OWNER`, `REPO_NAME`). The plugin folder inside the repository must stay named `AI_Dictionary_Plus.koplugin`.

## Troubleshooting

| Problem | What to check |
| --- | --- |
| No AI actions in the selection menu | Check the folder path above, enable the plugin in KOReader's plugin management menu if needed, make sure the original AI Dictionary plugin is not also installed, and restart KOReader. |
| A request fails or returns no text | Check connectivity, API key, account balance, model ID, and the full endpoint URL. The text endpoint must support streaming Chat Completions. |
| No image | Enable **Show images**. Some topics have no suitable Wikipedia image. |
| Gemini returns an error | Use a Gemini API key (not an OpenAI one) with the Gemini endpoint. Gemini 2.5 Pro and Gemini 3 models reject `reasoning_effort = "none"`; use `"minimal"` or `"low"`. Old model IDs may be retired, so try `gemini-flash-latest`. |
| Update fails after you accept it | The updater downloads a zip and extracts it with the `unzip` command; if your Kindle setup has none, copy the new `AI_Dictionary_Plus.koplugin` folder over USB instead (your settings and data are kept). |
| Update check says it could not check | A GitHub **Release** must exist (a tag alone is not enough) and the repository must be public. |
| An answer seems wrong | Try **↻** or select more context. Answers are AI-generated; the Explain prompt asks to avoid fiction spoilers, but cannot guarantee it. |

## Credits and license

- Original plugin: **[AI Dictionary for KOReader](https://github.com/SahandMalaei/ai-dictionary-koreader)** by Sahand Malaei, which in turn credits [AskGPT](https://github.com/drewbaumann/AskGPT) for its initial backbone. The Word Sense underline style takes visual inspiration from [Footcream](https://github.com/Fank1/foot-cream).
- This fork is distributed under the same [GPLv3](LICENSE) license as the original. The original copyright notices remain in effect.
