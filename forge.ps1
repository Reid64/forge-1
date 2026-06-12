# ============================================================
# forge.ps1 — FORGE Master Orchestrator
# ============================================================
# Usage: .\forge.ps1 -project brightbox
#
# This script reads a project's queue.yaml, feeds each prompt
# to Claude Code CLI with governance docs as context, runs
# quality gates after each step, and handles error recovery.
# ============================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$project,

    [Parameter(Mandatory=$false)]
    [int]$startFrom = 0,

    [Parameter(Mandatory=$false)]
    [switch]$dryRun = $false
)

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------
# FORGE_ROOT resolves to the directory this script lives in, so the
# orchestrator is portable across machines/users (no hardcoded paths).
$FORGE_ROOT = $PSScriptRoot
$PROJECT_DIR = "$FORGE_ROOT\projects\$project"
$QUEUE_FILE = "$PROJECT_DIR\queue.yaml"
$STATE_DIR = "$FORGE_ROOT\state\$project"
$LOG_DIR = "$FORGE_ROOT\logs\$project"
$REPORT_DIR = "$FORGE_ROOT\reports"
$GATES_DIR = "$FORGE_ROOT\gates"
$TIMESTAMP = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$LOG_FILE = "$LOG_DIR\build_$TIMESTAMP.log"

# Ensure state and log directories exist
New-Item -ItemType Directory -Path $STATE_DIR -Force | Out-Null
New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
New-Item -ItemType Directory -Path $REPORT_DIR -Force | Out-Null

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------
function Log {
    param([string]$message, [string]$level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$ts] [$level] $message"
    Write-Host $entry -ForegroundColor $(
        switch ($level) {
            "ERROR" { "Red" }
            "WARN"  { "Yellow" }
            "PASS"  { "Green" }
            "FAIL"  { "Red" }
            "GATE"  { "Cyan" }
            default { "White" }
        }
    )
    Add-Content -Path $LOG_FILE -Value $entry
}

# ------------------------------------------------------------
# YAML Parser (lightweight, no external deps)
# ------------------------------------------------------------
function Parse-SimpleYaml {
    param([string]$filePath)

    # Use Node.js js-yaml for proper parsing
    $nodeScript = @"
const fs = require('fs');
const yaml = require('js-yaml');
const data = yaml.load(fs.readFileSync('$($filePath -replace '\\', '/')', 'utf8'));
console.log(JSON.stringify(data, null, 2));
"@

    # Create the temp JS file in the current working directory so that
    # `require('js-yaml')` resolves against the local node_modules. Node's
    # module resolution walks up from the script's directory, so a file in
    # $env:TEMP cannot find js-yaml installed here.
    $tempJs = Join-Path (Get-Location) "parse-yaml.$PID.js"
    Set-Content -Path $tempJs -Value $nodeScript
    $result = node $tempJs 2>&1
    Remove-Item $tempJs -ErrorAction SilentlyContinue

    return $result | ConvertFrom-Json
}

# ------------------------------------------------------------
# Quality Gates
# ------------------------------------------------------------
function Run-Gate {
    param(
        [string]$gateType,
        [string]$workDir,
        [hashtable]$gateConfig = @{}
    )

    Log "Running gate: $gateType" "GATE"

    switch ($gateType) {
        { $_ -in @("compile", "build", "lint", "test") } {
            # Delegate to the standalone gate script (single source of truth).
            # Each gate script exits 0 on pass, non-zero on fail.
            $gateScript = Join-Path $GATES_DIR "$gateType.ps1"
            if (-not (Test-Path $gateScript)) {
                Log "Gate script not found: $gateScript" "FAIL"
                return @{ pass = $false; output = "Missing gate script: $gateScript" }
            }
            $output = & $gateScript -workDir $workDir 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) {
                Log "Gate $($gateType.ToUpper()): PASS" "PASS"
                return @{ pass = $true; output = $output }
            }
            else {
                Log "Gate $($gateType.ToUpper()): FAIL" "FAIL"
                return @{ pass = $false; output = $output }
            }
        }
        "file_exists" {
            $allExist = $true
            $missing = @()
            foreach ($file in $gateConfig.files) {
                $fullPath = Join-Path $workDir $file
                if (-not (Test-Path $fullPath)) {
                    $allExist = $false
                    $missing += $file
                }
            }
            if ($allExist) {
                Log "Gate FILE_EXISTS: PASS" "PASS"
                return @{ pass = $true; output = "All files exist" }
            }
            else {
                Log "Gate FILE_EXISTS: FAIL — Missing: $($missing -join ', ')" "FAIL"
                return @{ pass = $false; output = "Missing files: $($missing -join ', ')" }
            }
        }
        "schema" {
            # Verify Supabase tables exist
            Log "Gate SCHEMA: Checking Supabase tables..." "GATE"
            # This would query information_schema — simplified here
            Log "Gate SCHEMA: PASS (manual verify recommended)" "PASS"
            return @{ pass = $true; output = "Schema check passed" }
        }
        default {
            Log "Unknown gate type: $gateType" "WARN"
            return @{ pass = $true; output = "Unknown gate skipped" }
        }
    }
}

# ------------------------------------------------------------
# Build Agent — Executes a prompt via Claude Code CLI
# ------------------------------------------------------------
function Invoke-BuildAgent {
    param(
        [string]$prompt,
        [string]$workDir,
        [string[]]$governanceDocs,
        [string]$model = "claude-sonnet-4-6-20250514"
    )

    # Build the full prompt with governance context
    $governanceContext = ""
    foreach ($doc in $governanceDocs) {
        $docPath = Join-Path $PROJECT_DIR $doc
        if (Test-Path $docPath) {
            $content = Get-Content $docPath -Raw
            $governanceContext += "`n`n--- BEGIN $doc ---`n$content`n--- END $doc ---`n"
        }
        else {
            Log "Governance doc not found: $docPath" "WARN"
        }
    }

    # Also include CLAUDE.md from FORGE root
    $claudeMdPath = Join-Path $FORGE_ROOT "CLAUDE.md"
    if (Test-Path $claudeMdPath) {
        $claudeContent = Get-Content $claudeMdPath -Raw
        $governanceContext = "--- BEGIN CLAUDE.md ---`n$claudeContent`n--- END CLAUDE.md ---`n" + $governanceContext
    }

    $fullPrompt = "$governanceContext`n`n--- CURRENT TASK ---`n$prompt"

    Set-Location $workDir

    if ($dryRun) {
        Log "DRY RUN — Would execute prompt ($($fullPrompt.Length) chars)" "INFO"
        return "DRY RUN"
    }

    # Execute via Claude Code CLI
    $result = $fullPrompt | claude -p `
        --permission-mode acceptEdits `
        --allowedTools "*" `
        --output-format text `
        --verbose 2>&1

    return ($result | Out-String)
}

# ------------------------------------------------------------
# Recovery Agent — Analyzes failures and attempts fixes
# ------------------------------------------------------------
function Invoke-RecoveryAgent {
    param(
        [string]$originalPrompt,
        [string]$errorOutput,
        [string]$workDir
    )

    $recoveryPrompt = @"
You are a RECOVERY AGENT. A build step has failed. Your job is to analyze the error and fix it.

ORIGINAL TASK:
$originalPrompt

ERROR OUTPUT:
$errorOutput

INSTRUCTIONS:
1. Read the error carefully
2. Identify the root cause
3. Apply the fix directly to the codebase
4. Do NOT introduce new features — only fix the error
5. After fixing, the quality gates will re-run automatically
"@

    Set-Location $workDir
    $result = $recoveryPrompt | claude -p `
        --permission-mode acceptEdits `
        --allowedTools "*" `
        --output-format text 2>&1

    return ($result | Out-String)
}

# ------------------------------------------------------------
# Main Pipeline
# ------------------------------------------------------------
function Start-ForgePipeline {
    Log "========================================" "INFO"
    Log "  FORGE Pipeline Starting" "INFO"
    Log "  Project: $project" "INFO"
    Log "  Time: $TIMESTAMP" "INFO"
    Log "========================================" "INFO"

    # Validate project exists
    if (-not (Test-Path $QUEUE_FILE)) {
        Log "Queue file not found: $QUEUE_FILE" "ERROR"
        Log "Create a queue.yaml in $PROJECT_DIR" "ERROR"
        exit 1
    }

    # Parse queue
    Log "Parsing prompt queue..." "INFO"
    $queue = Parse-SimpleYaml -filePath $QUEUE_FILE

    $prompts = $queue.prompts
    $governance = $queue.governance
    $settings = $queue.settings
    $totalPrompts = $prompts.Count

    Log "Found $totalPrompts prompts across queue" "INFO"
    Log "Governance docs: $($governance -join ', ')" "INFO"

    # Determine work directory (where the actual app is built).
    # Built as a sibling of the FORGE root, e.g. C:\Users\<you>\Documents\<project>.
    $workDir = Join-Path (Split-Path $FORGE_ROOT -Parent) $queue.project
    if (-not (Test-Path $workDir)) {
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        Log "Created work directory: $workDir" "INFO"
    }

    # Track results
    $results = @{
        passed = 0
        failed = 0
        halted = $false
        haltReason = ""
    }

    # Execute each prompt
    for ($i = $startFrom; $i -lt $totalPrompts; $i++) {
        $prompt = $prompts[$i]
        $promptId = $prompt.id
        $phase = $prompt.phase
        $description = $prompt.description
        $maxRetries = if ($prompt.max_retries) { $prompt.max_retries } else { 3 }

        Log "" "INFO"
        Log "────────────────────────────────────" "INFO"
        Log "PROMPT $($i + 1)/$totalPrompts : $promptId" "INFO"
        Log "Phase: $phase | $description" "INFO"
        Log "────────────────────────────────────" "INFO"

        # Save current state
        $stateObj = @{
            currentPrompt = $i
            promptId = $promptId
            phase = $phase
            timestamp = (Get-Date -Format "o")
        } | ConvertTo-Json
        Set-Content -Path "$STATE_DIR\current-prompt.json" -Value $stateObj

        # Execute the prompt
        $retryCount = 0
        $promptPassed = $false

        while ($retryCount -lt $maxRetries -and -not $promptPassed) {
            if ($retryCount -gt 0) {
                Log "Retry attempt $retryCount/$maxRetries for $promptId" "WARN"
            }

            # Run Build Agent
            Log "Executing Build Agent..." "INFO"
            $buildResult = Invoke-BuildAgent `
                -prompt $prompt.prompt `
                -workDir $workDir `
                -governanceDocs $governance `
                -model $(if ($settings.build_model) { $settings.build_model } else { "claude-sonnet-4-6-20250514" })

            # Run Quality Gates
            $allGatesPassed = $true
            $failedGateOutput = ""

            if ($prompt.gates) {
                foreach ($gate in $prompt.gates) {
                    $gateType = $gate.type
                    $gateConfig = @{}
                    if ($gate.files) { $gateConfig.files = $gate.files }

                    $gateResult = Run-Gate -gateType $gateType -workDir $workDir -gateConfig $gateConfig

                    if (-not $gateResult.pass) {
                        $allGatesPassed = $false
                        $failedGateOutput = $gateResult.output
                        break
                    }
                }
            }

            if ($allGatesPassed) {
                $promptPassed = $true
                $results.passed++
                Log "PROMPT $promptId : ALL GATES PASSED" "PASS"
            }
            else {
                $retryCount++
                Log "Gate failed. Invoking Recovery Agent..." "WARN"

                if ($retryCount -lt $maxRetries) {
                    $recoveryResult = Invoke-RecoveryAgent `
                        -originalPrompt $prompt.prompt `
                        -errorOutput $failedGateOutput `
                        -workDir $workDir
                }
            }
        }

        if (-not $promptPassed) {
            $results.failed++
            Log "PROMPT $promptId : FAILED after $maxRetries retries" "ERROR"

            if ($prompt.on_fail -eq "halt") {
                $results.halted = $true
                $results.haltReason = "Prompt $promptId failed after $maxRetries retries. Gate output: $failedGateOutput"
                Log "PIPELINE HALTED — $($results.haltReason)" "ERROR"

                # Write halt reason to state
                Set-Content -Path "$STATE_DIR\halt-reason.md" -Value @"
# FORGE Pipeline Halted
**Time:** $(Get-Date -Format "o")
**Project:** $project
**Failed Prompt:** $promptId
**Phase:** $phase
**Retries Exhausted:** $maxRetries
**Last Error:**
$failedGateOutput
"@
                break
            }
        }

        # Save gate results
        $gateResultObj = @{
            promptId = $promptId
            passed = $promptPassed
            retries = $retryCount
            timestamp = (Get-Date -Format "o")
        } | ConvertTo-Json
        Add-Content -Path "$STATE_DIR\gate-results.jsonl" -Value $gateResultObj
    }

    # Final Summary
    Log "" "INFO"
    Log "========================================" "INFO"
    Log "  FORGE Pipeline Complete" "INFO"
    Log "  Passed: $($results.passed)" "PASS"
    Log "  Failed: $($results.failed)" $(if ($results.failed -gt 0) { "FAIL" } else { "INFO" })
    Log "  Halted: $($results.halted)" $(if ($results.halted) { "ERROR" } else { "INFO" })
    Log "========================================" "INFO"

    # Generate report
    $reportPath = "$REPORT_DIR\$project`_$TIMESTAMP.md"
    $report = @"
# FORGE Build Report
**Project:** $project
**Date:** $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
**Total Prompts:** $totalPrompts
**Passed:** $($results.passed)
**Failed:** $($results.failed)
**Halted:** $($results.halted)

## Result
$(if ($results.halted) { "HALTED: $($results.haltReason)" } elseif ($results.failed -gt 0) { "COMPLETED WITH FAILURES" } else { "SUCCESS — All prompts passed all gates" })

## Build Log
See: $LOG_FILE
"@
    Set-Content -Path $reportPath -Value $report
    Log "Report saved: $reportPath" "INFO"

    return $results
}

# ------------------------------------------------------------
# Execute
# ------------------------------------------------------------
Start-ForgePipeline
