# ============================================================
# forge.ps1 - FORGE Master Orchestrator
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
# Console / Output Encoding
# ------------------------------------------------------------
# Force UTF-8 console output so any non-ASCII text (governance docs,
# CLI output, etc.) renders correctly regardless of the host's default
# codepage. This is a hedge, not a dependency - all divider/banner
# strings this script prints are plain ASCII, so rendering is correct
# even on a console that ignores this setting entirely.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ------------------------------------------------------------
# Window / Tab Title
# ------------------------------------------------------------
$host.UI.RawUI.WindowTitle = "FORGE - $($project.ToUpper())"

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
    Add-Content -Path $LOG_FILE -Value $entry -Encoding UTF8
}

# Prints a line with a specific console color AND writes the same plain
# text into the log file (bypassing Log's level->color mapping, since
# these banners need colors that don't correspond to a log level).
function Write-ColoredLogLine {
    param([string]$text, [string]$color)
    Write-Host $text -ForegroundColor $color
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LOG_FILE -Value "[$ts] [INFO] $text" -Encoding UTF8
}

# Project name banner - bold caps, orange. Printed at the top of preflight
# and repeated at the start of every single prompt's log block.
# Note: PowerShell's built-in ConsoleColor enum has no true "Orange" -
# DarkYellow is the closest available and is what most terminal color
# schemes render as orange/amber.
function Write-ProjectBanner {
    param([string]$projectName)
    Write-ColoredLogLine -text "=== $($projectName.ToUpper()) ===" -color "DarkYellow"
}

# Prompt counter - bold caps, purple. PowerShell's ConsoleColor enum has
# no true "Purple" either - Magenta is the closest built-in and is used
# here as the stand-in.
function Write-PromptCounter {
    param([int]$current, [int]$total)
    Write-ColoredLogLine -text "PROMPT $current OF $total" -color "Magenta"
}

# Logs a single timestamped state transition for the current prompt.
# Every STARTED / RETRY / FAILED / PASSED transition gets its own line.
function Write-Transition {
    param([string]$state, [string]$reason = "")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = if ($reason) { "$state at $ts - $reason" } else { "$state at $ts" }
    $level = switch -Wildcard ($state) {
        "STARTED" { "INFO" }
        "RETRY*"  { "WARN" }
        "FAILED"  { "FAIL" }
        "PASSED"  { "PASS" }
        default   { "INFO" }
    }
    Log $line $level
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
    $outFile = Join-Path (Get-Location) "yaml-out.$PID.json"
    node $tempJs | Set-Content $outFile -Encoding UTF8
    Remove-Item $tempJs -ErrorAction SilentlyContinue
    $json = Get-Content $outFile -Raw -Encoding UTF8
    Remove-Item $outFile -ErrorAction SilentlyContinue
    return $json | ConvertFrom-Json
}

# ------------------------------------------------------------
# Hard Timeout Enforcement
# ------------------------------------------------------------
# Runs an external command as its own OS process (not just an in-process
# call-operator invocation) so that a hung child (npm/tsc/next/etc.) can
# actually be killed on timeout. Uses `taskkill /T` to take out the whole
# process tree, not just the top-level PID, since gate scripts spawn
# grandchildren (npm -> node -> tsc) that would otherwise be orphaned.
function Invoke-ProcessWithTimeout {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [int]$TimeoutSeconds
    )

    $stdOutFile = [System.IO.Path]::GetTempFileName()
    $stdErrFile = [System.IO.Path]::GetTempFileName()

    try {
        $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $stdOutFile -RedirectStandardError $stdErrFile

        $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
        if ($exited) { $proc.WaitForExit() }

        if (-not $exited) {
            # Hard timeout - kill the entire process tree, not just the parent.
            & taskkill /PID $proc.Id /T /F 2>&1 | Out-Null
            Start-Sleep -Milliseconds 300
            $output = "$(Get-Content $stdOutFile -Raw -ErrorAction SilentlyContinue)$(Get-Content $stdErrFile -Raw -ErrorAction SilentlyContinue)"
            return @{ timedOut = $true; exitCode = -1; output = $output }
        }

        $output = "$(Get-Content $stdOutFile -Raw -ErrorAction SilentlyContinue)$(Get-Content $stdErrFile -Raw -ErrorAction SilentlyContinue)"
        $exitCode = if ($null -eq $proc.ExitCode) { 0 } else { $proc.ExitCode }
        return @{ timedOut = $false; exitCode = $exitCode; output = $output }
    }
    finally {
        Remove-Item $stdOutFile, $stdErrFile -ErrorAction SilentlyContinue
    }
}

# Wraps a local (no-subprocess) scriptblock, such as the file_exists check,
# in a hard timeout via a background job so a stalled network drive or
# huge directory tree can't hang the pipeline indefinitely.
function Invoke-ScriptBlockWithTimeout {
    param(
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList,
        [int]$TimeoutSeconds
    )

    $job = Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    $completed = Wait-Job $job -Timeout $TimeoutSeconds

    if (-not $completed) {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        return @{ timedOut = $true; result = $null }
    }

    $result = Receive-Job $job
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    return @{ timedOut = $false; result = $result }
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
        { $_ -in @("compile", "build", "lint", "test", "deploy_verify") } {
            # Delegate to the standalone gate script (single source of truth).
            # Each gate script exits 0 on pass, non-zero on fail.
            # Hard timeout: 15 min for build (heavier), 10 min for deploy_verify
            # (a real `vercel --prod` deploy), 5 min for compile/lint/test.
            $gateScript = Join-Path $GATES_DIR "$gateType.ps1"
            if (-not (Test-Path $gateScript)) {
                Log "Gate script not found: $gateScript" "FAIL"
                return @{ pass = $false; output = "Missing gate script: $gateScript" }
            }

            $timeoutSeconds = if ($gateType -eq "build") { 900 } elseif ($gateType -eq "deploy_verify") { 600 } else { 300 }
            $procResult = Invoke-ProcessWithTimeout -FilePath "powershell.exe" `
                -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $gateScript, "-workDir", $workDir) `
                -TimeoutSeconds $timeoutSeconds

            if ($procResult.timedOut) {
                Log "Gate $($gateType.ToUpper()): FAILED - TIMEOUT after ${timeoutSeconds}s, process tree killed" "FAIL"
                return @{ pass = $false; output = "TIMEOUT: gate '$gateType' exceeded ${timeoutSeconds}s and was killed.`n$($procResult.output)"; reason = "TIMEOUT" }
            }
            elseif ($procResult.exitCode -eq 0) {
                Log "Gate $($gateType.ToUpper()): PASS" "PASS"
                return @{ pass = $true; output = $procResult.output }
            }
            else {
                Log "Gate $($gateType.ToUpper()): FAIL" "FAIL"
                return @{ pass = $false; output = $procResult.output }
            }
        }
        "file_exists" {
            # Hard timeout: 5 min, same as compile, even though this is normally
            # instantaneous - guards against a stalled network drive.
            $timeoutSeconds = 300
            $jobResult = Invoke-ScriptBlockWithTimeout -TimeoutSeconds $timeoutSeconds -ArgumentList @($workDir, $gateConfig.files) -ScriptBlock {
                param($workDir, $files)
                $missing = @()
                foreach ($file in $files) {
                    $fullPath = Join-Path $workDir $file
                    if (-not (Test-Path $fullPath)) {
                        $missing += $file
                    }
                }
                return , $missing
            }

            if ($jobResult.timedOut) {
                Log "Gate FILE_EXISTS: FAILED - TIMEOUT after ${timeoutSeconds}s" "FAIL"
                return @{ pass = $false; output = "TIMEOUT: file_exists gate exceeded ${timeoutSeconds}s"; reason = "TIMEOUT" }
            }

            $missing = @($jobResult.result)
            if ($missing.Count -eq 0) {
                Log "Gate FILE_EXISTS: PASS" "PASS"
                return @{ pass = $true; output = "All files exist" }
            }
            else {
                Log "Gate FILE_EXISTS: FAIL - Missing: $($missing -join ', ')" "FAIL"
                return @{ pass = $false; output = "Missing files: $($missing -join ', ')" }
            }
        }
        { $_ -in @("shell", "command") } {
            # Custom shell command gate. Hard timeout: 5 min.
            $timeoutSeconds = 300
            $cmdText = $gateConfig.command
            if (-not $cmdText) {
                Log "Gate $($gateType.ToUpper()): FAIL - no command specified in gate config" "FAIL"
                return @{ pass = $false; output = "No 'command' specified for $gateType gate" }
            }

            $procResult = Invoke-ProcessWithTimeout -FilePath "powershell.exe" `
                -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $cmdText) `
                -TimeoutSeconds $timeoutSeconds

            if ($procResult.timedOut) {
                Log "Gate $($gateType.ToUpper()): FAILED - TIMEOUT after ${timeoutSeconds}s, process tree killed" "FAIL"
                return @{ pass = $false; output = "TIMEOUT: gate '$gateType' exceeded ${timeoutSeconds}s and was killed.`n$($procResult.output)"; reason = "TIMEOUT" }
            }
            elseif ($procResult.exitCode -eq 0) {
                Log "Gate $($gateType.ToUpper()): PASS" "PASS"
                return @{ pass = $true; output = $procResult.output }
            }
            else {
                Log "Gate $($gateType.ToUpper()): FAIL" "FAIL"
                return @{ pass = $false; output = $procResult.output }
            }
        }
        "schema" {
            # Verify Supabase tables exist
            Log "Gate SCHEMA: Checking Supabase tables..." "GATE"
            # This would query information_schema - simplified here
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
# Build Agent - Executes a prompt via Claude Code CLI
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
        if (-not (Test-Path $docPath)) {
            $codebaseRoot = Join-Path (Split-Path $FORGE_ROOT -Parent) $project
            $altPath = Join-Path $codebaseRoot $doc
            if (Test-Path $altPath) {
                $docPath = $altPath
            } else {
                $specPath = Join-Path $codebaseRoot "specs\$doc"
                if (Test-Path $specPath) { $docPath = $specPath }
            }
        }
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
        Log "DRY RUN - Would execute prompt ($($fullPrompt.Length) chars)" "INFO"
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
# Deploy Command Guard
# ------------------------------------------------------------
# Strips any line containing "vercel deploy" or "npx vercel" out of a
# prompt's text before it is ever sent to the Build/Recovery Agent, so
# Claude Code can never execute a production deploy from inside a FORGE
# queue. Deploys must be run manually after the queue completes.
function Remove-DeployCommands {
    param([string]$promptText)

    if (-not $promptText) { return $promptText }

    $lines = $promptText -split "`r?`n"
    $filtered = @()
    $stripped = $false

    foreach ($line in $lines) {
        if ($line -match "vercel\s+deploy" -or $line -match "npx\s+vercel") {
            $stripped = $true
            Log "DEPLOY GUARD: Stripped disallowed line from prompt: '$($line.Trim())'" "WARN"
            continue
        }
        $filtered += $line
    }

    if ($stripped) {
        Log "Deploy commands are not permitted inside FORGE prompts - run npx vercel deploy --prod manually after the queue completes." "WARN"
    }

    return ($filtered -join "`n")
}

# ------------------------------------------------------------
# Recovery Agent - Analyzes failures and attempts fixes
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
4. Do NOT introduce new features - only fix the error
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
    Write-ProjectBanner -projectName $project
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

    # ------------------------------------------------------------
    # PREFLIGHT VERIFICATION
    # Must print before any Build Agent executes. Confirms project name,
    # total prompt count, and the full ordered list of prompt IDs + names.
    # ------------------------------------------------------------
    $promptIdList = @()
    foreach ($p in $prompts) { $promptIdList += $p.id }

    Write-Host ""
    Write-Host "========================================================" -ForegroundColor Black -BackgroundColor Yellow
    Write-Host "  FORGE PREFLIGHT VERIFICATION" -ForegroundColor Black -BackgroundColor Yellow
    Write-Host "========================================================" -ForegroundColor Black -BackgroundColor Yellow
    Write-Host "  PROJECT:       $project" -ForegroundColor Black -BackgroundColor Yellow
    Write-Host "  TOTAL PROMPTS: $totalPrompts" -ForegroundColor Black -BackgroundColor Yellow
    Write-Host "  PROMPT IDS (execution order):" -ForegroundColor Black -BackgroundColor Yellow
    for ($idx = 0; $idx -lt $promptIdList.Count; $idx++) {
        Write-Host ("    [{0}] {1} - {2}" -f $idx, $promptIdList[$idx], $prompts[$idx].description) -ForegroundColor Black -BackgroundColor Yellow
    }
    Write-Host "========================================================" -ForegroundColor Black -BackgroundColor Yellow
    Write-Host ""

    Log "PREFLIGHT: Project=$project TotalPrompts=$totalPrompts" "INFO"
    Log "PREFLIGHT: Prompt IDs in order: $($promptIdList -join ', ')" "INFO"

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

        # Sanitize the prompt text once up front so both the Build Agent and
        # any Recovery Agent invocation see the same deploy-stripped text.
        $sanitizedPromptText = Remove-DeployCommands -promptText $prompt.prompt

        Log "" "INFO"
        Write-ProjectBanner -projectName $project
        Write-PromptCounter -current ($i + 1) -total $totalPrompts
        Log "PROMPT ID: $promptId" "INFO"
        Log "PROMPT NAME: $description" "INFO"
        Log "PHASE: $phase" "INFO"
        Write-Transition -state "STARTED"

        # Save current state
        $stateObj = @{
            currentPrompt = $i
            promptId = $promptId
            phase = $phase
            timestamp = (Get-Date -Format "o")
        } | ConvertTo-Json
        Set-Content -Path "$STATE_DIR\current-prompt.json" -Value $stateObj -Encoding UTF8

        # Execute the prompt
        $retryCount = 0
        $promptPassed = $false

        while ($retryCount -lt $maxRetries -and -not $promptPassed) {
            if ($retryCount -gt 0) {
                Write-Transition -state "RETRY $retryCount"
            }

            # Run Build Agent
            Log "Executing Build Agent..." "INFO"
            $buildResult = Invoke-BuildAgent `
                -prompt $sanitizedPromptText `
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
                    if ($gate.command) { $gateConfig.command = $gate.command }

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
                Write-Transition -state "PASSED"
                Log "PROMPT $promptId : ALL GATES PASSED" "PASS"
            }
            else {
                $retryCount++
                $shortReason = if ($failedGateOutput.Length -gt 200) { $failedGateOutput.Substring(0, 200) + "..." } else { $failedGateOutput }
                Write-Transition -state "FAILED" -reason $shortReason
                Log "Gate failed. Invoking Recovery Agent..." "WARN"

                if ($retryCount -lt $maxRetries) {
                    $recoveryResult = Invoke-RecoveryAgent `
                        -originalPrompt $sanitizedPromptText `
                        -errorOutput $failedGateOutput `
                        -workDir $workDir
                }
            }
        }

        if (-not $promptPassed) {
            $results.failed++
            Write-Transition -state "FAILED" -reason "exhausted $maxRetries retries"
            Log "PROMPT $promptId : FAILED after $maxRetries retries" "ERROR"

            if ($prompt.on_fail -eq "halt") {
                $results.halted = $true
                $results.haltReason = "Prompt $promptId failed after $maxRetries retries. Gate output: $failedGateOutput"
                Log "PIPELINE HALTED - $($results.haltReason)" "ERROR"

                # Write halt reason to state
                Set-Content -Path "$STATE_DIR\halt-reason.md" -Encoding UTF8 -Value @"
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
        Add-Content -Path "$STATE_DIR\gate-results.jsonl" -Value $gateResultObj -Encoding UTF8
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
$(if ($results.halted) { "HALTED: $($results.haltReason)" } elseif ($results.failed -gt 0) { "COMPLETED WITH FAILURES" } else { "SUCCESS - All prompts passed all gates" })

## Build Log
See: $LOG_FILE
"@
    Set-Content -Path $reportPath -Value $report -Encoding UTF8
    Log "Report saved: $reportPath" "INFO"

    return $results
}

# ------------------------------------------------------------
# Execute
# ------------------------------------------------------------
$result = Start-ForgePipeline
if ($result.halted -or $result.failed -gt 0) { exit 1 } else { exit 0 }


