# `collama` & `ollama-copilot` CLI Reference, SDD Integration, and Subagent Patterns

## 1. Environment Probing & SDD Tool Priority (`-CheckEnvironment`)

Running `Invoke-CopilotSubagents.ps1 -CheckEnvironment` inspects the local machine and returns JSON describing:
1. **`PreferredPlanningTool`**:
   - Prioritizes **`openspec`** (`@fission-ai/openspec`), **`openspec-tw`** (`@minidoracat/openspec-tw`), or **`specify`** (`specify.exe`) when installed on the machine.
   - Falls back to **`agy-native-plan`** (Antigravity's built-in Plan workflow/artifacts) only if no SDD tool is installed.
2. **`Engines.collama` & `Engines.ollama_copilot`**:
   - Verifies both PowerShell function definition (via `$PROFILE`) and live HTTP endpoint reachability (`https://llm-share.duotify.com/v1/models` and `http://localhost:11434/v1/models`).

### Common OpenSpec CLI Commands Used in Stage 0
- Initialize OpenSpec in a project (non-interactive):
  ```powershell
  openspec init --tools none
  ```
- Create a new change folder (`openspec/changes/<change-id>/`):
  ```powershell
  openspec new change <change-id>
  ```
- Standard OpenSpec change artifacts authored by `agy`'s smartest model:
  - `openspec/changes/<change-id>/proposal.md`
  - `openspec/changes/<change-id>/design.md` (Plan)
  - `openspec/changes/<change-id>/specs/<domain>/spec.md`
  - `openspec/changes/<change-id>/tasks.md`
- Check status / validate:
  ```powershell
  openspec status --change <change-id>
  openspec validate <change-id>
  ```

---

## 2. How `collama` and `ollama-copilot` Are Defined

Both commands are PowerShell functions defined in the user's PowerShell `$PROFILE` (`C:\Users\d1658\Documents\PowerShell\Microsoft.PowerShell_profile.ps1`). They configure GitHub Copilot CLI (`copilot`) to use custom OpenAI-compatible BYOK endpoints (`COPILOT_PROVIDER_WIRE_API="responses"`):

| Property | `collama` | `ollama-copilot` |
| :--- | :--- | :--- |
| **Provider Base URL** | `https://llm-share.duotify.com/v1` | `http://localhost:11434/v1` |
| **Default Model** | `deepseek-v4.1-flash:1017` | `deepseek-v4.1-flash:1017-cloud` |
| **Underlying Command** | `copilot --yolo @args` | `copilot --yolo --autopilot @args` |
| **Parallel Subagent Cap** | **At most 2 (`<= 2`)** | **Default 4 (`>= 4`, unrestricted)** |
| **Autopilot Mode** | Off by default (can pass `--autopilot`) | On by default (`--autopilot` baked in) |
| **Auto-Failover** | Falls over to `ollama-copilot` if unreachable | Falls over to `collama` (clamped to `<=2`) if unreachable |

---

## 3. Intelligent Dispatch Policy (Driven by AGY's Smartest Gemini Model)

Once `proposal`, `spec`, `plan/design`, and `tasks` are confirmed in Stage 0, `agy`'s smartest Gemini model decides how to dispatch the tasks:

1. **Co-Dispatch (一起派工 — Default when both engines are healthy and multiple task groups exist)**:
   - Dispatch larger parallelizable task groups (e.g., 3–4+ subtasks) to `ollama-copilot` (4 concurrent subagents).
   - Simultaneously dispatch smaller/focused task groups (1–2 subtasks, or wave-batched pairs) to `collama` (at most 2 concurrent subagents).
2. **Availability-Based Routing (看哪個可以用就用誰)**:
   - If one engine is unreachable or rate-limited, `Invoke-CopilotSubagents.ps1` (or `agy` directly after reading `-CheckEnvironment`) routes all tasks to the healthy engine and automatically adjusts `MaxSubagents` (`<= 2` for `collama`, `4` for `ollama-copilot`).
3. **Spec Context Injection (`-SpecContextPath`)**:
   - Passing `-SpecContextPath "openspec/changes/<change-id>"` (or a plan `.md` file path) automatically embeds all `.md` files (`proposal.md`, `design.md`, `specs/*.md`, `tasks.md`) into the prompt under `[CONFIRMED SDD / OPENSPEC / PLAN ARTIFACTS (AUTHORITATIVE SPEC)]`.

---

## 4. Internal Subagent Tools Available Inside Copilot CLI

When `collama` or `ollama-copilot` runs a prompt, the underlying GitHub Copilot CLI agent has built-in multi-agent orchestration tools:

- **`task`**: Launches a subagent in a separate context window (`agent_type`: `general-purpose`, `explore`, `task`, `research`, `code-review`, `security-review`; `mode`: `"background"` or `"sync"`).
- **`read_agent`**: Waits for and reads the output/status of background subagents (`agent_id`, `wait: true`, `timeout`).
- **`write_agent`**: Sends follow-up instructions to a running or idle subagent.
- **`list_agents`**: Lists active and completed subagents in the current session.

### Pitfall to Avoid: `-s` (`--silent`) with `ollama-copilot`

Do **NOT** pass `-s` / `--silent` to `ollama-copilot`. Because `ollama-copilot` includes `--autopilot`, its final turn invokes `task_complete`, causing `-s` to output an empty string while discarding the synthesis printed in the preceding turn.

---

## 5. AGY High-Tier Model Review & Session-Resume Correction Pattern

1. **Audit Step**: `agy`'s smartest model audits the returned output against `proposal.md`, `spec.md`, `design.md`, and `tasks.md` for both **Dispatch Compliance** and **Logic/Spec Accuracy**.
2. **Correction Step**: When an error or spec violation is detected, `agy` uses the `Resume copilot --resume=<uuid>` printed at the bottom of the engine's output and runs:
   ```powershell
   pwsh -File .\.agents\skills\copilot-subagent-orchestrator\scripts\Invoke-CopilotSubagents.ps1 `
     -Engine <collama|ollama-copilot> `
     -ResumeSessionId "<uuid>" `
     -SpecContextPath ".\openspec\changes\<change-id>" `
     -CorrectionFeedback "<Detailed explanation of the spec/logic violation, plus instructions to fix and re-verify>"
   ```
3. **Re-Verification Step**: `agy` checks the resumed session's corrected output to confirm all spec scenarios and tasks pass.
4. **Version Control Step (Git Tracking)**:
   - Ensure all planning/SDD artifacts (`openspec/`, `proposal.md`, `spec.md`, `design.md`, `tasks.md`, `README.md`) and skill files (`.agents/skills/`) are tracked in Git (`git init` if not yet initialized) and committed atomically so future iterations and debugging have full version history.
