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
# Slack Notifications
# ------------------------------------------------------------
. "$FORGE_ROOT\forge-slack.ps1"

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
    node $tempJs 2>&1 | Set-Content $outFile -Encoding UTF8
    $nodeExit = $LASTEXITCODE
    Remove-Item $tempJs -ErrorAction SilentlyContinue
    $json = Get-Content $outFile -Raw -Encoding UTF8
    Remove-Item $outFile -ErrorAction SilentlyContinue

    # FG-4 (2026-09-16): node failing here (malformed YAML, js-yaml not
    # resolvable from the CWD) previously produced an empty $json, a $null
    # queue, "Found 0 prompts", and a run that ended reporting no failures.
    # A queue that could not be parsed is a hard stop, not an empty queue.
    if ($nodeExit -ne 0 -or -not $json -or -not $json.Trim()) {
        Log "Queue parse FAILED (node exit $nodeExit). Raw output below." "ERROR"
        Log $json "ERROR"
        throw "Parse-SimpleYaml: could not parse $filePath - node exited $nodeExit. This is a malformed queue.yaml or a js-yaml resolution failure, not an empty queue."
    }

    $parsed = $json | ConvertFrom-Json
    if ($null -eq $parsed -or $null -eq $parsed.prompts -or @($parsed.prompts).Count -eq 0) {
        throw "Parse-SimpleYaml: $filePath parsed but contains zero prompts. Check that the top-level key is 'prompts:' (not 'phases:') and that indices are sequential."
    }
    return $parsed
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
        [int]$TimeoutSeconds,
        [string]$WorkingDirectory = $null
    )

    $stdOutFile = [System.IO.Path]::GetTempFileName()
    $stdErrFile = [System.IO.Path]::GetTempFileName()

    try {
        $startArgs = @{
            FilePath              = $FilePath
            ArgumentList          = $ArgumentList
            NoNewWindow           = $true
            PassThru              = $true
            RedirectStandardOutput = $stdOutFile
            RedirectStandardError  = $stdErrFile
        }
        if ($WorkingDirectory) { $startArgs.WorkingDirectory = $WorkingDirectory }
        $proc = Start-Process @startArgs
        # Touching .Handle right after Start-Process is required for a
        # PassThru'd process object to later report a real .ExitCode - without
        # it, .ExitCode throws (silently, inside the $null-check below) and
        # every gate here would false-PASS on a real failure. Known
        # Start-Process -PassThru quirk, not optional.
        $null = $proc.Handle

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
        # FG-2 (2026-09-16): a null ExitCode must FAIL, never default to 0.
        # The `$null = $proc.Handle` touch above normally makes ExitCode
        # readable, but when it does not (access denied, process already
        # disposed, bitness edge cases) this previously returned 0 -- i.e.
        # PASS -- for a gate that never reported a result. That is the same
        # false-pass class as the original .Handle bug, just one layer down.
        if ($null -eq $proc.ExitCode) {
            Log "Gate process exited but ExitCode was null - treating as FAILURE, not success." "FAIL"
            $exitCode = -2
        }
        else { $exitCode = $proc.ExitCode }
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

            # 2026-09-19: compile raised 300 -> 900. next.config.mjs had ESLint and
            # TypeScript checking disabled during `next build` purely to keep this
            # gate under 300s. That reopened the gap compile.ps1 exists to close
            # (28 consecutive failed deploys, per its own header). Both checks are
            # back on; the budget moves instead. A gate that times out on correct
            # code is a false failure - the same defect class as a false pass.
            $timeoutSeconds = if ($gateType -in @("build", "compile")) { 900 } elseif ($gateType -eq "deploy_verify") { 600 } else { 300 }
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
                    if (-not (Test-Path -LiteralPath $fullPath)) {
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
            # Custom shell command gate. Queue files specify the command under
            # `run:`; `command:` is accepted too for back-compat. Hard timeout: 5 min.
            $timeoutSeconds = 300
            $cmdText = $gateConfig.command
            if (-not $cmdText) {
                Log "Gate $($gateType.ToUpper()): FAIL - no command specified in gate config" "FAIL"
                return @{ pass = $false; output = "No 'run' (or 'command') specified for $gateType gate" }
            }

            # Precondition: if the command invokes a script file (e.g. `node
            # scripts/audit/verify-foo.mjs`), confirm that file exists in
            # $workDir before running it. A missing script here almost always
            # means the Build Agent turn that was supposed to create it never
            # actually completed (CLI-level failure, usage/rate limit, crash) -
            # surface that plainly instead of letting the interpreter's raw
            # MODULE_NOT_FOUND stack trace stand in for it, which reads like a
            # code/path bug and sends debugging in the wrong direction.
            if ($cmdText -match '([.\w/\\-]+\.(mjs|cjs|js|ts|ps1|py))\b') {
                $scriptRef = $matches[1]
                $scriptFull = Join-Path $workDir $scriptRef
                if (-not (Test-Path -LiteralPath $scriptFull)) {
                    Log "Gate $($gateType.ToUpper()): FAIL - precondition failed, script not found: $scriptRef" "FAIL"
                    return @{ pass = $false; output = "PRECONDITION FAILED: '$scriptRef' does not exist in $workDir. The Build Agent turn that was supposed to create it did not complete - check the 'Build Agent finished (exit=...)' log line immediately above this gate run for the real error (most likely a CLI-level failure: auth, usage/rate limit, network, or crash), not a bug in the script itself." }
                }
            }

            # Run via a temp .ps1 file rather than -Command with an embedded
            # string: $cmdText commonly contains its own double quotes (e.g.
            # `node -e "process.exit(1)"`), which Start-Process's -ArgumentList
            # array re-quoting mangles, silently no-op'ing the command. Writing
            # the raw text to a file sidesteps command-line requoting entirely.
            # Also appends an explicit exit, since powershell.exe does not
            # propagate a native command's exit code to its own by default.
            $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) "forge-gate-cmd-$([guid]::NewGuid().ToString('N')).ps1"
            $scriptContent = "$cmdText`nif (`$LASTEXITCODE) { exit `$LASTEXITCODE } else { exit 0 }"
            Set-Content -Path $tempScript -Value $scriptContent -Encoding UTF8

            try {
                $procResult = Invoke-ProcessWithTimeout -FilePath "powershell.exe" `
                    -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $tempScript) `
                    -TimeoutSeconds $timeoutSeconds -WorkingDirectory $workDir
            }
            finally {
                Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
            }

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
            # FG-6 (2026-09-16): this gate previously logged
            # "PASS (manual verify recommended)" and returned pass=$true
            # WITHOUT querying anything. Every queue that used `- type: schema`
            # banked a free green for a database check that never ran. A gate
            # that cannot verify must fail, never pass with a caveat.
            #
            # Real verification belongs in a `shell` gate the queue owns, e.g.
            #   - type: shell
            #     run: |-
            #       node scripts/audit/verify-schema.mjs table_a table_b
            # so the assertion is explicit, versioned, and reviewable.
            Log "Gate SCHEMA: FAIL - the built-in schema gate performs no verification and has been disabled." "FAIL"
            return @{ pass = $false; output = "The built-in 'schema' gate never queried the database; it returned a hardcoded pass. It is now disabled. Replace it in the queue with an explicit shell gate that runs a real schema assertion script and exits non-zero when a table or column is missing." }
        }
        default {
            # FG-5 (2026-09-16): an unrecognized gate type previously returned
            # pass=$true ("Unknown gate skipped"), so a single typo in a queue
            # -- `typecheck` instead of `compile`, `e2e` instead of `test` --
            # turned a required gate into a silent free pass. A gate FORGE
            # cannot execute has proven nothing and must fail loudly.
            Log "Unknown gate type: '$gateType' - FAILING. Valid types: compile, build, lint, test, deploy_verify, file_exists, shell, command." "FAIL"
            return @{ pass = $false; output = "UNKNOWN GATE TYPE '$gateType'. FORGE cannot execute it, so it cannot pass. Valid types: compile, build, lint, test, deploy_verify, file_exists, shell, command. Fix the queue." }
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
        [string]$model = "claude-sonnet-5",
        [int]$promptIndex = 0
    )

    # NOTE on prompt caching: Anthropic's cache_control:{type:"ephemeral"}
    # is a field on a JSON `messages` request body sent to the Messages API.
    # This function does not build one - $fullPrompt below is plain text
    # piped over stdin to the `claude` CLI, which makes its own API calls
    # internally. There is no JSON payload here to attach cache_control to,
    # so governance-doc caching cannot be controlled from this script.

    # Build the full prompt with governance context
    $governanceContext = ""
    if ($promptIndex -eq 0) {
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
    }
    else {
        Log "[INFO] Governance docs injected on prompt 1 only - skipping for prompts 2+" "INFO"
    }

    $fullPrompt = "$governanceContext`n`n--- CURRENT TASK ---`n$prompt"

    Set-Location $workDir

    if ($dryRun) {
        # FG-9 (2026-09-16): dry run previously skipped only the Build Agent
        # call while the gate loop still ran for real -- including `build`,
        # `shell`, and `deploy_verify`, the last of which performs an actual
        # production deploy. A dry run must not mutate anything. The gate loop
        # now reads this marker and skips every gate except file_exists.
        Log "DRY RUN - Would execute prompt ($($fullPrompt.Length) chars). No Build Agent call, no mutating gates." "INFO"
        return @{ text = "DRY RUN"; exitCode = 0; dryRun = $true }
    }

    # Execute via Claude Code CLI
    # FG-7 (2026-09-16): $model was accepted as a parameter and forge.ps1 read
    # settings.build_model out of every queue, but the CLI invocation never
    # referenced it -- so build_model was silently inert config in every queue
    # ever run.
    #
    # FG-7a (2026-09-16, same day): wiring it through unconditionally was worse
    # than leaving it inert. Every Benavora queue carries
    # build_model: claude-sonnet-4-6-20250514, which this CLI rejects outright
    # ("There's an issue with the selected model"), so the Build Agent died at
    # invocation on prompt 1 and burned both retries without touching the repo.
    # A stale model string in a queue must degrade to the CLI default, not kill
    # the run. Now: try the configured model, and on a model-rejection fall back
    # to the CLI default once, loudly, and carry on.
    if ($model) {
        $result = $fullPrompt | claude -p --model $model --dangerously-skip-permissions --output-format text --verbose 2>&1
        $modelExit = $LASTEXITCODE
        $resultText = ($result | Out-String)
        if ($modelExit -ne 0 -and $resultText -match "issue with the selected model|may not exist or you may not have access") {
            Log "build_model '$model' was REJECTED by the claude CLI. Falling back to the CLI default model for this run. Fix or remove settings.build_model in the queue - it is not a valid model for this account." "WARN"
            $result = $fullPrompt | claude -p --dangerously-skip-permissions --output-format text --verbose 2>&1
        }
    }
    else {
        $result = $fullPrompt | claude -p --dangerously-skip-permissions --output-format text --verbose 2>&1
    }
    # $LASTEXITCODE reflects claude's own exit code here (last native command in
    # the pipeline) - capture it immediately, before any other command can
    # overwrite it. A non-zero exit means the CLI call itself failed (auth
    # expired, usage/rate limit hit, network error, crash) before ever touching
    # the codebase - that is a categorically different failure than "the agent
    # ran but did a bad job", and callers need to be able to tell them apart
    # instead of finding out three prompts later via a gate's raw stack trace.
    $exitCode = $LASTEXITCODE

    return @{ text = ($result | Out-String); exitCode = $exitCode }
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
    $result = $recoveryPrompt | claude -p --dangerously-skip-permissions --output-format text 2>&1

    return ($result | Out-String)
}

# ------------------------------------------------------------
# Main Pipeline
# ------------------------------------------------------------
function Start-ForgePipeline {
    $pipelineStartTime = Get-Date
    $slackWebhookUrl = $env:FORGE_SLACK_WEBHOOK

    Write-ProjectBanner -projectName $project
    Log "========================================" "INFO"
    Log "  FORGE Pipeline Starting" "INFO"
    Log "  Project: $project" "INFO"
    Log "  Time: $TIMESTAMP" "INFO"
    Log "========================================" "INFO"
    Log "[INFO] Prompt caching not applicable - Build Agent calls go through the claude CLI, not a raw Messages API JSON payload, so cache_control cannot be set from forge.ps1" "INFO"

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

    # ------------------------------------------------------------
    # Live Dashboard
    # ------------------------------------------------------------
    $dashboardScript = Join-Path $FORGE_ROOT "forge-dashboard.ps1"
    $dashboardJob = Start-Job -FilePath $dashboardScript -ArgumentList @($project, $LOG_FILE, $totalPrompts)
    Log "[INFO] Dashboard running at http://localhost:7734 - open in browser" "INFO"

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
        failedIds = @()
    }

    Send-ForgeStart -webhookUrl $slackWebhookUrl -project $project -totalPrompts $totalPrompts

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
        $promptStartTime = Get-Date

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
                -model $(if ($settings.build_model) { $settings.build_model } else { "claude-sonnet-5" }) `
                -promptIndex $i

            # Always log what the Build Agent actually said, truncated to keep the
            # log file sane. Previously this was captured into $buildResult and
            # then discarded - a CLI-level failure (auth, usage/rate limit,
            # network) produced zero record of itself, so the only visible
            # symptom was a downstream gate failing on a file that was never
            # written, hours later, with nothing to explain why.
            $buildOutputPreview = if ($buildResult.text.Length -gt 4000) { $buildResult.text.Substring(0, 4000) + "...[truncated, $($buildResult.text.Length) chars total]" } else { $buildResult.text }
            Log "Build Agent finished (exit=$($buildResult.exitCode), $($buildResult.text.Length) chars):" "INFO"
            Log $buildOutputPreview "INFO"

            # Run Quality Gates
            $allGatesPassed = $true
            $failedGateOutput = ""
            $dryRunSkippedAGate = $false

            if (-not $dryRun -and $buildResult.exitCode -ne 0) {
                # The CLI call itself failed - no gate ran, none should. Running
                # gates here would just report "file not found" for whatever the
                # prompt asked the agent to create, masking the real error.
                $allGatesPassed = $false
                $failedGateOutput = "BUILD AGENT INVOCATION FAILED (claude exited $($buildResult.exitCode)) before any work could happen - likely auth expiry, a usage/rate limit, or a network error, not a defect in the prompt or codebase. Build Agent output:`n$($buildResult.text)"
                Log "Build Agent invocation failed (exit $($buildResult.exitCode)) - skipping gates for this attempt." "FAIL"
            }
            elseif ($prompt.gates) {
                foreach ($gate in $prompt.gates) {
                    $gateType = $gate.type

                    # FG-9 (2026-09-16): during a dry run, execute only
                    # read-only gates. build/test/lint/compile/deploy_verify and
                    # arbitrary shell commands all mutate (node_modules, .next,
                    # the database, or a live Vercel deploy) and must never fire
                    # from a dry run. Skipped gates are reported as SKIPPED and
                    # the prompt is NOT recorded as a real pass.
                    if ($dryRun -and $gateType -ne "file_exists") {
                        # Still VALIDATE the gate type even though we will not
                        # execute it - otherwise a dry run would report green
                        # for a queue containing a gate type FORGE cannot run,
                        # which is the exact false-pass this fix exists to kill.
                        $validGateTypes = @("compile", "build", "lint", "test", "deploy_verify", "file_exists", "shell", "command")
                        if ($gateType -notin $validGateTypes) {
                            $allGatesPassed = $false
                            $failedGateOutput = "UNKNOWN GATE TYPE '$gateType' found during dry-run validation. Valid types: $($validGateTypes -join ', ')."
                            Log "DRY RUN - invalid gate type '$gateType' - FAILING validation." "FAIL"
                            break
                        }
                        Log "DRY RUN - gate '$gateType' validated but NOT executed. This run proves nothing about the code." "INFO"
                        $dryRunSkippedAGate = $true
                        continue
                    }
                    $gateConfig = @{}
                    if ($gate.files) { $gateConfig.files = $gate.files }
                    if ($gate.command) { $gateConfig.command = $gate.command }
                    if ($gate.run) { $gateConfig.command = $gate.run }

                    $gateResult = Run-Gate -gateType $gateType -workDir $workDir -gateConfig $gateConfig

                    if (-not $gateResult.pass) {
                        $allGatesPassed = $false
                        $failedGateOutput = $gateResult.output
                        break
                    }
                }
            }
            else {
                # FG-3 (2026-09-16): a prompt with no `gates:` key previously
                # left $allGatesPassed = $true and PASSED unconditionally, so a
                # forgotten gates block read as green. An ungated prompt proves
                # nothing and must never pass.
                $allGatesPassed = $false
                $failedGateOutput = "NO GATES DEFINED for prompt '$promptId'. A prompt without a gates: block proves nothing, so FORGE fails it rather than reporting a pass it cannot substantiate. Add at least one gate (compile/build/lint/test/file_exists/shell)."
                Log "Prompt $promptId has no gates defined - failing rather than false-passing." "FAIL"
            }

            if ($allGatesPassed -and $dryRunSkippedAGate) {
                Log "PROMPT $promptId : DRY-RUN VALIDATED ONLY - gates were not executed, this is NOT a pass." "WARN"
            }

            if ($allGatesPassed) {
                $promptPassed = $true
                $results.passed++
                Write-Transition -state "PASSED"
                Log "PROMPT $promptId : ALL GATES PASSED" "PASS"
                $promptDuration = "{0:N1}s" -f ((Get-Date) - $promptStartTime).TotalSeconds
                Send-ForgePromptPass -webhookUrl $slackWebhookUrl -project $project -promptId $promptId -promptName $description -duration $promptDuration
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
            $results.failedIds += $promptId
            Write-Transition -state "FAILED" -reason "exhausted $maxRetries retries"
            Log "PROMPT $promptId : FAILED after $maxRetries retries" "ERROR"
            Send-ForgePromptFail -webhookUrl $slackWebhookUrl -project $project -promptId $promptId -promptName $description -retries $retryCount

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

    $pipelineDuration = "{0:N1}m" -f ((Get-Date) - $pipelineStartTime).TotalMinutes
    Send-ForgeComplete -webhookUrl $slackWebhookUrl -project $project -passed $results.passed -failed $results.failed -duration $pipelineDuration -failedPromptIds $results.failedIds

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

    Stop-Job $dashboardJob -ErrorAction SilentlyContinue
    Remove-Job $dashboardJob -ErrorAction SilentlyContinue
    try { Invoke-WebRequest http://localhost:7734/stop -TimeoutSec 2 -ErrorAction SilentlyContinue } catch {}

    return $results
}

# ------------------------------------------------------------
# Execute
# ------------------------------------------------------------
# Guarded so this file can be dot-sourced (e.g. `. .\forge.ps1`) by tests to
# reuse functions like Run-Gate without kicking off a full pipeline run.
# Normal invocation (`powershell -File forge.ps1` or `.\forge.ps1`) is unaffected.
if ($MyInvocation.InvocationName -ne '.') {
    $result = Start-ForgePipeline
    if ($result.halted -or $result.failed -gt 0) { exit 1 } else { exit 0 }
}



