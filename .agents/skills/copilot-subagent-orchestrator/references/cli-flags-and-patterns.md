# `collama` & `ollama-copilot` CLI Reference and Subagent Patterns

## 1. How `collama` and `ollama-copilot` Are Defined

Both commands are PowerShell functions defined in the user's PowerShell `$PROFILE` (`C:\Users\d1658\Documents\PowerShell\Microsoft.PowerShell_profile.ps1`). They configure GitHub Copilot CLI (`copilot`) to use custom OpenAI-compatible BYOK endpoints (`COPILOT_PROVIDER_WIRE_API="responses"`):

| Property | `collama` | `ollama-copilot` |
| :--- | :--- | :--- |
| **Provider Base URL** | `https://llm-share.duotify.com/v1` | `http://localhost:11434/v1` |
| **Default Model** | `deepseek-v4.1-flash:1017` | `deepseek-v4.1-flash:1017-cloud` |
| **Underlying Command** | `copilot --yolo @args` | `copilot --yolo --autopilot @args` |
| **Parallel Subagent Cap** | **At most 2 (`<= 2`)** | **Default 4 (`>= 4`, unrestricted)** |
| **Autopilot Mode** | Off by default (can pass `--autopilot`) | On by default (`--autopilot` baked in) |

---

## 2. Internal Subagent Tools Available Inside Copilot CLI

When `collama` or `ollama-copilot` runs a prompt, the underlying GitHub Copilot CLI agent has built-in multi-agent orchestration tools:

- **`task`**: Launches a subagent in a separate context window.
  - `agent_type`: `general-purpose`, `explore`, `task`, `research`, `code-review`, `security-review` (or custom agents in `~/.copilot/agents/`).
  - `mode`: `"background"` (non-blocking; calling multiple `task` tools with `mode: "background"` in one turn executes them in parallel) or `"sync"` (blocking).
  - `name` / `description` / `prompt`: Focused instructions and deliverable spec for the subagent.
- **`read_agent`**: Waits for and reads the output/status of background subagents (`agent_id`, `wait: true`, `timeout`).
- **`write_agent`**: Sends follow-up instructions to a running or idle subagent.
- **`list_agents`**: Lists active and completed subagents in the current session.

Passing `--fleet` on the CLI (`collama --fleet -p "..."` or `ollama-copilot --fleet -p "..."`) explicitly activates **Fleet Mode** (parallel subagent orchestration with SQL-backed todo tracking).

---

## 3. Important CLI Flags for Non-Interactive Shell Control

When invoking `collama` or `ollama-copilot` from Antigravity (`agy`) via PowerShell:

- **`--fleet`**: Enables parallel subagent orchestration mode.
- **`-p, --prompt <text>`**: Runs the prompt non-interactively and exits upon completion.
- **`--no-ask-user`**: Disables the `ask_user` tool so the agent never blocks waiting for interactive terminal input.
- **`-C <directory>`**: Changes the working directory for the Copilot CLI session before executing.
- **`--resume=<session-id>`**: Resumes a previous session or task by UUID or 7+ char hex prefix (printed at the end of every non-interactive run as `Resume     copilot --resume=<uuid>`).
- **`--output-format json`**: Outputs JSONL (one JSON event per line) if structured programmatic parsing of tool calls is needed.

### Pitfall to Avoid: `-s` (`--silent`) with `ollama-copilot`

Do **NOT** pass `-s` / `--silent` to `ollama-copilot` in general tasks. Because `ollama-copilot` includes `--autopilot`, its final turn often invokes `task_complete`, causing `-s` to output an empty string while discarding the subagent synthesis printed in the preceding turn. Always omit `-s` (or use `Invoke-CopilotSubagents.ps1`) so full subagent outputs and session resume IDs are captured.

---

## 4. Subagent Batching Pattern When Subtasks Exceed Concurrency Cap

### For `collama` (Max 2 Parallel Subagents)
If a task has 4 subtasks (`T1`, `T2`, `T3`, `T4`), `collama` must execute them in waves of 2:
1. **Wave 1**: Launch `T1` and `T2` simultaneously with `task(mode="background")`, then call `read_agent(wait=true)` on both.
2. **Wave 2**: After Wave 1 finishes, launch `T3` and `T4` simultaneously with `task(mode="background")`, then call `read_agent(wait=true)` on both.
3. **Synthesis**: Combine results from `T1..T4`.

### For `ollama-copilot` (Default 4 Parallel Subagents)
1. Launch `T1`, `T2`, `T3`, and `T4` simultaneously in a single turn with `task(mode="background")`.
2. Call `read_agent(wait=true)` to collect all 4 results and synthesize.
If there are > 4 subtasks (e.g., 6 subtasks), either batch in waves of 4 or pass `-MaxSubagents 6` to `Invoke-CopilotSubagents.ps1`.

---

## 5. AGY High-Tier Model Review & Session-Resume Correction Pattern

When `agy` dispatches work to `collama` and/or `ollama-copilot` in parallel:
1. **Audit Step**: `agy` (using its highest-tier active model or a `Model: "pro"` / `"inherit"` subagent) reviews the returned output for:
   - **Dispatch Compliance**: Did `collama` stay within `<= 2` concurrent subagents? Did `ollama-copilot` dispatch all requested tasks? Were any subtasks skipped?
   - **Logic & Content Accuracy**: Are formulas, constraints, code changes, and conclusions logically valid and verified?
2. **Correction Step**: When an error or omission is detected, `agy` takes the `Resume copilot --resume=<uuid>` printed at the bottom of the engine's output and runs:
   ```powershell
   pwsh -File .\.agents\skills\copilot-subagent-orchestrator\scripts\Invoke-CopilotSubagents.ps1 `
     -Engine <collama|ollama-copilot> `
     -ResumeSessionId "<uuid>" `
     -CorrectionFeedback "<Detailed explanation of the logical flaw or missing subtask, plus instructions to fix and re-verify>"
   ```
3. **Re-Verification Step**: `agy` checks the resumed session's corrected output to confirm all audit criteria are now satisfied.
