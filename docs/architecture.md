# LocalPilot Desktop Architecture

LocalPilot Desktop is a macOS-only native app: SwiftUI for the interface, AppKit
where window behavior requires it (the Agent Mode overlay and HUD).

## Layout

- `apps/macos/Sources`: the app. `DesignSystem` (theme and shared components),
  `Chat`, `UI` (sidebar, settings, history, activity log, model controls),
  `Overlay` (haze, AI cursor, HUD, global stop hot key), `Permissions`.
- `core/agent`: the agent, with no UI code.
  - `orchestrator/AgentController`: run state machine and the control loop.
  - `planner`: prompt construction, the action format reference, and JSON
    recovery from raw model output.
  - `providers`: model backends and settings.
  - `policy`: action schema and the deterministic policy engine.
  - `executor`: the only code that touches the OS (CGEvent, NSWorkspace, a
    restricted shell).
  - `context`: screen observation, accessibility element capture, history
    compaction.
  - `logging`: JSONL event log writer and reader.

## Model providers

- **Local server** (`OpenAICompatibleProvider`): any server implementing the
  OpenAI chat completions API, such as LM Studio, Ollama, `llama-server`,
  `mlx_lm.server`, vLLM, or Jan. `LocalModelDiscovery` probes the usual ports
  (1234, 11434, 8080, 8000, 1337) plus the configured address and lists the
  models each server offers. Structured output is requested as a
  `json_schema` response format; if a server rejects it, the request is retried
  once without it.
- **Built-in rules** (`BuiltInRulesProvider`): deterministic rules for a few
  task shapes. It needs no model and exists to exercise the loop.

## Control boundary

Models never call operating-system APIs, shell commands, input events, files,
websites, or the clipboard. A model proposes structured actions. LocalPilot
validates each one, classifies it with deterministic policy, asks the user when
policy requires it, and only then passes it to the executor.

## Control loop

1. The user enters a task.
2. The orchestrator observes the screen: frontmost app and window, and
   actionable accessibility elements with their frames.
3. The planner proposes one action or a short ordered plan.
4. The reply is recovered (thinking tags, code fences, and preamble are
   stripped) and decoded against the action schema. Invalid JSON is retried
   once, then the run stops.
5. For each action, the policy engine returns `allow`, `ask_user`, or `block`.
   `ask_user` shows an approval card in the chat and in the Agent Mode HUD.
6. The executor performs the action; dry run validates it without touching the
   OS.
7. The result is recorded and logged, and the screen is observed again before
   the next action.
8. The loop repeats until the task finishes, is blocked, or is stopped. Pause
   and Stop are honored at every safe boundary.

## Native tool transport

Local-server runs default to `NativeToolSession`. `OpenAICompatibleProvider`
sends typed user/assistant/tool messages and the functions from
`NativeToolRegistry` to chat completions. Each registry entry owns its public
argument schema and action adapter. The existing validator, policy engine,
approval flow and executor remain the execution boundary.

A session correlates results with the server's tool call IDs, preserves native
assistant call messages and separate reasoning content, and keeps the latest
screen image ephemeral. A native final answer is ordinary text with no calls.
`JSONActionPlanner` remains available only in explicit JSON compatibility mode
or for deterministic built-in rules. The settings migration defaults existing
local-server selections to native tools without changing their selected model.
