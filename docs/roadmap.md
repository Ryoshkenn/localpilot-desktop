# Roadmap

## Milestone 1: Native App Shell

Implemented in this run:

- app launches as a native macOS SwiftUI app;
- full main window exists;
- chat-style task input exists;
- Start enters Agent Mode;
- overlay haze and fake AI cursor appear;
- floating controls show current action, Pause, and Stop;
- Stop hard-stops the fake loop and disables execution;
- Pause freezes the fake loop;
- Continue accepts an optional instruction and resumes;
- events are logged locally;
- internal in-process model provider mode is the default;
- managed local model provider scaffolding is present as an optional advanced mode;
- the internal planner can complete simple observe -> action -> finish tasks
  without Ollama or another model server;
- click, double-click, safe typing, approved paste, copy, scroll, keypress, URL
  opening, restricted terminal command, and app-switch execution are implemented
  behind the dry-run toggle.

## Milestone 2: Scripted Executor

Add hardcoded JSON actions for observe, click, type, scroll, and wait. Wire interruption points so Stop can interrupt immediately and Pause can interrupt at safe action boundaries.

## Milestone 3: Action Schema And Policy

Add full JSON validation, policy classification, native approval popups, and fake demonstrations of allow, ask-user, and block decisions.

## Milestone 4: Screen Observation

Add ScreenCaptureKit screenshots, active app/window detection, basic accessibility tree capture, and browser URL/domain detection where available.

## Milestone 5: Owned Local Model Runtime

Implemented now:

- internal in-process planner/guard provider with no external runtime;
- configurable runtime executable path for optional managed-runtime mode;
- configurable planner and guard model file paths;
- configurable localhost host, port, health path, completion path, launch arguments, and environment;
- process launch through `ProcessManagedModelRuntime`;
- non-streaming JSON generation through the configured local completion endpoint;
- cancellable provider task tracking;
- immediate runtime stop through `ModelSessionManager.closeLoadedModels()`;
- planner proposes exactly one JSON action.

Still later:

- replace the deterministic internal task planner with a real embedded local model backend;
- package a default LocalPilot model runner binary and starter model files for managed-runtime mode if still needed;
- generic OpenAI-compatible endpoint;
- invalid JSON retry once with schema correction prompt;
- LM Studio, MLX, and llama.cpp direct integrations.

## Milestone 6: Guard Model (removed)

Implemented, then removed on 2026-09-26 to keep evaluation runs simple. Deterministic policy and user approval remain the safety layer; a guard may return later as an optional stage.

## Milestone 7: Context Compaction

Persist structured state, recent raw steps, compacted history, approvals, and logs. Compact at 80 percent context usage while preserving immutable safety policy and current state.

## Milestone 8: Terminal Support

Implemented in the guarded executor as restricted command execution after policy
classification. Deletion remains blocked. Medium-risk commands require approval.

## Milestone 9: Polish

Add task history, richer logs, settings, permission scopes, model configuration, private mode, and stronger error handling.
