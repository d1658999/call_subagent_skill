<#
.SYNOPSIS
    [v1.1.0] Orchestrates GitHub Copilot CLI via `collama`, `ollama-copilot`, and/or `ollama-copilot_2`
    with SDD/OpenSpec integration, engine health probing & auto-failover, parallel subagents (`--fleet` / `task` tool),
    and AGY Supervisor Audit & Correction loops (`-ResumeSessionId` + `-CorrectionFeedback`).

.DESCRIPTION
    1. Environment & SDD Check (`-CheckEnvironment`):
       Detects installed SDD tools (`openspec`, `openspec-tw`, `specify`) and probes availability of
       `collama`, `ollama-copilot`, and `ollama-copilot_2` endpoints.
    2. Spec-Driven Context Injection (`-SpecContextPath`):
       Reads confirmed `proposal.md`, `design.md`, `specs/`, and `tasks.md` (from OpenSpec or AGY Plan)
       and injects them into the orchestration prompt.
    3. Engine Concurrency & Auto-Failover:
       - `collama`: Hard cap of at most 1 concurrent subagent (to prevent hitting TPM/RPM rate limits).
       - `ollama-copilot`: Default of 4 concurrent subagents (customizable, unrestricted ceiling).
       - `ollama-copilot_2`: Default of 4 concurrent subagents (customizable, unrestricted ceiling, identical to ollama-copilot).
       - `auto`: Automatically picks an available engine and fails over if one endpoint is unreachable (unless `-DisableAutoFallback` is set).
    4. Supervisor Review & Correction (`-ResumeSessionId` + `-CorrectionFeedback`):
       Resumes a previous session with AGY's top-tier model audit feedback to guide corrections.

.NOTES
    Version: 1.1.0 (Added ollama-copilot_2 and reduced collama concurrency to 1 for TPM/RPM safety)

.PARAMETER Engine
    Which Copilot CLI wrapper to use: 'auto', 'collama', 'ollama-copilot', or 'ollama-copilot_2'. Default: 'auto'.

.PARAMETER CheckEnvironment
    If set, checks SDD tools (`openspec`, `openspec-tw`, `specify`) and probes `collama`, `ollama-copilot`, and `ollama-copilot_2` availability, then exits.

.PARAMETER SpecContextPath
    Optional path to an OpenSpec change directory (e.g. `openspec/changes/<id>`) or a Plan/Spec markdown file
    whose contents (`proposal.md`, `design.md`, `specs/`, `tasks.md`) should be injected as authoritative context.

.PARAMETER Prompt
    The main objective or instruction to execute. Optional if -Tasks, -CorrectionFeedback, or -CheckEnvironment is provided.

.PARAMETER Tasks
    An array of specific subtasks to distribute across parallel subagents.

.PARAMETER CorrectionFeedback
    Supervisor review feedback from AGY when a previous output had logical errors, missing subtasks,
    or violated constraints. Typically paired with -ResumeSessionId to guide the engine to fix its work.

.PARAMETER MaxSubagents
    Maximum number of subagents to run in parallel at any one time (0 = engine default).
    - Resolves to 1 for 'collama' when 0, and is strictly clamped to <= 1 (TPM/RPM protection).
    - Resolves to 4 for 'ollama-copilot' and 'ollama-copilot_2' when 0 (can be set to any positive integer).

.PARAMETER SubagentType
    Preferred subagent type for Copilot CLI's `task` tool (e.g., 'general-purpose', 'explore', 'task', 'research', 'code-review', 'security-review').
    Default: 'general-purpose'.

.PARAMETER WorkingDirectory
    Optional working directory passed via `-C` to Copilot CLI.

.PARAMETER ResumeSessionId
    Optional session UUID or prefix to resume (`--resume=<id>`), used when AGY guides the engine to correct previous output.

.PARAMETER NoFleet
    If set, omits the `--fleet` flag and relies solely on prompt-driven `task` tool calls.

.PARAMETER DisableAutoFallback
    If set, disables automatic failover to the alternate engine when the selected engine's endpoint is unreachable or fails.

.PARAMETER AdditionalArgs
    Any extra CLI flags to pass through to `collama` / `ollama-copilot` / `ollama-copilot_2`.

.PARAMETER RemainingTasks
    Captures remaining unbound arguments when invoked via `pwsh -File` and merges them into `-Tasks`.

.EXAMPLE
    pwsh -File .\.agents\skills\copilot-subagent-orchestrator\scripts\Invoke-CopilotSubagents.ps1 -CheckEnvironment

.EXAMPLE
    pwsh -File .\.agents\skills\copilot-subagent-orchestrator\scripts\Invoke-CopilotSubagents.ps1 -Engine ollama-copilot_2 -Tasks "Task 1", "Task 2"
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("auto", "collama", "ollama-copilot", "ollama-copilot_2")]
    [string]$Engine = "auto",

    [Parameter(Mandatory = $false)]
    [switch]$CheckEnvironment,

    [Parameter(Mandatory = $false)]
    [string]$SpecContextPath = "",

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
    [switch]$DisableAutoFallback,

    [Parameter(Mandatory = $false)]
    [string[]]$AdditionalArgs = @(),

    [Parameter(Mandatory = $false, ValueFromRemainingArguments = $true)]
    [string[]]$RemainingTasks = @()
)

$ErrorActionPreference = "Stop"
$SkillVersion = "1.1.0"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# Ensure PowerShell $PROFILE is loaded so `collama`, `ollama-copilot`, and `ollama-copilot_2` functions are available
$knownEngines = @("collama", "ollama-copilot", "ollama-copilot_2")
$missingAny = $false
foreach ($eng in $knownEngines) {
    if (-not (Get-Command $eng -ErrorAction SilentlyContinue)) {
        $missingAny = $true
        break
    }
}
if ($missingAny) {
    if ($PROFILE -and (Test-Path $PROFILE)) {
        . $PROFILE
    }
}

function Test-EndpointReachable {
    param(
        [string]$Uri,
        [int]$TimeoutSec = 4
    )
    try {
        $req = [System.Net.HttpWebRequest]::Create($Uri)
        $req.Method = "GET"
        $req.Timeout = $TimeoutSec * 1000
        $resp = $req.GetResponse()
        $resp.Close()
        return $true
    } catch [System.Net.WebException] {
        # Any HTTP response (even 401/403/404) proves the server is reachable and listening
        if ($null -ne $_.Exception.Response) {
            $_.Exception.Response.Close()
            return $true
        }
        return $false
    } catch {
        return $false
    }
}

function Get-OrchestratorEnvironmentStatus {
    $openspecCmd = Get-Command "openspec" -ErrorAction SilentlyContinue
    $openspecTwCmd = Get-Command "openspec-tw" -ErrorAction SilentlyContinue
    $specifyCmd = Get-Command "specify" -ErrorAction SilentlyContinue

    $collamaFn = Get-Command "collama" -ErrorAction SilentlyContinue
    $ollamaCopilotFn = Get-Command "ollama-copilot" -ErrorAction SilentlyContinue
    $ollamaCopilot2Fn = Get-Command "ollama-copilot_2" -ErrorAction SilentlyContinue

    $collamaReachable = ($null -ne $collamaFn) -and (Test-EndpointReachable -Uri "https://llm-share.duotify.com/v1/models" -TimeoutSec 5)
    $ollamaReachable = ($null -ne $ollamaCopilotFn) -and (Test-EndpointReachable -Uri "http://localhost:11434/v1/models" -TimeoutSec 3)
    $ollama2Reachable = ($null -ne $ollamaCopilot2Fn) -and (Test-EndpointReachable -Uri "http://localhost:11434/v1/models" -TimeoutSec 3)

    $preferredSdd = if ($null -ne $openspecCmd) {
        "openspec"
    } elseif ($null -ne $openspecTwCmd) {
        "openspec-tw"
    } elseif ($null -ne $specifyCmd) {
        "specify"
    } else {
        "agy-native-plan"
    }

    $gitInitialized = (Test-Path (Join-Path (Get-Location).Path ".git"))

    return [PSCustomObject]@{
        SkillVersion                 = $SkillVersion
        PreferredPlanningTool        = $preferredSdd
        GitInitialized               = $gitInitialized
        SDDTools                     = [PSCustomObject]@{
            openspec    = ($null -ne $openspecCmd)
            openspec_tw = ($null -ne $openspecTwCmd)
            specify     = ($null -ne $specifyCmd)
        }
        WorkspaceOpenSpecInitialized = (Test-Path (Join-Path (Get-Location).Path "openspec"))
        Engines               = [PSCustomObject]@{
            collama          = [PSCustomObject]@{
                Defined            = ($null -ne $collamaFn)
                Reachable          = $collamaReachable
                MaxParallelAgents  = 1
            }
            ollama_copilot   = [PSCustomObject]@{
                Defined            = ($null -ne $ollamaCopilotFn)
                Reachable          = $ollamaReachable
                DefaultParallelAgents = 4
            }
            ollama_copilot_2 = [PSCustomObject]@{
                Defined            = ($null -ne $ollamaCopilot2Fn)
                Reachable          = $ollama2Reachable
                DefaultParallelAgents = 4
            }
        }
    }
}

if ($CheckEnvironment) {
    $status = Get-OrchestratorEnvironmentStatus
    $status | ConvertTo-Json -Depth 4
    exit 0
}

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

if ([string]::IsNullOrWhiteSpace($Prompt) -and $allTasks.Count -eq 0 -and [string]::IsNullOrWhiteSpace($CorrectionFeedback) -and [string]::IsNullOrWhiteSpace($SpecContextPath)) {
    throw "You must provide -Prompt, -Tasks, -CorrectionFeedback, -SpecContextPath, or -CheckEnvironment."
}

# Resolve Engine when 'auto' or check availability for fallback
$envStatus = Get-OrchestratorEnvironmentStatus
$selectedEngine = $Engine

if ($selectedEngine -eq "auto") {
    $availablePool = [System.Collections.Generic.List[string]]::new()
    if ($envStatus.Engines.ollama_copilot.Reachable) { [void]$availablePool.Add("ollama-copilot") }
    if ($envStatus.Engines.ollama_copilot_2.Reachable) { [void]$availablePool.Add("ollama-copilot_2") }
    if ($envStatus.Engines.collama.Reachable) { [void]$availablePool.Add("collama") }

    if ($availablePool.Count -eq 0) {
        throw "None of the engines ('ollama-copilot', 'ollama-copilot_2', 'collama') are currently reachable."
    }

    if ($allTasks.Count -gt 1 -or $MaxSubagents -gt 1) {
        if ($availablePool.Contains("ollama-copilot")) {
            $selectedEngine = "ollama-copilot"
        } elseif ($availablePool.Contains("ollama-copilot_2")) {
            $selectedEngine = "ollama-copilot_2"
        } else {
            $selectedEngine = "collama"
        }
    } else {
        $selectedEngine = $availablePool[0]
    }
    Write-Host "[Auto-Engine] Selected '$selectedEngine' based on endpoint availability and workload." -ForegroundColor DarkCyan
} else {
    $engineKey = $selectedEngine -replace '-', '_'
    $isSelectedReachable = $envStatus.Engines.$engineKey.Reachable
    if (-not $isSelectedReachable -and (-not $DisableAutoFallback)) {
        $candidateFallbacks = @("ollama-copilot", "ollama-copilot_2", "collama") | Where-Object { $_ -ne $selectedEngine }
        $foundFallback = $null
        foreach ($cand in $candidateFallbacks) {
            $candKey = $cand -replace '-', '_'
            if ($envStatus.Engines.$candKey.Reachable) {
                $foundFallback = $cand
                break
            }
        }
        if ($null -ne $foundFallback) {
            Write-Warning "[$selectedEngine] Endpoint appears unreachable. Auto-failing over to reachable engine '$foundFallback'."
            $selectedEngine = $foundFallback
        }
    }
}

function Get-EffectiveMaxSubagents {
    param([string]$TargetEngine, [int]$RequestedMax)
    if ($TargetEngine -eq "collama") {
        if ($RequestedMax -le 0) {
            return 1
        } elseif ($RequestedMax -gt 1) {
            Write-Warning "[collama] MaxSubagents requested ($RequestedMax) exceeds collama's hard limit of 1 (TPM/RPM protection). Clamping MaxSubagents to 1."
            return 1
        }
        return $RequestedMax
    } else {
        # ollama-copilot and ollama-copilot_2 default to 4 subagents, unrestricted
        if ($RequestedMax -le 0) {
            return 4
        }
        return $RequestedMax
    }
}

# Optional: Read SDD / OpenSpec or AGY Plan artifacts from -SpecContextPath
$specContextText = ""
if (-not [string]::IsNullOrWhiteSpace($SpecContextPath)) {
    if (-not (Test-Path $SpecContextPath)) {
        throw "SpecContextPath '$SpecContextPath' does not exist."
    }
    $resolvedSpecPath = (Resolve-Path $SpecContextPath).Path
    $specBuilder = [System.Text.StringBuilder]::new()
    if ((Get-Item $resolvedSpecPath).PSIsContainer) {
        $candidateFiles = Get-ChildItem -Path $resolvedSpecPath -Recurse -File -Include "*.md" | Sort-Object FullName
        foreach ($file in $candidateFiles) {
            $relName = $file.FullName.Substring($resolvedSpecPath.Length).TrimStart('\', '/')
            [void]$specBuilder.AppendLine("--- File: $relName ---")
            [void]$specBuilder.AppendLine((Get-Content -Path $file.FullName -Raw))
            [void]$specBuilder.AppendLine("")
        }
    } else {
        [void]$specBuilder.AppendLine("--- File: $(Split-Path $resolvedSpecPath -Leaf) ---")
        [void]$specBuilder.AppendLine((Get-Content -Path $resolvedSpecPath -Raw))
    }
    $specContextText = $specBuilder.ToString().Trim()
}

function Build-OrchestrationPrompt {
    param([string]$TargetEngine, [int]$EffectiveMax)
    $promptBuilder = [System.Text.StringBuilder]::new()

    [void]$promptBuilder.AppendLine("[SUBAGENT ORCHESTRATION INSTRUCTIONS]")
    if ($TargetEngine -eq "collama") {
        [void]$promptBuilder.AppendLine("- CONCURRENCY LIMIT (STRICT): You are running under 'collama'. You MUST launch AT MOST $EffectiveMax parallel subagent (`task` tool in `mode: `"background`"`) at the same time to strictly prevent TPM/RPM rate limits.")
        [void]$promptBuilder.AppendLine("- BATCHING RULE: If there are more than $EffectiveMax subtasks, execute them in serial batches of at most 1 concurrent subagent. Wait for each subagent to finish using `read_agent` before launching the next one.")
    } else {
        [void]$promptBuilder.AppendLine("- CONCURRENCY RULE: You are running under '$TargetEngine'. You can launch up to $EffectiveMax parallel subagents (`task` tool in `mode: `"background`"`) simultaneously in a single turn.")
        [void]$promptBuilder.AppendLine("- BATCHING RULE: If there are more than $EffectiveMax subtasks, run up to $EffectiveMax concurrent subagents per batch, collect results with `read_agent`, and continue until all subtasks are complete.")
    }
    [void]$promptBuilder.AppendLine("- PREFERRED SUBAGENT TYPE: Use `agent_type: `"$SubagentType`"` when calling the `task` tool unless a more specialized agent is required.")
    [void]$promptBuilder.AppendLine("- AUTONOMOUS EXECUTION: Work autonomously without asking user questions. Synthesize all subagent findings into a clear, structured final response.")
    [void]$promptBuilder.AppendLine("")

    if (-not [string]::IsNullOrWhiteSpace($specContextText)) {
        [void]$promptBuilder.AppendLine("[CONFIRMED SDD / OPENSPEC / PLAN ARTIFACTS (AUTHORITATIVE SPEC)]")
        [void]$promptBuilder.AppendLine("You MUST strictly adhere to the following approved Proposal, Spec, Design/Plan, and Tasks:")
        [void]$promptBuilder.AppendLine($specContextText)
        [void]$promptBuilder.AppendLine("")
    }

    if (-not [string]::IsNullOrWhiteSpace($CorrectionFeedback)) {
        [void]$promptBuilder.AppendLine("[AGY SUPERVISOR AUDIT FAILED - MANDATORY CORRECTION DIRECTIVE]")
        [void]$promptBuilder.AppendLine("Your previous output was audited by the AGY Lead Supervisor Model and requires correction.")
        [void]$promptBuilder.AppendLine("Carefully address every point below, re-verify your work (using subagents if needed within your concurrency limit of $EffectiveMax), and provide the corrected, verified output:")
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

    return $promptBuilder.ToString().Trim()
}

function Invoke-TargetEngine {
    param([string]$TargetEngine)

    $effectiveMax = Get-EffectiveMaxSubagents -TargetEngine $TargetEngine -RequestedMax $MaxSubagents
    $finalPrompt = Build-OrchestrationPrompt -TargetEngine $TargetEngine -EffectiveMax $effectiveMax

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
    $specLabel = if (-not [string]::IsNullOrWhiteSpace($SpecContextPath)) { ", Spec: $SpecContextPath" } else { "" }
    Write-Host "=== [$modeLabel] Invoking $TargetEngine (MaxSubagents: $effectiveMax, Subtasks: $($allTasks.Count), Fleet: $(-not $NoFleet)$specLabel$resumeLabel) ===" -ForegroundColor Cyan

    & $TargetEngine @cliArgs
}

# Save and restore environment variables around invocation
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
    Invoke-TargetEngine -TargetEngine $selectedEngine
    $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    if ($exitCode -ne 0) {
        if (-not $DisableAutoFallback -and [string]::IsNullOrWhiteSpace($ResumeSessionId)) {
            $fallbackEngine = if ($selectedEngine -eq "collama") {
                if ($envStatus.Engines.ollama_copilot.Reachable) { "ollama-copilot" } else { "ollama-copilot_2" }
            } else {
                if ($selectedEngine -eq "ollama-copilot" -and $envStatus.Engines.ollama_copilot_2.Reachable) {
                    "ollama-copilot_2"
                } elseif ($envStatus.Engines.ollama_copilot.Reachable) {
                    "ollama-copilot"
                } else {
                    "collama"
                }
            }
            Write-Warning "[$selectedEngine] exited with code $exitCode. Attempting automatic failover to '$fallbackEngine'..."
            Invoke-TargetEngine -TargetEngine $fallbackEngine
            $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
        }
        if ($exitCode -ne 0) {
            exit $exitCode
        }
    }
} finally {
    foreach ($key in $envKeysToPreserve) {
        [Environment]::SetEnvironmentVariable($key, $savedEnv[$key], "Process")
    }
}
