# Native tools and model responses

Native tool calling is the default for local servers. LocalPilot sends separate
function definitions in `tools`, `tool_choice: "auto"`, and
`parallel_tool_calls: false`. It sends no `response_format` or custom tool syntax
in this mode. The server is responsible for its model-specific chat template and
parser; API compatibility alone does not prove the model was trained for tools.

Ordinary assistant `content` is displayed directly. An assistant `tool_calls`
message is retained with its exact call IDs and arguments, and each call gets a
`role: "tool"` result with `tool_call_id`. Reasoning supplied separately by the
server is preserved for subsequent model requests, not displayed as chat.
Screenshots are attached to the next request as image content.

The native registry in `core/agent/tools/NativeTools.swift` supplies each tool's
name, description, parameter schema, validation, and adapter into the shared
action executor. It exposes 15 tools:

| Tool | Arguments |
| --- | --- |
| `open_app` | `name` |
| `observe`, `screenshot`, `wait` | none |
| `click`, `double_click` | `id`, or both `x` and `y` |
| `type_text` | `text`, optional `id` |
| `press_key` | `key` |
| `scroll` | `lines` (negative = down) |
| `browser_new_tab` | optional `url` |
| `browser_navigate` | `url` |
| `browser_switch_tab`, `browser_close_tab` | `tab` (1-based) |
| `update_todo` | `items` (optional workflow; [] clears) |
| `run_terminal_command` | `command` |

There is no native `reply`, `finish`, or mandatory planning tool. Text-only
responses end the turn. Text accompanying a tool call is commentary; the model
receives the result before providing its final answer. Invalid tool arguments
produce a non-execution result for the same call ID. Multiple calls in one
response are returned as unexecuted, requesting one call at a time. Paused or
abandoned calls are also closed with explicit non-execution results before a
new request, preserving valid conversation history.

Native request errors never silently remove tools or switch to custom JSON.
For unsupported model/server combinations, select **JSON compatibility** in
Settings. The older contract below is retained for that explicit mode and the
built-in rules provider.

## JSON compatibility format

The model can answer directly, use one command, or return up to six commands.
Only `type` is required on a command; the validator checks the arguments needed
for that particular action. Explanations, risk labels, and checklists are not
required from the model. The compact command reference is frontloaded in every
system prompt.

```json
{"reply":"Hi! How can I help?"}
```

```json
{"actions":[{"type":"open_app","target":"Notes"}],"reply":"Opened Notes."}
```

```json
{"actions":[{"type":"type_text","id":7,"text":"Hello"}]}
```

A `reply` without actions goes straight to chat. With actions, it ends the turn
only after all actions succeed. Omit it when the model needs to see results first.
An optional `todo` array of strings displays a checklist for longer tasks.
Bare commands, command arrays, and plain text replies are also accepted. Malformed
tool payloads are rejected, including a malformed batch paired with a valid reply.
Legacy verbose field names and action names still decode.

| Command | Arguments / behavior |
| --- | --- |
| `open_app` | `target`: app name; activates or launches it |
| `observe` | Accessibility elements, visible text, Chrome front-window tabs |
| `screenshot` | Attach a screenshot to the next model request |
| `click`, `double_click` | `id` from the latest observation, or `coordinates:[x,y]` |
| `type_text` | `text`; optional `id` replaces a field's contents; otherwise types into focus |
| `press_key` | `key`, such as `return`, `tab`, `cmd+a`, `cmd+shift+t` |
| `scroll` | `coordinates:[0,-5]` scrolls down; positive scrolls up |
| `browser_new_tab` | Optional `url`; opens a Chrome tab |
| `browser_navigate` | `url`; navigates Chrome's active tab |
| `browser_switch_tab`, `browser_close_tab` | `target`: observed 1-based front-window tab number |
| `ask_user` | `text`: question; pauses for an answer |
| `finish` | Optional `text`: final answer |
| `wait` | Short delay |
| `open_url` | `url`; opens in the default browser |
| `copy`, `paste` | Clipboard actions; `paste` requires `text` |
| `run_terminal_command` | `command`; existing terminal policy applies |

Accessibility IDs resolve to the exact live handles from the planning snapshot.
Press and value-setting use AX APIs; unsupported controls fall back to the
handle's current coordinates. Stale handles are rejected. A batch cannot reuse
an element ID after a previous step changed the UI; it replans with fresh state.
Observed click labels feed policy, so the short `id` format retains risky-button
checks. Each step retains policy, Stop/Pause, and dry-run checks.

Screenshots are requested automatically when accessibility yields no actionable
elements, or explicitly with `screenshot`. JPEG data is sent as an `image_url`
content part, not inserted into the text prompt. Screenshot coordinate actions
use image pixels, mapped back to display points; scroll deltas are not scaled.
The selected server/model must support vision. Plain chat sends no screen data.
