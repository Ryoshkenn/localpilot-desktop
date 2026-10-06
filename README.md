# LocalPilot Desktop

LocalPilot Desktop is a macOS-only local-first desktop AI agent. The goal is to
let local models observe the screen and act through a visible, interruptible,
guarded loop while the user remains in control.

The source of truth for the product is [goal.md](goal.md). Current progress and
milestones are tracked in [progress.txt](progress.txt).

## Build

Generate the Xcode project after adding or moving Swift files:

```sh
xcodegen generate
```

Run tests:

```sh
xcodebuild test -project LocalPilotDesktop.xcodeproj -scheme LocalPilotDesktop -destination 'platform=macOS'
```

Build the app:

```sh
xcodebuild build -project LocalPilotDesktop.xcodeproj -scheme LocalPilotDesktop -destination 'platform=macOS'
```

## Current Status

LocalPilot chats with a model served locally (LM Studio, Ollama, llama-server,
mlx_lm.server, or any OpenAI-compatible server). Greetings and normal questions
receive a direct reply without screen capture or Agent Mode. Recent conversation
is included for follow-up questions.

Local models now default to native function calling: ordinary assistant text
is chat, `tool_calls` request actions, and results return in `tool` messages with
the original call ID. The server applies the model's chat template and tool
parser; LocalPilot does not force a JSON reply or disable model thinking.
Choose **Settings → Tool calling → JSON compatibility** only for a server/model
without working native tools. There is no silent format fallback.

For computer tasks, a registry supplies 15 concise, separately described tools
with their own argument schemas on every request. It can open an app, observe accessibility elements, click, fill
fields, use keyboard shortcuts, and scroll. Chrome supports new tabs, navigation,
switching and closing tabs; web forms use the same accessibility actions as native
apps. Missing accessibility triggers a screenshot fallback, and `screenshot` can
request one explicitly. Images are sent to the selected model, which must support
vision to interpret them.

A single action is enough for a quick request. A checklist is optional through
`update_todo`. Native calls execute one at a time through validation, policy, and
the dry-run gate; results return to the model before it writes its final answer.
Dry-run remains the default. See [the tool contract](docs/action-schema.md)
and [macOS permissions](docs/macos-permissions.md).

With no model available, the built-in rules handle a few fixed task shapes
(open a URL, switch apps, press a key, type, scroll, click coordinates, run a
restricted command) so the loop can still be exercised.

## Interface

The app uses its own dark design system (`apps/macos/Sources/DesignSystem`)
instead of stock controls:

- **Agent**: chat transcript where each proposed step renders as a card, with
  inline approval and pause cards. The header holds the model picker (every
  model on your local servers, with live status) and the Dry run / Live
  switch. Run details (status, step progress, duration, step results) appear
  once a task starts.
- **Agent Mode overlay**: a click-through haze with a glowing edge and an AI
  cursor that points at the element or coordinates the next action targets,
  plus a floating, non-activating HUD with Pause/Continue/Stop and inline
  approvals. Computer actions hand focus back to the app you were using; chat keeps focus in LocalPilot.
- **History** and **Activity Log**: past tasks and every event, read back from
  the local JSONL log.
- **Permissions**: live Accessibility and Screen Recording status with request
  and System Settings shortcuts.
- **Settings**: model source and server address, discovered models, dry run,
  structured output, temperature, timeout, and the domains, apps, and folders
  allowed without asking. Changes save automatically.

Keyboard: ⌘N new task, ⇧⌘P pause, ⌘. stop, and ⌥⌘. stops the agent from any app.
