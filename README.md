# Copilot Subagent Orchestrator Skill (`collama`, `ollama-copilot`, `ollama-copilot_2` + SDD Planning) — `v1.1.0`

> **目前版本**：`v1.1.0`（新增 `ollama-copilot_2` 並將 `collama` 並行降至 1 避免 TPM/RPM 超限）

讓 Google Antigravity (`agy` CLI / Antigravity IDE) 在接到任務時，先由 **`agy` 當下可用最聰明的 Gemini 模型（如 Pro / 最高階模型）進行嚴謹規劃（優先使用電腦上已安裝的 OpenSpec / Specify 等 SDD 工具；若未安裝則使用 AGY 原生 Plan 功能）**；當 `proposal`、`spec`、`plan (design)`、`tasks` 確定後，再由 `agy` 最聰明的模型動態決定如何指派給三組 GitHub Copilot CLI 引擎（`collama`、`ollama-copilot`、`ollama-copilot_2`）進行協同平行派工或自動切換可用引擎，並在完成後執行嚴格審查與退回訂正閉環。

---

## 專案與全域安裝結構

此 Skill 已同時部署於**當前專案工作區**與**全域 Antigravity 設定目錄**（讓你在任何專案下使用 `agy` 都能自動觸發此 Skill）：

- **工作區路徑**：[`.agents/skills/copilot-subagent-orchestrator/`](file:///c:/Users/d1658/Documents/project/call_subagent_skill/.agents/skills/copilot-subagent-orchestrator)
  - [`SKILL.md`](file:///c:/Users/d1658/Documents/project/call_subagent_skill/.agents/skills/copilot-subagent-orchestrator/SKILL.md)：定義 5 階段閉環（Stage 0 SDD/Plan 嚴謹規劃 → Stage 1 智慧動態派工 → Stage 2 最高等模型審查 → Stage 3 退回訂正 → Stage 4 複查結案）
  - [`scripts/Invoke-CopilotSubagents.ps1`](file:///c:/Users/d1658/Documents/project/call_subagent_skill/.agents/skills/copilot-subagent-orchestrator/scripts/Invoke-CopilotSubagents.ps1)：支援三引擎切換、`-CheckEnvironment`（探測 SDD 工具與三引擎連線狀態）、`-SpecContextPath`（自動注入 OpenSpec/Plan 規格文件）、`-Engine auto`（自動容錯切換）、並行上限保護與 `-ResumeSessionId` / `-CorrectionFeedback` 退回訂正
  - [`references/cli-flags-and-patterns.md`](file:///c:/Users/d1658/Documents/project/call_subagent_skill/.agents/skills/copilot-subagent-orchestrator/references/cli-flags-and-patterns.md)：OpenSpec 整合指令、三引擎派工策略與 CLI 參數參考
- **全域路徑**：`C:\Users\d1658\.gemini\config\skills\copilot-subagent-orchestrator\`

---

## 三組引擎並行數量與保護規則

| 引擎名稱 (`-Engine`) | 最大同時平行 Subagent 數 | 行為與保護機制 |
| :--- | :--- | :--- |
| **`collama`** | **最多 1 個 (`<= 1`)** | **TPM/RPM 防撞上限**：強制將並行數鎖定為 `<= 1`（若要求 > 1 會自動警告並降為 1）。若子任務超過 1 個，自動採用單線分批執行（每批 1 個，等待完成後再啟動下一個），徹底避免撞到 `llm-share` 之 Token/Request 限制。 |
| **`ollama-copilot`** | **預設 4 個（不設硬上限）** | **高並行主力**：預設同時啟動最多 **4** 個平行 Subagent，亦可透過 `-MaxSubagents <N>` 自由擴展。 |
| **`ollama-copilot_2`** | **預設 4 個（不設硬上限）** | **第二實例**：設定與 `ollama-copilot` 相同，提供第二個獨立的 Copilot CLI 實例，方便與第一實例平行分流任務。 |

---

## 五階段運作流程 (5-Stage Workflow)

1. **Stage 0：環境探測與嚴謹規劃（由 `agy` 當下最聰明的模型執行）**
   - 執行 `-CheckEnvironment` 自動檢查電腦是否安裝 `openspec` / `openspec-tw` / `specify` 以及 `collama`、`ollama-copilot`、`ollama-copilot_2` 端點是否可用。
   - **優先使用 OpenSpec 等 SDD 工具**（若未安裝則使用 **AGY 原生 Plan**）產出並確認四大規格產物：`proposal.md`、`specs/`、`design.md (plan)`、`tasks.md`。
2. **Stage 1：智慧動態派工（由 `agy` 當下最聰明的 Gemini 模型決定）**
   - 預設三者皆可使用；若其中某端點無法連線則自動使用可用的一方（看哪個可以用就用誰）。
   - 當多個引擎皆可用時，由 `agy` 最聰明的模型依據 `tasks.md` 任務特性決定**三引擎協同派工**或**分流派工**：
     - **`ollama-copilot`**：派發多模組/高扇出任務群 A（預設 4 個平行 Subagent）。
     - **`ollama-copilot_2`**：派發多模組/高扇出任務群 B（預設 4 個平行 Subagent）。
     - **`collama`**：派發聚焦型單一任務（嚴格限制 1 個 Subagent）。
   - 透過 `-SpecContextPath` 將確認後的 `proposal`、`spec`、`plan`、`tasks` 完整注入 Subagent 上下文。
3. **Stage 2：最高等模型審查（Logic & Spec Audit）**
   - `agy` 最聰明的模型針對回傳結果對照 `spec` 與 `tasks` 進行「工作派遣合規性」與「邏輯與規格正確性」審查。
4. **Stage 3：退回指導重新訂正（Guided Correction）**
   - 若不符合規格或邏輯有誤，`agy` 透過 `-ResumeSessionId` + `-CorrectionFeedback` 指導原引擎在原 Session 修正並重新驗證。
5. **Stage 4：複查確認與強制版控結案（Sign-Off & Version Control）**
   - 複查通過後更新 `tasks.md` 狀態並彙整最終成果。
   - **文件與技能包強制納入 Git 版控**：所有規劃/規格文件（`openspec/`、`proposal.md`、`spec.md`、`design.md`、`tasks.md`、`README.md`）與技能包（`.agents/skills/`）皆須納入 Git 版本控制，並以清晰的 Commit 紀錄提交。

---

## 快速指令範例

### 1. 檢查電腦 SDD 工具與三引擎可用狀態 (`-CheckEnvironment`)
```powershell
pwsh -File .\.agents\skills\copilot-subagent-orchestrator\scripts\Invoke-CopilotSubagents.ps1 -CheckEnvironment
```

### 2. 派工給三組引擎範例

```powershell
# 派工給 ollama-copilot（預設 4 個平行 Subagent）
pwsh -File .\.agents\skills\copilot-subagent-orchestrator\scripts\Invoke-CopilotSubagents.ps1 `
  -Engine ollama-copilot `
  -SpecContextPath ".\openspec\changes\<change-id>" `
  -Prompt "依據 OpenSpec 規格平行執行任務群 A" `
  -Tasks "Task 1.1: ...", "Task 1.2: ...", "Task 1.3: ...", "Task 1.4: ..."

# 派工給 ollama-copilot_2（第二實例，預設 4 個平行 Subagent）
pwsh -File .\.agents\skills\copilot-subagent-orchestrator\scripts\Invoke-CopilotSubagents.ps1 `
  -Engine ollama-copilot_2 `
  -SpecContextPath ".\openspec\changes\<change-id>" `
  -Prompt "依據 OpenSpec 規格平行執行任務群 B" `
  -Tasks "Task 2.1: ...", "Task 2.2: ...", "Task 2.3: ...", "Task 2.4: ..."

# 派工給 collama（嚴格限制 1 個 Subagent，避免 TPM/RPM 超限）
pwsh -File .\.agents\skills\copilot-subagent-orchestrator\scripts\Invoke-CopilotSubagents.ps1 `
  -Engine collama `
  -SpecContextPath ".\openspec\changes\<change-id>" `
  -Prompt "依據 OpenSpec 規格執行單一核心任務" `
  -Tasks "Task 3.1: ..."
```
