# Copilot Subagent Orchestrator Skill (`collama` & `ollama-copilot`)

讓 Google Antigravity (`agy` CLI / Antigravity IDE) 透過 PowerShell 同時呼叫並操控 `collama` 與 `ollama-copilot`（基於 GitHub Copilot CLI 的封裝函式），自動啟用 `--fleet` 平行 Subagent 協作模式、嚴格控管並行數量，並由 **`agy` 當下最高等模型進行邏輯與工作派遣審查（若發現錯誤則透過 Session Resume 指導訂正並複查）**。

## 專案與全域安裝結構

此 Skill 已同時部署於**當前專案工作區**與**全域 Antigravity 設定目錄**（讓你在任何專案下使用 `agy` 都能自動觸發此 Skill）：

- **工作區路徑**：[`.agents/skills/copilot-subagent-orchestrator/`](file:///c:/Users/d1658/Documents/project/call_subagent_skill/.agents/skills/copilot-subagent-orchestrator)
  - [`SKILL.md`](file:///c:/Users/d1658/Documents/project/call_subagent_skill/.agents/skills/copilot-subagent-orchestrator/SKILL.md)：Skill 核心指令、並行規範與 **AGY 最高等模型審查＆退回訂正迴圈**定義
  - [`scripts/Invoke-CopilotSubagents.ps1`](file:///c:/Users/d1658/Documents/project/call_subagent_skill/.agents/skills/copilot-subagent-orchestrator/scripts/Invoke-CopilotSubagents.ps1)：PowerShell 操控、並行上限保護與 `-ResumeSessionId` / `-CorrectionFeedback` 訂正腳本
  - [`references/cli-flags-and-patterns.md`](file:///c:/Users/d1658/Documents/project/call_subagent_skill/.agents/skills/copilot-subagent-orchestrator/references/cli-flags-and-patterns.md)：CLI 參數、內部 `task` / `read_agent` 工具與審查訂正模式說明
- **全域路徑**：`C:\Users\d1658\.gemini\config\skills\copilot-subagent-orchestrator\`

---

## 1. Subagent 並行數量規則

| 引擎 (`-Engine`) | 底層端點 / 模型 | 最大同時平行 Subagent 數 | 行為與保護機制 |
| :--- | :--- | :--- | :--- |
| **`collama`** | `https://llm-share.duotify.com/v1` (`deepseek-v4.1-flash:1017`) | **最多 2 個 (`<= 2`)** | 腳本強制將 `-MaxSubagents` 鎖定在 `<= 2`（超過會發出 Warning 並自動降為 `2`）；若子任務超過 2 個，會指示 `collama` 分批（Wave Batching，每批最多 2 個，透過 `read_agent` 等待完成後再啟動下一批）。 |
| **`ollama-copilot`** | `http://localhost:11434/v1` (`deepseek-v4.1-flash:1017-cloud`) | **預設 4 個（不設硬上限）** | 預設同時啟動最多 **4** 個平行 Subagent，亦可透過 `-MaxSubagents <N>` 依需求自由調整。 |

---

## 2. AGY 最高等模型審查與退回訂正閉環 (Supervisor Audit & Correction Loop)

1. **平行派遣 (Stage 1)**：`agy` 同時（或分別）呼叫 `collama` 與 `ollama-copilot` 執行平行 Subagent 任務。
2. **最高等模型審查 (Stage 2)**：`agy` 使用當下最高等模型針對回傳結果進行雙重審查：
   - **工作派遣審查**：確認 `collama` 並行數 `<= 2`、`ollama-copilot` 並行數符合設定，且所有子任務皆完整執行無遺漏。
   - **邏輯與內容正確性審查**：檢查計算、程式碼、邏輯推論與限制條件是否完全正確。
3. **指導重新訂正 (Stage 3)**：若發現任何邏輯錯誤或條件不符，`agy` 會擷取輸出的 `Resume copilot --resume=<session-uuid>`，透過 `-ResumeSessionId` 與 `-CorrectionFeedback` 具體指出錯誤原因並指導 `collama` / `ollama-copilot` 修正。
4. **複查確認 (Stage 4)**：`agy` 再次審查訂正後的結果，確認完全無誤後才結案。

---

## 3. 快速使用方式

### 初始平行派遣 (`-Prompt` + `-Tasks`)

```powershell
# 呼叫 collama（最多 2 個平行 Subagent）
pwsh -File .\.agents\skills\copilot-subagent-orchestrator\scripts\Invoke-CopilotSubagents.ps1 `
  -Engine collama `
  -Prompt "請平行執行以下子任務並彙整結果" `
  -Tasks "子任務 1：...", "子任務 2：..."

# 呼叫 ollama-copilot（預設 4 個平行 Subagent）
pwsh -File .\.agents\skills\copilot-subagent-orchestrator\scripts\Invoke-CopilotSubagents.ps1 `
  -Engine ollama-copilot `
  -MaxSubagents 4 `
  -Prompt "請同時派發 4 個 Subagent 平行處理以下任務並整理成表格" `
  -Tasks "子任務 1：...", "子任務 2：...", "子任務 3：...", "子任務 4：..."
```

### 審查未通過時的退回訂正呼叫 (`-ResumeSessionId` + `-CorrectionFeedback`)

```powershell
pwsh -File .\.agents\skills\copilot-subagent-orchestrator\scripts\Invoke-CopilotSubagents.ps1 `
  -Engine collama `
  -ResumeSessionId "<上一輪輸出的 session-uuid>" `
  -CorrectionFeedback "AGY 審查退回：子任務 2 的邏輯違反了條件 X，請重新派發 Subagent 修正並驗證後輸出正確結果。"
```
