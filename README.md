# Copilot Subagent Orchestrator Skill (`collama` & `ollama-copilot` + SDD Planning)

讓 Google Antigravity (`agy` CLI / Antigravity IDE) 在接到任務時，先由 **`agy` 當下可用最聰明的 Gemini 模型（如 Pro / 最高階模型）進行嚴謹規劃（優先使用電腦上已安裝的 OpenSpec / Specify 等 SDD 工具；若未安裝則使用 AGY 原生 Plan 功能）**；當 `proposal`、`spec`、`plan (design)`、`tasks` 確定後，再由 `agy` 最聰明的模型動態決定如何指派給 `ollama-copilot`（預設 4 個平行 Subagent）與 `collama`（最多 2 個平行 Subagent）一起平行派工或自動切換可用引擎，並在完成後執行嚴格審查與退回訂正閉環。

---

## 專案與全域安裝結構

此 Skill 已同時部署於**當前專案工作區**與**全域 Antigravity 設定目錄**（讓你在任何專案下使用 `agy` 都能自動觸發此 Skill）：

- **工作區路徑**：[`.agents/skills/copilot-subagent-orchestrator/`](file:///c:/Users/d1658/Documents/project/call_subagent_skill/.agents/skills/copilot-subagent-orchestrator)
  - [`SKILL.md`](file:///c:/Users/d1658/Documents/project/call_subagent_skill/.agents/skills/copilot-subagent-orchestrator/SKILL.md)：定義 5 階段閉環（Stage 0 SDD/Plan 嚴謹規劃 → Stage 1 智慧動態派工 → Stage 2 最高等模型審查 → Stage 3 退回訂正 → Stage 4 複查結案）
  - [`scripts/Invoke-CopilotSubagents.ps1`](file:///c:/Users/d1658/Documents/project/call_subagent_skill/.agents/skills/copilot-subagent-orchestrator/scripts/Invoke-CopilotSubagents.ps1)：支援 `-CheckEnvironment`（探測 SDD 工具與雙引擎連線狀態）、`-SpecContextPath`（自動注入 OpenSpec/Plan 規格文件）、`-Engine auto`（自動容錯切換）、並行上限保護與 `-ResumeSessionId` / `-CorrectionFeedback` 退回訂正
  - [`references/cli-flags-and-patterns.md`](file:///c:/Users/d1658/Documents/project/call_subagent_skill/.agents/skills/copilot-subagent-orchestrator/references/cli-flags-and-patterns.md)：OpenSpec 整合指令、智慧派工策略與 CLI 參數參考
- **全域路徑**：`C:\Users\d1658\.gemini\config\skills\copilot-subagent-orchestrator\`

---

## 五階段運作流程 (5-Stage Workflow)

1. **Stage 0：環境探測與嚴謹規劃（由 `agy` 當下最聰明的模型執行）**
   - 執行 `-CheckEnvironment` 自動檢查電腦是否安裝 `openspec` / `openspec-tw` / `specify` 以及 `collama`、`ollama-copilot` 端點是否可用。
   - **優先使用 OpenSpec 等 SDD 工具**（若未安裝則使用 **AGY 原生 Plan**）產出並確認四大規格產物：`proposal.md`、`specs/`、`design.md (plan)`、`tasks.md`。
2. **Stage 1：智慧動態派工（由 `agy` 當下最聰明的 Gemini 模型決定）**
   - 預設 `ollama-copilot` 與 `collama` 兩者皆可使用；若其中一個端點無法連線則自動使用可用的一方（看哪個可以用就用誰）。
   - 當兩者皆可用時，由 `agy` 最聰明的模型依據 `tasks.md` 任務特性決定**一起平行派工**或**單獨派工**：
     - **`ollama-copilot`**：預設同時執行 **4 個**平行 Subagent（不設硬上限），適合派發多模組/高扇出任務群。
     - **`collama`**：強制鎖定最多 **2 個**平行 Subagent（超過 2 個子任務時自動以每批 2 個進行 Wave Batching），適合派發聚焦型雙任務群。
   - 透過 `-SpecContextPath` 將確認後的 `proposal`、`spec`、`plan`、`tasks` 完整注入 Subagent 上下文。
3. **Stage 2：最高等模型審查（Logic & Spec Audit）**
   - `agy` 最聰明的模型針對回傳結果對照 `spec` 與 `tasks` 進行「工作派遣合規性」與「邏輯與規格正確性」審查。
4. **Stage 3：退回指導重新訂正（Guided Correction）**
   - 若不符合規格或邏輯有誤，`agy` 透過 `-ResumeSessionId` + `-CorrectionFeedback` 指導 `collama` / `ollama-copilot` 在原 Session 修正並重新驗證。
5. **Stage 4：複查確認與強制版控結案（Sign-Off & Version Control）**
   - 複查通過後更新 `tasks.md` 狀態並彙整最終成果。
   - **文件與技能包強制納入 Git 版控**：所有規劃/規格文件（`openspec/`、`proposal.md`、`spec.md`、`design.md`、`tasks.md`、`README.md`）與技能包（`.agents/skills/`）皆須納入 Git 版本控制（若尚未初始化則執行 `git init`），並以清晰的 Commit 紀錄提交，以便未來持續更新、修改與除錯追蹤。

---

## 快速指令範例

### 1. 檢查電腦 SDD 工具與雙引擎可用狀態 (`-CheckEnvironment`)
```powershell
pwsh -File .\.agents\skills\copilot-subagent-orchestrator\scripts\Invoke-CopilotSubagents.ps1 -CheckEnvironment
```

### 2. 帶入 OpenSpec / Plan 規格目錄進行雙引擎平行派工 (`-SpecContextPath`)
```powershell
# 派工給 ollama-copilot（預設 4 個平行 Subagent）
pwsh -File .\.agents\skills\copilot-subagent-orchestrator\scripts\Invoke-CopilotSubagents.ps1 `
  -Engine ollama-copilot `
  -SpecContextPath ".\openspec\changes\<change-id>" `
  -Prompt "依據 OpenSpec 規格平行執行以下任務" `
  -Tasks "Task 1.1: ...", "Task 1.2: ...", "Task 1.3: ...", "Task 1.4: ..."

# 同時派工給 collama（最多 2 個平行 Subagent）
pwsh -File .\.agents\skills\copilot-subagent-orchestrator\scripts\Invoke-CopilotSubagents.ps1 `
  -Engine collama `
  -SpecContextPath ".\openspec\changes\<change-id>" `
  -Prompt "依據 OpenSpec 規格平行執行以下任務" `
  -Tasks "Task 2.1: ...", "Task 2.2: ..."
```
