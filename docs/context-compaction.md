# Context Compaction

LocalPilot needs compaction because screenshots, OCR text, accessibility trees, browser metadata, and action logs can quickly fill a local model context window.

## Required Layering

Never summarize these layers away:

1. Immutable safety policy.
2. Original user task.
3. Permission scope.
4. User approvals and denials.
5. Current structured state.

Compacted or rolling layers:

6. Compacted old history.
7. Recent raw history.
8. Latest observation.
9. Proposed action.

## 80/20 Rule

When estimated context usage reaches 80 percent of the configured model context window:

- summarize the oldest 80 percent of history;
- keep the newest 20 percent raw;
- inject original task directly;
- inject immutable safety policy directly;
- inject current permissions directly;
- inject denied actions directly;
- inject user approvals directly;
- inject current structured state directly.

## Source Of Truth

Natural-language summaries are not authoritative. A structured state object remains the source of truth.

Required files for later milestones:

- `state.json`
- `recent_steps.jsonl`
- `compacted_history.md`
- `approvals.jsonl`
- `logs.jsonl`

## Implemented Now

`ContextCompactor` exposes the 80 percent threshold calculation, a cheap token
estimate (`estimateTokens`, ~4 chars/token), and rolling compaction
(`compact(recentSteps:maxKeep:existingSummary:)`) that collapses older steps into
a single short summary line while keeping the newest steps raw.

`AgentHistory` is the bounded, in-memory source of truth the planner sees instead
of the full chat log: a rolling `compactedSummary` plus a capped `recentSteps`
tail (default 4). It never stores image/base64 payloads and truncates oversized
step strings.

`AgentContextBuilder.makeContext(settings:task:history:)` builds a lean,
fresh context from the task line, the rolling summary, the recent-step tail, and
**only the latest observation**. Screenshots are latest-only and never
accumulate across steps. The legacy `makeContext(settings:messages:)` overload is
kept for the message-oriented call sites but now caps to the trailing messages.

The default context budget is large (`AppSettings.maximumContextWindowSize`,
131072) so capable local models can use their full window, while compaction keeps
the actual payload small enough for small-window models.

Disk persistence (`state.json`, `recent_steps.jsonl`, `compacted_history.md`,
`approvals.jsonl`, `logs.jsonl`) and natural-language summarization via a model
remain for a later milestone.
