---
name: copilot-subagent-orchestrator
version: 1.0.0
description: >-
  [v1.0.0] End-to-end Spec-Driven multi-agent orchestrator for Antigravity (`agy`).
  When receiving a task, `agy` uses its smartest available Gemini model (Pro / top-tier)
  to perform rigorous planning first (prioritizing installed SDD tools like OpenSpec/Specify,
  or falling back to AGY's native Plan). Once `proposal`, `spec`, `plan`, and `tasks` are
  confirmed, `agy`'s smartest model dynamically dispatches work to `ollama-copilot` (default 4
  subagents) and/or `collama` (max 2 subagents) based on availability and workload, audits
  results, and runs a guided correction loop if any errors are found.
---

# Copilot Subagent Orchestrator (`collama` & `ollama-copilot` + SDD Planning) — `v1.0.0`

> **Version**: `v1.0.0` (Initial Release / 初版)

This skill enables Antigravity (`agy`) to act as the **Lead Architect & Supervisor** using its smartest available Gemini model (e.g., Gemini 4 Argon / Pro tier) to:
1. **Plan rigorously first** (prioritizing **OpenSpec / SDD** if installed on the machine, otherwise falling back to **AGY's native Plan**).
2. **Dynamically dispatch** confirmed `proposal`, `spec`, `plan`, and `tasks` to `ollama-copilot` and/or `collama` (co-dispatching in parallel when both are available, or failing over automatically to whichever engine is online).
3. **Audit & correct** all outputs via a closed-loop review workflow.

---

## 1. Engine Subagent Concurrency & Availability Rules

| Engine | Concurrency Limit | Availability & Routing Policy |
| :--- | :--- | :--- |
| **`collama`** | **At most 2 (`<= 2`)** | **Hard Cap**: Never run > **2** concurrent subagents. If assigned > 2 subtasks, batch in waves of at most 2 (`task` in `mode: "background"`), wait with `read_agent`, then start the next wave. |
| **`ollama-copilot`** | **Default 4 (Unrestricted)** | **Default 4**: Runs up to **4** parallel subagents simultaneously by default; no hard upper ceiling. |
| **`auto` / Dual Dispatch** | **Dynamic (`agy` Decides)** | **Default**: Both engines are available. `agy`'s smartest Gemini model decides whether to **co-dispatch both in parallel** (e.g., 4 subtasks to `ollama-copilot` + 2 subtasks to `collama`) or use whichever engine is reachable/optimal. |

---

## 2. Mandatory 5-Stage End-to-End Workflow

Every non-trivial task handled with this skill **MUST** follow this 5-stage workflow driven by `agy`'s smartest available Gemini model (active top-tier primary model or `invoke_subagent` with `Model: "pro"` / `"inherit"`):

```mermaid
flowchart TD
    S0["Stage 0: Rigorous Planning & Git Baseline (AGY Smartest Model)<br/>1. Check Environment (-CheckEnvironment)<br/>2. Priority: OpenSpec / SDD -> fallback: AGY Native Plan<br/>3. Confirm proposal, spec, plan/design, tasks & Track in Git"] --> S1
    S1["Stage 1: Intelligent Dispatch (AGY Smartest Model Decides)<br/>Co-dispatch ollama-copilot (4) + collama (<=2)<br/>or route to whichever engine is available (-SpecContextPath)"] --> S2
    S2["Stage 2: High-Tier Model Audit<br/>Verify Task Dispatch Compliance + Spec/Logic Accuracy"]
    S2 -->|Pass| S4["Stage 4: Approved, Final Synthesis & Git Commit<br/>(Update tasks.md / docs / skill files & Commit to VCS)"]
    S2 -->|Fail / Error Found| S3["Stage 3: Guided Correction Loop<br/>(-ResumeSessionId + -CorrectionFeedback)"]
    S3 --> S2
```

### Stage 0: Environment Probe & Rigorous SDD / Plan Generation (最聰明模型嚴謹規劃)

When `agy` receives a task, **before** dispatching work to `collama` or `ollama-copilot`:
1. **Probe SDD Tools & Engine Availability**:
   Run [Invoke-CopilotSubagents.ps1](./scripts/Invoke-CopilotSubagents.ps1) with `-CheckEnvironment`:
   ```powershell
   pwsh -File "c:\Users\d1658\Documents\project\call_subagent_skill\.agents\skills\copilot-subagent-orchestrator\scripts\Invoke-CopilotSubagents.ps1" -CheckEnvironment
   ```
2. **Author `proposal`, `spec`, `plan` (`design`), and `tasks` Using the Highest-Priority Planning Tool**:
   - **Priority 1 — OpenSpec / SDD Installed (`PreferredPlanningTool: "openspec"` / `"openspec-tw"` / `"specify"`)**:
     - If `openspec` is installed and the workspace is not yet initialized, run `openspec init --tools none` (if appropriate for the project) and `openspec new change <change-name>`.
     - Using `agy`'s smartest Gemini model, author the 4 core SDD artifacts under `openspec/changes/<change-name>/` (or a dedicated spec folder):
       1. `proposal.md` — Problem statement, scope, goals, and non-goals.
       2. `specs/<domain>/spec.md` — Concrete requirements, scenarios (`WHEN/THEN`), and invariants.
       3. `design.md` (`plan`) — Architecture, implementation approach, and verification strategy.
       4. `tasks.md` — Granular checklist partitioned into independent subtasks ready for `ollama-copilot` / `collama` subagents.
   - **Priority 2 — Fallback to AGY Native Plan (`PreferredPlanningTool: "agy-native-plan"`)**:
     - If no SDD CLI is installed, use AGY's built-in Plan capability (writing an implementation plan markdown file/artifact) containing the exact same 4 sections: **Proposal**, **Spec**, **Plan**, and **Tasks**.

### Stage 1: Dynamic Engine Selection & Intelligent Dispatch (由 AGY 最聰明模型決定派工策略)

Once `plan`, `proposal`, `spec`, and `tasks` are confirmed, `agy`'s smartest Gemini model decides how to assign the tasks in `tasks.md` across `ollama-copilot` and `collama`:
- **Strategy A — Dual-Engine Co-Dispatch (預設兩者皆可用時，可同時平行派工)**:
  - Assign wider/multi-part task groups (e.g., 3–4+ parallel subtasks) to **`ollama-copilot`** (`-Engine ollama-copilot -MaxSubagents 4`).
  - Simultaneously assign focused 1–2 subtask groups (e.g., core logic, verification, or 2-part modules) to **`collama`** (`-Engine collama -MaxSubagents 2`).
- **Strategy B — Single-Engine or Auto-Failover (看哪個可以用就用誰)**:
  - If only one engine is reachable (reported by `-CheckEnvironment`), or if the task is small enough for a single engine, route to the available engine (or pass `-Engine auto`, which automatically selects a healthy engine and fails over if one errors out).
- Always pass `-SpecContextPath "<path-to-openspec-change-or-plan>"` so the confirmed `proposal`, `spec`, `design/plan`, and `tasks` are injected directly into the subagents' prompt context.

### Stage 2: High-Tier Model Audit (AGY 最聰明模型審查)

After `ollama-copilot` and/or `collama` finish, `agy`'s smartest model audits the outputs against the confirmed `spec` and `tasks`:
1. **Task Dispatch Compliance (工作派遣合規性)**:
   - Did `collama` strictly obey `<= 2` concurrent subagents per wave?
   - Did `ollama-copilot` run its expected parallel subagents?
   - Were all assigned items from `tasks.md` completed?
2. **Logical & Spec Accuracy (邏輯與規格正確性)**:
   - Do the outputs and any modified files strictly satisfy every requirement and scenario in `spec.md` / `design.md`?
   - Are there any logical flaws, edge-case bugs, or hallucinations?

### Stage 3: Guided Correction Loop (退回重新訂正與檢查)

If **any** flaw or spec violation is found in Stage 2:
1. Extract the session UUID (`Resume copilot --resume=<session-uuid>`) from the failed engine's output.
2. Call `Invoke-CopilotSubagents.ps1` with `-ResumeSessionId "<session-uuid>"`, `-SpecContextPath "<spec-path>"`, and `-CorrectionFeedback "<detailed flaw + fix instructions>"` so the engine resumes its session and fixes the issue.

### Stage 4: Re-Audit, Sign-Off & Mandatory Version Control (複查確認與文件/技能包強制納入版控)

1. Re-audit the corrected output. Once all `spec` requirements and `tasks.md` items pass, mark `tasks.md` items complete (`- [x]`).
2. **Mandatory Version Control Policy (文件與技能包皆須納入 Git 版控)**:
   - Every SDD/Planning document (`openspec/`, `proposal.md`, `spec.md`, `design.md`, `tasks.md`, `README.md`) and any workspace Skill package (`.agents/skills/`) **MUST** be tracked in Git version control so future updates, modifications, rollbacks, and debugging have a complete history.
   - If the workspace is not yet a Git repository (`GitInitialized: false` in `-CheckEnvironment`), run `git init` and ensure `.gitignore` does **NOT** exclude `.agents/skills/` or `openspec/`.
   - Stage and commit all updated documentation, specs, skill package files, and code changes (`git add` + `git commit`) with a clear, structured commit message before concluding the task.

---

## 3. Command Reference (`Invoke-CopilotSubagents.ps1`)

### 1. Check SDD Tools & Engine Availability
```powershell
pwsh -File "c:\Users\d1658\Documents\project\call_subagent_skill\.agents\skills\copilot-subagent-orchestrator\scripts\Invoke-CopilotSubagents.ps1" -CheckEnvironment
```

### 2. Co-Dispatch Confirmed OpenSpec / Plan Tasks to `ollama-copilot` & `collama`
```powershell
# Engine 1: ollama-copilot (4 parallel subagents)
pwsh -File "c:\Users\d1658\Documents\project\call_subagent_skill\.agents\skills\copilot-subagent-orchestrator\scripts\Invoke-CopilotSubagents.ps1" `
  -Engine ollama-copilot `
  -MaxSubagents 4 `
  -SpecContextPath ".\openspec\changes\<change-id>" `
  -Prompt "Execute Tasks Group A according to the attached OpenSpec." `
  -Tasks "Task 1.1: ...", "Task 1.2: ...", "Task 1.3: ...", "Task 1.4: ..."

# Engine 2: collama (Max 2 parallel subagents)
pwsh -File "c:\Users\d1658\Documents\project\call_subagent_skill\.agents\skills\copilot-subagent-orchestrator\scripts\Invoke-CopilotSubagents.ps1" `
  -Engine collama `
  -MaxSubagents 2 `
  -SpecContextPath ".\openspec\changes\<change-id>" `
  -Prompt "Execute Tasks Group B according to the attached OpenSpec." `
  -Tasks "Task 2.1: ...", "Task 2.2: ..."
```

### 3. Guided Correction Call (`-ResumeSessionId` + `-CorrectionFeedback`)
```powershell
pwsh -File "c:\Users\d1658\Documents\project\call_subagent_skill\.agents\skills\copilot-subagent-orchestrator\scripts\Invoke-CopilotSubagents.ps1" `
  -Engine <collama|ollama-copilot> `
  -ResumeSessionId "<session-uuid>" `
  -SpecContextPath ".\openspec\changes\<change-id>" `
  -CorrectionFeedback "AGY Spec Audit Failed: Task 1.2 violated Requirement X in spec.md. Re-dispatch a subagent to fix and verify."
```

> See [cli-flags-and-patterns.md](./references/cli-flags-and-patterns.md) for detailed OpenSpec CLI commands, failover behavior, and Copilot CLI subagent flags.
