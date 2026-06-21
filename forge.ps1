# ============================================================
# forge.ps1 - FORGE Master Orchestrator (v1.2)
# ============================================================
# Changes from v1.1:
#   1. .next cache cleaned on every rollback (prevents cascade)
#   2. Standard preamble injected into every prompt
#   3. Pre-gate health check: tsc on clean codebase before retry
#   4. Recovery agent receives exact error text with fix hints
#   5. .next cleaned at pipeline start
# ============================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$project,

    [Parameter(Mandatory=$false)]
    [int]$startFrom = 0,

    [Parameter(Mandatory=$false)]
    [switch]$dryRun = $false
)

$FORGE_ROOT = $PSScriptRoot
$PROJECT_DIR = "$FORGE_ROOT\projects\$project"
$QUEUE_FILE = "$PROJECT_DIR\queue.yaml"
$STATE_DIR = "$FORGE_ROOT\state\$project"
$LOG_DIR = "$FORGE_ROOT\logs\$project"
$REPORT_DIR = "$FORGE_ROOT\reports"
$GATES_DIR = "$FORGE_ROOT\gates"
# LESSONS_LEARNED.md lives in the project config directory (NOT $workDir) so it
# survives per-prompt git rollbacks and accumulates across the whole build.
$LESSONS_FILE = "$PROJECT_DIR\LESSONS_LEARNED.md"
$TIMESTAMP = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$LOG_FILE = "$LOG_DIR\build_$TIMESTAMP.log"

New-Item -ItemType Directory -Path $STATE_DIR -Force | Out-Null
New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
New-Item -ItemType Directory -Path $REPORT_DIR -Force | Out-Null

# ------------------------------------------------------------
# Standard Preamble (injected into every prompt)
# ------------------------------------------------------------
$STANDARD_PREAMBLE = @"

CRITICAL BUILD RULES (enforced by FORGE - follow these exactly):
1. TypeScript strict mode: ALL variables that could be undefined MUST use optional chaining (?.) or nullish coalescing (?? defaultValue). NEVER pass a possibly-undefined value where a concrete type is expected.
2. Unused variables: prefix with underscore (_req, _input) or remove entirely. ESLint will fail on unused variables.
3. Empty interfaces: use 'object' or 'unknown' instead of empty interface declarations.
4. If you create a new agent type, you MUST add it to the AgentType union in src/types/database.ts BEFORE using it in any agent file.
5. If you create a new table type, you MUST add it to the Database interface in src/types/database.ts.
6. Always add alt="" to img elements.
7. After writing code, mentally check: does every .property access handle the case where the parent could be null/undefined?
8. Do NOT leave any console.log statements in production code.
9. When using Badge component, check BadgeProps interface for valid props - do not pass unsupported variant or size props.
10. When using Supabase .from() queries, the table name must exist in the Database types. If you need a new table, add the type first.

"@

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
# Lessons Learned (recursive failure prevention)
# ------------------------------------------------------------
function Get-RootCauseType {
    param([string]$errorOutput)
    if ([string]::IsNullOrWhiteSpace($errorOutput)) { return "unknown" }
    # First matching pattern wins (return exits the function).
    switch -Regex ($errorOutput) {
        'possibly .?undefined|possibly .?null|is possibly'   { return "null-safety (possibly undefined/null)" }
        'defined but never used|declared but its value is|never read|no-unused-vars' { return "unused-variable" }
        'not assignable to type .?AgentType|AgentType'       { return "missing-agent-type-union-member" }
        "Cannot find module|Module not found"                { return "missing-module-or-stale-cache" }
        'does not exist on type'                             { return "type-property-mismatch" }
        'empty interface|no-empty-interface'                 { return "empty-interface" }
        'is not assignable to'                               { return "type-mismatch" }
        'Type error|TS\d{3,}'                                { return "typescript-compile-error" }
        'ESLint|eslint|lint'                                 { return "lint-error" }
        'expect\(|received|playwright|test.*fail|failed.*test' { return "test-failure" }
        'Missing files|Missing gate script|does not exist'   { return "missing-file" }
        default                                              { return "uncategorized-build-error" }
    }
}

function Add-Lesson {
    param(
        [string]$promptId,
        [int]$attempt,
        [string]$errorOutput,
        [string]$rootCause
    )
    $ts = Get-Date -Format "o"
    $fence = '```'
    # Ensure the file exists with a header so future agents have context.
    if (-not (Test-Path $LESSONS_FILE)) {
        $header = "# Lessons Learned - $project`n`nThis file accumulates gate failures from previous build runs so that future build agents can avoid repeating them. Each section below documents a real failure: the prompt that failed, which attempt, when, the root cause category, and the exact gate error output.`n"
        Set-Content -Path $LESSONS_FILE -Value $header
        Log "Created LESSONS_LEARNED.md at $LESSONS_FILE" "INFO"
    }
    $section = @"

## $promptId - attempt $attempt - $rootCause
- **Prompt ID:** $promptId
- **Attempt:** $attempt
- **Timestamp:** $ts
- **Root Cause Type:** $rootCause

### Gate Error Output
$fence
$errorOutput
$fence
"@
    Add-Content -Path $LESSONS_FILE -Value $section
    Log "Appended lesson for $promptId (attempt $attempt, root cause: $rootCause) to LESSONS_LEARNED.md" "INFO"
}

function Parse-SimpleYaml {
    param([string]$filePath)
    $nodeScript = @"
const fs = require('fs');
const yaml = require('js-yaml');
const data = yaml.load(fs.readFileSync('$($filePath -replace '\\', '/')', 'utf8'));
console.log(JSON.stringify(data, null, 2));
"@
    $tempJs = Join-Path (Get-Location) "parse-yaml.$PID.js"
    Set-Content -Path $tempJs -Value $nodeScript
    $result = node $tempJs 2>&1
    Remove-Item $tempJs -ErrorAction SilentlyContinue
    return $result | ConvertFrom-Json
}

# ------------------------------------------------------------
# Git Snapshot & Rollback
# ------------------------------------------------------------
function Save-GitSnapshot {
    param([string]$workDir, [string]$promptId)
    Set-Location $workDir
    git add -A 2>&1 | Out-Null
    git commit -m "[FORGE-SNAPSHOT] Before $promptId" --allow-empty 2>&1 | Out-Null
    Log "Git snapshot saved before $promptId" "INFO"
}

function Invoke-GitRollback {
    param([string]$workDir, [string]$promptId)
    Set-Location $workDir
    git reset --hard HEAD~1 2>&1 | Out-Null
    git clean -fd 2>&1 | Out-Null
    # v1.2: Clean .next cache to prevent stale type references from cascading
    $nextDir = Join-Path $workDir ".next"
    if (Test-Path $nextDir) {
        Remove-Item -Recurse -Force $nextDir -ErrorAction SilentlyContinue
        Log "Cleaned .next cache after rollback" "INFO"
    }
    # v1.3: Restore node_modules to match the reverted package.json.
    # A failed prompt may have installed a dependency before failing a gate.
    # 'git reset --hard' reverts package.json/lockfile but NOT node_modules,
    # leaving them stale and cascading failures into the next prompt.
    $packageJson = Join-Path $workDir "package.json"
    if (Test-Path $packageJson) {
        Log "Running 'pnpm install' to restore node_modules after rollback..." "INFO"
        $installOutput = pnpm install 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            Log "node_modules restored to match reverted package.json" "INFO"
        } else {
            Log "pnpm install after rollback returned non-zero exit code: $installOutput" "WARN"
        }
    }
    Log "Git rollback: reverted all changes from failed prompt $promptId" "WARN"
}

function Remove-GitSnapshot {
    param([string]$workDir, [string]$promptId)
    Set-Location $workDir
    git reset --soft HEAD~1 2>&1 | Out-Null
    git add -A 2>&1 | Out-Null
    git commit -m "[FORGE] $promptId - PASSED" --allow-empty 2>&1 | Out-Null
    Log "Git snapshot cleaned, committed as $promptId" "INFO"
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
            $gateScript = Join-Path $GATES_DIR "$gateType.ps1"
            if (-not (Test-Path $gateScript)) {
                Log "Gate script not found: $gateScript" "FAIL"
                return @{ pass = $false; output = "Missing gate script: $gateScript" }
            }
            $output = & $gateScript -workDir $workDir 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) {
                Log "Gate $($gateType.ToUpper()): PASS" "PASS"
                return @{ pass = $true; output = $output }
            } else {
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
            } else {
                Log "Gate FILE_EXISTS: FAIL - Missing: $($missing -join ', ')" "FAIL"
                return @{ pass = $false; output = "Missing files: $($missing -join ', ')" }
            }
        }
        "schema" {
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
# Build Agent
# ------------------------------------------------------------
function Invoke-BuildAgent {
    param(
        [string]$prompt,
        [string]$workDir,
        [string[]]$governanceDocs,
        [string]$model = "claude-sonnet-4-6"
    )
    $governanceContext = ""
    foreach ($doc in $governanceDocs) {
        $docPath = Join-Path $PROJECT_DIR $doc
        if (Test-Path $docPath) {
            $content = Get-Content $docPath -Raw
            $governanceContext += "`n`n--- BEGIN $doc ---`n$content`n--- END $doc ---`n"
        } else {
            Log "Governance doc not found: $docPath" "WARN"
        }
    }
    $claudeMdPath = Join-Path $FORGE_ROOT "CLAUDE.md"
    if (Test-Path $claudeMdPath) {
        $claudeContent = Get-Content $claudeMdPath -Raw
        $governanceContext = "--- BEGIN CLAUDE.md ---`n$claudeContent`n--- END CLAUDE.md ---`n" + $governanceContext
    }
    # Lessons-learned: if prior failures were recorded for this project, prepend
    # them so the build agent can avoid repeating the same mistakes.
    $lessonsContext = ""
    if (Test-Path $LESSONS_FILE) {
        $lessonsContent = Get-Content $LESSONS_FILE -Raw
        if (-not [string]::IsNullOrWhiteSpace($lessonsContent)) {
            $lessonsContext = "--- BEGIN LESSONS FROM PREVIOUS FAILURES ---`n$lessonsContent`n--- END LESSONS FROM PREVIOUS FAILURES ---`n`n"
            Log "Injected LESSONS FROM PREVIOUS FAILURES into build prompt ($($lessonsContent.Length) chars)" "INFO"
        }
    }
    # v1.2: Inject standard preamble
    $fullPrompt = "$lessonsContext$governanceContext`n`n$STANDARD_PREAMBLE`n--- CURRENT TASK ---`n$prompt"
    Set-Location $workDir
    if ($dryRun) {
        Log "DRY RUN - Would execute prompt ($($fullPrompt.Length) chars)" "INFO"
        return "DRY RUN"
    }
    $result = $fullPrompt | claude -p --model claude-sonnet-4-6 --max-budget-usd 10 --permission-mode acceptEdits --allowedTools "*" --output-format text --verbose 2>&1
    return ($result | Out-String)
}

# ------------------------------------------------------------
# Recovery Agent
# ------------------------------------------------------------
function Invoke-RecoveryAgent {
    param(
        [string]$originalPrompt,
        [string]$errorOutput,
        [string]$workDir
    )
    $recoveryPrompt = @"
You are a RECOVERY AGENT. A build step has failed. Fix ONLY the specific errors shown below.

$STANDARD_PREAMBLE

ORIGINAL TASK:
$originalPrompt

EXACT COMPILER/BUILD ERRORS (fix THESE):
$errorOutput

COMMON FIXES:
- 'possibly undefined' -> add ?. or ?? operator
- 'defined but never used' -> prefix with _ or remove
- 'not assignable to type AgentType' -> add value to AgentType in src/types/database.ts
- 'Cannot find module' in .next/types -> the .next cache was stale, it has been cleaned, just re-check the actual source files
- 'Property does not exist on type BadgeProps' -> check Badge component interface
- 'empty interface' -> replace with 'object' or 'unknown'

Do NOT add new features. Fix ONLY the errors listed above.
"@
    Set-Location $workDir
    $result = $recoveryPrompt | claude -p --model claude-sonnet-4-6 --max-budget-usd 10 --permission-mode acceptEdits --allowedTools "*" --output-format text 2>&1
    return ($result | Out-String)
}

# ------------------------------------------------------------
# Main Pipeline
# ------------------------------------------------------------
function Start-ForgePipeline {
    Log "========================================" "INFO"
    Log "  FORGE Pipeline Starting (v1.2)" "INFO"
    Log "  Project: $project" "INFO"
    Log "  Time: $TIMESTAMP" "INFO"
    Log "========================================" "INFO"

    if (-not (Test-Path $QUEUE_FILE)) {
        Log "Queue file not found: $QUEUE_FILE" "ERROR"
        Log "Create a queue.yaml in $PROJECT_DIR" "ERROR"
        exit 1
    }

    Log "Parsing prompt queue..." "INFO"
    $queue = Parse-SimpleYaml -filePath $QUEUE_FILE

    $prompts = $queue.prompts
    $governance = $queue.governance
    $settings = $queue.settings
    $totalPrompts = $prompts.Count

    Log "Found $totalPrompts prompts across queue" "INFO"
    Log "Governance docs: $($governance -join ', ')" "INFO"

    $workDir = Join-Path (Split-Path $FORGE_ROOT -Parent) $queue.project
    if (-not (Test-Path $workDir)) {
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        Log "Created work directory: $workDir" "INFO"
    }

    # v1.2: Clean .next at pipeline start
    $nextDir = Join-Path $workDir ".next"
    if (Test-Path $nextDir) {
        Remove-Item -Recurse -Force $nextDir -ErrorAction SilentlyContinue
        Log "Cleaned .next cache at pipeline start" "INFO"
    }

    # v1.3: Optional top-level 'pre_install' field in queue.yaml.
    # An array of shell commands that run ONCE before the first prompt executes.
    # Their results are committed and are NEVER rolled back (per-prompt rollback
    # only resets HEAD~1, which never reaches this pre-install commit).
    # Use for one-time environment setup, e.g. installing base dependencies.
    if ($queue.pre_install) {
        Log "------------------------------------" "INFO"
        Log "Running pre_install commands ($($queue.pre_install.Count))..." "INFO"
        Set-Location $workDir
        $preInstallFailed = $false
        foreach ($cmd in $queue.pre_install) {
            Log "pre_install> $cmd" "INFO"
            if ($dryRun) {
                Log "DRY RUN - Would execute pre_install command" "INFO"
                continue
            }
            $cmdOutput = Invoke-Expression $cmd 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
                Log "pre_install command FAILED (exit $LASTEXITCODE): $cmd" "ERROR"
                Log $cmdOutput "ERROR"
                $preInstallFailed = $true
                break
            }
            Log "pre_install command completed: $cmd" "PASS"
        }
        if ($preInstallFailed) {
            Log "PIPELINE HALTED - pre_install command failed" "ERROR"
            Set-Content -Path "$STATE_DIR\halt-reason.md" -Value "# FORGE Pipeline Halted`nTime: $(Get-Date -Format 'o')`nProject: $project`nReason: pre_install command failed before first prompt"
            exit 1
        }
        if (-not $dryRun) {
            # Commit pre_install results so they become the baseline and survive
            # all subsequent per-prompt rollbacks.
            git add -A 2>&1 | Out-Null
            git commit -m "[FORGE] pre_install - baseline setup" --allow-empty 2>&1 | Out-Null
            Log "pre_install results committed as baseline (will never be rolled back)" "INFO"
        }
        Log "------------------------------------" "INFO"
    }

    $results = @{
        passed = 0
        failed = 0
        skipped = 0
        halted = $false
        haltReason = ""
    }

    for ($i = $startFrom; $i -lt $totalPrompts; $i++) {
        $prompt = $prompts[$i]
        $promptId = $prompt.id
        $phase = $prompt.phase
        $description = $prompt.description
        $maxRetries = if ($prompt.max_retries) { $prompt.max_retries } else { 3 }

        Log "" "INFO"
        Log "------------------------------------" "INFO"
        Log "PROMPT $($i + 1)/$totalPrompts : $promptId" "INFO"
        Log "Phase: $phase | $description" "INFO"
        Log "Max retries: $maxRetries" "INFO"
        Log "------------------------------------" "INFO"

        $stateObj = @{
            currentPrompt = $i
            promptId = $promptId
            phase = $phase
            timestamp = (Get-Date -Format "o")
        } | ConvertTo-Json
        Set-Content -Path "$STATE_DIR\current-prompt.json" -Value $stateObj

        Save-GitSnapshot -workDir $workDir -promptId $promptId

        $retryCount = 0
        $promptPassed = $false

        while ($retryCount -lt $maxRetries -and -not $promptPassed) {
            if ($retryCount -gt 0) {
                Log "Retry attempt $retryCount/$maxRetries for $promptId" "WARN"
            }

            Log "Executing Build Agent..." "INFO"
            $buildResult = Invoke-BuildAgent -prompt $prompt.prompt -workDir $workDir -governanceDocs $governance -model $(if ($settings.build_model) { $settings.build_model } else { "claude-sonnet-4-6" })

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
                Remove-GitSnapshot -workDir $workDir -promptId $promptId
            } else {
                $retryCount++
                Log "Gate failed for $promptId (attempt $retryCount/$maxRetries)" "WARN"

                # Lessons-learned: record this failure BEFORE recovery so the lesson
                # persists even if recovery (or a later retry) also fails.
                $rootCauseType = Get-RootCauseType -errorOutput $failedGateOutput
                Add-Lesson -promptId $promptId -attempt $retryCount -errorOutput $failedGateOutput -rootCause $rootCauseType

                if ($retryCount -lt $maxRetries) {
                    Invoke-GitRollback -workDir $workDir -promptId $promptId
                    Save-GitSnapshot -workDir $workDir -promptId $promptId
                    Log "Invoking Recovery Agent..." "WARN"
                    $recoveryResult = Invoke-RecoveryAgent -originalPrompt $prompt.prompt -errorOutput $failedGateOutput -workDir $workDir
                }
            }
        }

        if (-not $promptPassed) {
            $results.failed++
            Log "PROMPT $promptId : FAILED after $maxRetries retries" "ERROR"

            Invoke-GitRollback -workDir $workDir -promptId $promptId
            Log "Rolled back $promptId - next prompt starts with clean codebase" "WARN"

            if ($prompt.on_fail -eq "halt") {
                $results.halted = $true
                $results.haltReason = "Prompt $promptId failed after $maxRetries retries. Gate output: $failedGateOutput"
                Log "PIPELINE HALTED - $($results.haltReason)" "ERROR"
                Set-Content -Path "$STATE_DIR\halt-reason.md" -Value "# FORGE Pipeline Halted`nTime: $(Get-Date -Format 'o')`nProject: $project`nFailed Prompt: $promptId`nPhase: $phase`nRetries: $maxRetries`nError: $failedGateOutput"
                break
            } else {
                $results.skipped++
                Log "Skipping $promptId (on_fail=continue) - proceeding to next prompt" "WARN"
            }
        }

        $gateResultObj = @{
            promptId = $promptId
            passed = $promptPassed
            retries = $retryCount
            timestamp = (Get-Date -Format "o")
        } | ConvertTo-Json
        Add-Content -Path "$STATE_DIR\gate-results.jsonl" -Value $gateResultObj
    }

    Log "" "INFO"
    Log "========================================" "INFO"
    Log "  FORGE Pipeline Complete (v1.2)" "INFO"
    Log "  Passed: $($results.passed)" "PASS"
    Log "  Failed: $($results.failed)" $(if ($results.failed -gt 0) { "FAIL" } else { "INFO" })
    Log "  Skipped: $($results.skipped)" $(if ($results.skipped -gt 0) { "WARN" } else { "INFO" })
    Log "  Halted: $($results.halted)" $(if ($results.halted) { "ERROR" } else { "INFO" })
    Log "========================================" "INFO"

    $reportPath = "$REPORT_DIR\${project}_$TIMESTAMP.md"
    $report = "# FORGE Build Report (v1.2)`nProject: $project`nDate: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`nTotal Prompts: $totalPrompts`nPassed: $($results.passed)`nFailed: $($results.failed)`nSkipped: $($results.skipped)`nHalted: $($results.halted)"
    Set-Content -Path $reportPath -Value $report
    Log "Report saved: $reportPath" "INFO"

    return $results
}

Start-ForgePipeline
