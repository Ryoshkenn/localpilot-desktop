# LocalPilot computer use for pi

A [pi](https://github.com/badlogic/pi-mono) extension that lets the coding agent operate macOS: open apps and websites, click, type, scroll, and read what is on screen. It is built to work with **small local models** (tested with Qwen3.5-4B and Holo-3.1-4B on an M3 with 16 GB).

```
pi --computer -- "Open https://example.com in Safari and tell me the main heading"
```

## How it works

```
pi (agent loop, any model)
 └─ extension/            tools + computer mode + safety rules (TypeScript)
     └─ helper/lpcu       native helper (Swift): accessibility tree, input events, screenshots
```

Small models are poor at pixel coordinates and long prompts, so the design avoids both:

- **Accessibility first.** The screen is read from the macOS accessibility tree and shown to the model as a short numbered list (`[12] button "Save"`, `[13] textfield "Name" = "Ada"`), plus visible text. The model acts by number or label, so it never has to estimate coordinates.
- **Fuzzy targets.** `click {"target": "the Save button"}`, `"#12"` and `"12"` all resolve. Common argument mistakes (`{"id": 12}`, `{"element": "Save"}`, `{"enter": true}`) are normalized before validation.
- **Every action returns the new screen** with a one-line summary of what changed (or `Nothing visible changed.`), so the model needs no separate "look" turn.
- **Loop guard.** Repeating an action that changed nothing is flagged, and refused on the third try.
- **Visual fallback.** If a label isn't in the accessibility tree (canvas apps, some Electron apps), `click` grounds the description on a screenshot with a vision model (the session model or a dedicated one like Holo) using Qwen-VL 0-1000 coordinates.
- **Native text insertion.** Text goes into native fields through accessibility, bypassing autocorrect; web pages get real key events.
- **Lean computer mode.** `--computer` / `/computer on` replaces pi's coding prompt with a ~350-token prompt and exposes only the 7 computer tools. Old screens in the transcript are collapsed to one line, so context stays small and the server's prefix cache stays warm.
- **Deterministic safety rules** (from LocalPilot's policy engine): clicking things like *Delete*, *Buy*, *Send*; shortcuts like ⌘Q; opening a terminal; and typing into password fields need approval. Typing secrets or card numbers the user didn't supply, and non-web URLs, are blocked. Press Esc in pi to stop the agent at any time.

## Tools

| Tool | Arguments |
|---|---|
| `look` | `screenshot?` – attach a screenshot with numbered boxes (vision models) |
| `click` | `target` (number, label, or description), `double?`, `right?` |
| `type_text` | `text`, `target?`, `submit?` (press Enter) |
| `press_key` | `keys`, e.g. `cmd+t`, `return`, `escape` |
| `scroll` | `direction` (`up`/`down`/`left`/`right`), `target?` |
| `open_app` | `name` (loose: "chrome", "settings", "calc") |
| `open_url` | `url`, `app?` |

## Setup

1. **Permissions.** Give your terminal app *Accessibility* and *Screen Recording* access in System Settings > Privacy & Security.
2. **Helper.** `swift build -c release --package-path helper` (the extension also builds it on first use).
3. **Model server.** `scripts/serve-model.sh [model-dir] [port]` installs mlx-vlm into `~/.localpilot/mlxenv` and serves an MLX model with prefix caching on `127.0.0.1:8090`. Then add it to `~/.pi/agent/models.json`:

   ```json
   {
     "providers": {
       "local-mlx": {
         "baseUrl": "http://127.0.0.1:8090/v1",
         "api": "openai-completions",
         "apiKey": "local",
         "models": [{ "id": "/path/to/Qwen3.5-4B-MLX-4bit", "name": "Qwen3.5 4B", "input": ["text", "image"], "contextWindow": 32768, "maxTokens": 4096 }]
       }
     }
   }
   ```

   Any OpenAI-compatible server works (llama.cpp, LM Studio, Ollama); so do cloud models.
4. **Install** the package: `pi install ./integrations/pi-computer-use`, or try it once with `pi -e ./integrations/pi-computer-use --computer`.

## Use

- `pi --computer` starts in computer mode; `/computer on|off` switches inside pi.
- `/computer tools` adds the tools to a normal coding session without changing the prompt (good with strong models: "build the app, then click through it").
- `/computer status` shows permissions.

Configuration lives in `~/.pi/agent/computer-use.json` (all optional):

```json
{
  "maxElements": 80,
  "grounding": "auto",
  "groundingModel": "local-mlx//path/to/Holo-3.1-4B-MLX-4bit",
  "autoApprove": false,
  "alwaysOn": false
}
```

Environment overrides: `LOCALPILOT_AUTO_APPROVE=1`, `LOCALPILOT_GROUNDING=off`, `LOCALPILOT_GROUNDING_MODEL`, `LOCALPILOT_MAX_ELEMENTS`, `LPCU_PATH`.

## Evals

`node eval/run.ts [--model provider/id] [--only a,b] [--repeat n]` runs real tasks on this Mac (TextEdit, Calculator, Safari, a local test site with a form, a shop, a long page, Finder, System Settings, and a safety check that must *not* delete an account) and verifies each outcome with AppleScript or the test site's request log. Unit tests: `node --test extension/*.test.ts`.

The helper can also be driven by hand: `helper/.build/release/lpcu observe`, `lpcu click '{"id":3}'`, `lpcu tree`.
