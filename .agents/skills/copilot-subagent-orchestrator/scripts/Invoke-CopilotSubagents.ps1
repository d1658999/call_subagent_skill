<#
.SYNOPSIS
    Orchestrates GitHub Copilot CLI via `collama` or `ollama-copilot` with parallel subagents (`--fleet` / `task` tool)
    and supports AGY Supervisor Audit & Correction loops (`-ResumeSessionId` + `-CorrectionFeedback`).

.DESCRIPTION
    Invokes `collama` or `ollama-copilot` in non-interactive fleet mode (`--fleet -p ... --no-ask-user`)
    while enforcing subagent concurrency rules:
    - `collama`: Hard cap of at most 2 concurrent subagents (clamped automatically if > 2 is requested).
    - `ollama-copilot`: Default of 4 concurrent subagents (customizable, unrestricted ceiling).
    Also supports resuming a previous session (`-ResumeSessionId`) with `-CorrectionFeedback` when
    Antigravity (AGY)'s top-tier supervisor model detects logical errors or task dispatch issues during review.

.PARAMETER Engine
    Which Copilot CLI wrapper to use: 'collama' or 'ollama-copilot'. Default: 'ollama-copilot'.

.PARAMETER Prompt
    The main objective or instruction to execute. Optional if -Tasks or -CorrectionFeedback is provided.

.PARAMETER Tasks
    An array of specific subtasks to distribute across parallel subagents.

.PARAMETER CorrectionFeedback
    Supervisor review feedback from AGY when a previous output had logical errors, missing subtasks,
    or violated constraints. Typically paired with -ResumeSessionId to guide the engine to fix its work.

.PARAMETER MaxSubagents
    Maximum number of subagents to run in parallel at any one time (0 = engine default).
    - Resolves to 2 for 'collama' when 0, and is strictly clamped to <= 2.
    - Resolves to 4 for 'ollama-copilot' when 0 (can be set to any positive integer).

.PARAMETER SubagentType
    Preferred subagent type for Copilot CLI's `task` tool (e.g., 'general-purpose', 'explore', 'task', 'research', 'code-review', 'security-review').
    Default: 'general-purpose'.

.PARAMETER WorkingDirectory
    Optional working directory passed via `-C` to Copilot CLI.

.PARAMETER ResumeSessionId
    Optional session UUID or prefix to resume (`--resume=<id>`), used when AGY guides the engine to correct previous output.

.PARAMETER NoFleet
    If set, omits the `--fleet` flag and relies solely on prompt-driven `task` tool calls.

.PARAMETER AdditionalArgs
    Any extra CLI flags to pass through to `collama` / `ollama-copilot`.

.PARAMETER RemainingTasks
    Captures remaining unbound arguments when invoked via `pwsh -File` and merges them into `-Tasks`.

.EXAMPLE
    pwsh -File .\.agents\skills\copilot-subagent-orchestrator\scripts\Invoke-CopilotSubagents.ps1 -Engine collama -Tasks "Check API routes", "Check DB models"

.EXAMPLE
    pwsh -File .\.agents\skills\copilot-subagent-orchestrator\scripts\Invoke-CopilotSubagents.ps1 -Engine collama -ResumeSessionId "e8e99fb9-f280-440f-a89c-79b68ad4724a" -CorrectionFeedback "Subtask 2 missed edge case X. Re-verify and fix."
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("collama", "ollama-copilot")]
    [string]$Engine = "ollama-copilot",

    [Parameter(Mandatory = $false)]
    [string]$Prompt = "",

    [Parameter(Mandatory = $false)]
    [string[]]$Tasks = @(),

    [Parameter(Mandatory = $false)]
    [string]$CorrectionFeedback = "",

    [Parameter(Mandatory = $false)]
    [int]$MaxSubagents = 0,

    [Parameter(Mandatory = $false)]
    [ValidateSet("general-purpose", "explore", "task", "research", "code-review", "security-review")]
    [string]$SubagentType = "general-purpose",

    [Parameter(Mandatory = $false)]
    [string]$WorkingDirectory = "",

    [Parameter(Mandatory = $false)]
    [string]$ResumeSessionId = "",

    [Parameter(Mandatory = $false)]
    [switch]$NoFleet,

    [Parameter(Mandatory = $false)]
    [string[]]$AdditionalArgs = @(),

    [Parameter(Mandatory = $false, ValueFromRemainingArguments = $true)]
    [string[]]$RemainingTasks = @()
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# Merge any remaining arguments (e.g. when invoked via `pwsh -File ... -Tasks "A", "B"`) into $Tasks
$allTasks = [System.Collections.Generic.List[string]]::new()
foreach ($t in $Tasks) {
    if (-not [string]::IsNullOrWhiteSpace($t)) {
        $allTasks.Add($t.Trim().TrimEnd(','))
    }
}
foreach ($rt in $RemainingTasks) {
    if (-not [string]::IsNullOrWhiteSpace($rt)) {
        $allTasks.Add($rt.Trim().TrimEnd(','))
    }
}

if ([string]::IsNullOrWhiteSpace($Prompt) -and $allTasks.Count -eq 0 -and [string]::IsNullOrWhiteSpace($CorrectionFeedback)) {
    throw "You must provide -Prompt, -Tasks, or -CorrectionFeedback."
}

# 1. Enforce Engine-Specific Subagent Concurrency Limits
if ($Engine -eq "collama") {
    if ($MaxSubagents -le 0) {
        $MaxSubagents = 2
    } elseif ($MaxSubagents -gt 2) {
        Write-Warning "[collama] MaxSubagents requested ($MaxSubagents) exceeds collama's hard limit of 2. Clamping MaxSubagents to 2."
        $MaxSubagents = 2
    }
} else {
    # ollama-copilot defaults to 4 concurrent subagents, no upper clamp
    if ($MaxSubagents -le 0) {
        $MaxSubagents = 4
    }
}

# 2. Ensure PowerShell $PROFILE is loaded so `collama` and `ollama-copilot` functions are available
if (-not (Get-Command $Engine -ErrorAction SilentlyContinue)) {
    if ($PROFILE -and (Test-Path $PROFILE)) {
        . $PROFILE
    }
}

if (-not (Get-Command $Engine -ErrorAction SilentlyContinue)) {
    throw "Command '$Engine' was not found even after loading `$PROFILE ($PROFILE). Please verify your PowerShell profile defines '$Engine'."
}

# 3. Build the Orchestration / Correction Prompt with Explicit Subagent Guardrails
$promptBuilder = [System.Text.StringBuilder]::new()

[void]$promptBuilder.AppendLine("[SUBAGENT ORCHESTRATION INSTRUCTIONS]")
if ($Engine -eq "collama") {
    [void]$promptBuilder.AppendLine("- CONCURRENCY LIMIT (STRICT): You are running under 'collama'. You MUST launch AT MOST $MaxSubagents parallel subagents (`task` tool in `mode: `"background`"`) at the same time.")
    [void]$promptBuilder.AppendLine("- BATCHING RULE: If there are more than $MaxSubagents subtasks, execute them in batches of at most $MaxSubagents concurrent subagents. Wait for the active batch to finish using `read_agent` before launching the next batch.")
} else {
    [void]$promptBuilder.AppendLine("- CONCURRENCY RULE: You are running under 'ollama-copilot'. You can launch up to $MaxSubagents parallel subagents (`task` tool in `mode: `"background`"`) simultaneously in a single turn.")
    [void]$promptBuilder.AppendLine("- BATCHING RULE: If there are more than $MaxSubagents subtasks, run up to $MaxSubagents concurrent subagents per batch, collect results with `read_agent`, and continue until all subtasks are complete.")
}
[void]$promptBuilder.AppendLine("- PREFERRED SUBAGENT TYPE: Use `agent_type: `"$SubagentType`"` when calling the `task` tool unless a more specialized agent is required.")
[void]$promptBuilder.AppendLine("- AUTONOMOUS EXECUTION: Work autonomously without asking user questions. Synthesize all subagent findings into a clear, structured final response.")
[void]$promptBuilder.AppendLine("")

if (-not [string]::IsNullOrWhiteSpace($CorrectionFeedback)) {
    [void]$promptBuilder.AppendLine("[AGY SUPERVISOR AUDIT FAILED - MANDATORY CORRECTION DIRECTIVE]")
    [void]$promptBuilder.AppendLine("Your previous output was audited by the AGY Lead Supervisor Model and requires correction.")
    [void]$promptBuilder.AppendLine("Carefully address every point below, re-verify your work (using subagents if needed within your concurrency limit of $MaxSubagents), and provide the corrected, verified output:")
    [void]$promptBuilder.AppendLine($CorrectionFeedback.Trim())
    [void]$promptBuilder.AppendLine("")
}

if (-not [string]::IsNullOrWhiteSpace($Prompt)) {
    [void]$promptBuilder.AppendLine("[MAIN OBJECTIVE]")
    [void]$promptBuilder.AppendLine($Prompt.Trim())
    [void]$promptBuilder.AppendLine("")
}

if ($allTasks.Count -gt 0) {
    [void]$promptBuilder.AppendLine("[SUBTASKS TO EXECUTE VIA SUBAGENTS]")
    for ($i = 0; $i -lt $allTasks.Count; $i++) {
        $idx = $i + 1
        [void]$promptBuilder.AppendLine("$idx. $($allTasks[$i])")
    }
    [void]$promptBuilder.AppendLine("")
}

$finalPrompt = $promptBuilder.ToString().Trim()

# 4. Assemble CLI Arguments for GitHub Copilot CLI wrapper
$cliArgs = [System.Collections.Generic.List[string]]::new()

if (-not $NoFleet) {
    $cliArgs.Add("--fleet")
}

$cliArgs.Add("--no-ask-user")

if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
    $resolvedDir = (Resolve-Path -Path $WorkingDirectory).Path
    $cliArgs.Add("-C")
    $cliArgs.Add($resolvedDir)
}

if (-not [string]::IsNullOrWhiteSpace($ResumeSessionId)) {
    $cleanId = $ResumeSessionId.Trim() -replace '^--resume=', ''
    $cliArgs.Add("--resume=$cleanId")
}

if ($null -ne $AdditionalArgs -and $AdditionalArgs.Count -gt 0) {
    foreach ($arg in $AdditionalArgs) {
        if (-not [string]::IsNullOrWhiteSpace($arg)) {
            $cliArgs.Add($arg)
        }
    }
}

$cliArgs.Add("-p")
$cliArgs.Add($finalPrompt)

$modeLabel = if (-not [string]::IsNullOrWhiteSpace($CorrectionFeedback)) { "CORRECTION-ROUND" } else { "DISPATCH" }
$resumeLabel = if (-not [string]::IsNullOrWhiteSpace($ResumeSessionId)) { ", Resume: $ResumeSessionId" } else { "" }
Write-Host "=== [$modeLabel] Invoking $Engine (MaxSubagents: $MaxSubagents, Subtasks: $($allTasks.Count), Fleet: $(-not $NoFleet)$resumeLabel) ===" -ForegroundColor Cyan

# 5. Save and restore environment variables around invocation
$envKeysToPreserve = @(
    "COPILOT_PROVIDER_TYPE",
    "COPILOT_PROVIDER_WIRE_API",
    "COPILOT_PROVIDER_BASE_URL",
    "COPILOT_PROVIDER_API_KEY",
    "COPILOT_MODEL",
    "COPILOT_PROVIDER_MAX_PROMPT_TOKENS",
    "COPILOT_PROVIDER_MAX_OUTPUT_TOKENS"
)
$savedEnv = @{}
foreach ($key in $envKeysToPreserve) {
    $savedEnv[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
}

try {
    & $Engine @cliArgs
    $exitCode = $LASTEXITCODE
    if ($null -ne $exitCode -and $exitCode -ne 0) {
        exit $exitCode
    }
} finally {
    foreach ($key in $envKeysToPreserve) {
        [Environment]::SetEnvironmentVariable($key, $savedEnv[$key], "Process")
    }
}
