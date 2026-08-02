# ============================================================
# forge-orchestrator.ps1
# BENAVORA — Autonomous FORGE Build Orchestrator
#
# Reads library-manifest.yaml, resolves dependency order,
# runs queues sequentially via chain-forge.ps1, updates
# manifest status after each queue completes, loops until
# all queues are complete or no runnable queues remain.
#
# Usage:
#   cd C:\Users\manag\Documents\FORGE
#   powershell -ExecutionPolicy Bypass -File .\forge-orchestrator.ps1 -project benavora
#
# Optional flags:
#   -dryRun       Print execution plan without running anything
#   -skipTo id    Skip queues until this queue id, then run from there
#   -only id      Run only this single queue id (ignores dependencies)
#   -maxRounds 5  Maximum number of dependency-resolution rounds (default 20)
# ============================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$project,

    [switch]$dryRun,

    [string]$skipTo = "",

    [string]$only = "",

    [int]$maxRounds = 20
)

# ── Paths ─────────────────────────────────────────────────────────────────────
$forgePath      = "C:\Users\manag\Documents\FORGE"
$projectPath    = "C:\Users\manag\Documents\$project"
$libraryPath    = "$forgePath\library\$project"
$manifestPath   = "$forgePath\library\$project\library-manifest.yaml"
$chainScript    = "$forgePath\chain-forge.ps1"
$timestamp      = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$orchestratorLog = "$forgePath\reports\orchestrator_${project}_${timestamp}.log"

# ── Ensure directories exist ──────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path "$forgePath\library\$project" | Out-Null
New-Item -ItemType Directory -Force -Path "$forgePath\reports" | Out-Null

# ── Logging ───────────────────────────────────────────────────────────────────
function Log {
    param([string]$level, [string]$msg)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$level] $msg"
    Write-Host $line
    Add-Content -Path $orchestratorLog -Value $line
}

function Log-Info  { param([string]$msg) Log "INFO " $msg }
function Log-Pass  { param([string]$msg) Log "PASS " $msg }
function Log-Fail  { param([string]$msg) Log "FAIL " $msg }
function Log-Warn  { param([string]$msg) Log "WARN " $msg }
function Log-Plan  { param([string]$msg) Log "PLAN " $msg }

# ── Preflight (folded in from the retired launch-forge.ps1) ──────────────────
$env:NODE_OPTIONS = "--max-old-space-size=8192"
$buildDir = Join-Path $projectPath ".next"
if (Test-Path $buildDir) {
    Remove-Item -Recurse -Force $buildDir -ErrorAction SilentlyContinue
    Log-Info "Cleared stale build cache: $buildDir"
}
$env:ANTHROPIC_API_KEY = $null
Log-Info "Verifying Claude Code subscription login..."
$authTest = "test" | claude -p --output-format text 2>&1
if ($LASTEXITCODE -ne 0) {
    Log-Fail "Claude Code not authenticated. Run: claude then /login"
    exit 1
}
Log-Pass "Claude Code OK -- running on Max subscription"

# ── Validate prerequisites ────────────────────────────────────────────────────
if (-not (Test-Path $manifestPath)) {
    Log-Fail "Manifest not found at $manifestPath"
    Log-Fail "Create library-manifest.yaml in $libraryPath before running the orchestrator."
    exit 1
}

# chain-forge.ps1 check removed -- orchestrator calls forge.ps1 directly

# ── Parse manifest (simple YAML reader — no external module needed) ───────────
function Parse-Manifest {
    param([string]$path)

    $lines   = Get-Content $path
    $queues  = @()
    $seenIds = @{}
    $current = $null

    foreach ($line in $lines) {
        # New queue entry
        if ($line -match '^\s{2}- id:\s+(.+)$') {
            if ($current -and -not $seenIds.ContainsKey($current.id)) {
                $queues += $current
                $seenIds[$current.id] = $true
            }
            $current = $null
            $current = @{
                id              = $matches[1].Trim()
                file            = ""
                description     = ""
                status          = "pending"
                depends_on      = @()
                prompt_count    = 0
                estimated_hours = 0
                priority        = 99
                note            = ""
            }
        }
        elseif ($current -and $line -match '^\s{4}file:\s+(.+)$')          { $current.file          = $matches[1].Trim() }
        elseif ($current -and $line -match '^\s{4}description:\s+"(.+)"$') { $current.description   = $matches[1].Trim() }
        elseif ($current -and $line -match '^\s{4}status:\s+(.+)$')        { $current.status        = $matches[1].Trim() }
        elseif ($current -and $line -match '^\s{4}prompt_count:\s+(\d+)$') { $current.prompt_count  = [int]$matches[1] }
        elseif ($current -and $line -match '^\s{4}estimated_hours:\s+(\d+)$') { $current.estimated_hours = [int]$matches[1] }
        elseif ($current -and $line -match '^\s{4}priority:\s+(\d+)$')     { $current.priority      = [int]$matches[1] }
        elseif ($current -and $line -match '^\s{4}note:\s+"(.+)"$')        { $current.note          = $matches[1].Trim() }
        elseif ($current -and $line -match '^\s{6}- (.+)$') {
            $dep = $matches[1].Trim()
            if ($dep -ne "[]") { $current.depends_on += $dep }
        }
    }
    if ($current -and -not $seenIds.ContainsKey($current.id)) {
        $queues += $current
        $seenIds[$current.id] = $true
    }
    return $queues
}

# ── Write updated manifest ────────────────────────────────────────────────────
function Update-ManifestStatus {
    param([string]$queueId, [string]$newStatus)

    $content = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8)
    # Replace the status line for this specific queue id block
    # Find "  - id: queueId" then replace the next "status:" line
    $pattern     = "(  - id:\s+$([regex]::Escape($queueId))[\s\S]*?)\s{4}status:\s+\w+"
    $replacement = '$1    status: ' + $newStatus
    $updated     = [regex]::Replace($content, $pattern, $replacement, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    [IO.File]::WriteAllText($manifestPath, $updated)
    Log-Info "Manifest updated: $queueId -> $newStatus"
}

# ── Check if all dependencies are satisfied ───────────────────────────────────
function Dependencies-Met {
    param($queue, $allQueues)
    if ($queue.depends_on.Count -eq 0) { return $true }
    foreach ($dep in $queue.depends_on) {
        $depQueue = $allQueues | Where-Object { $_.id -eq $dep }
        if (-not $depQueue) {
            Log-Warn "Dependency '$dep' for '$($queue.id)' not found in manifest — treating as unmet"
            return $false
        }
        if ($depQueue.status -ne "complete") { return $false }
    }
    return $true
}

# ── Check if all dependencies are satisfied, for the plan-preview phase only ──
# Never mutates $allQueues; a dependency counts as met if the real queue is
# already complete OR the planning simulation has marked it complete in
# $planStatus (PSObject.Copy() does not deep-copy hashtables in PS5, so the
# plan preview tracks simulated status separately instead of cloning queues).
function Dependencies-Met-ForPlanning {
    param($queue, $allQueues, $planStatus)
    if ($queue.depends_on.Count -eq 0) { return $true }
    foreach ($dep in $queue.depends_on) {
        $depQueue = $allQueues | Where-Object { $_.id -eq $dep }
        if (-not $depQueue) {
            Log-Warn "Dependency '$dep' for '$($queue.id)' not found in manifest — treating as unmet"
            return $false
        }
        $depComplete = ($depQueue.status -eq "complete") -or ($planStatus[$dep] -eq "complete")
        if (-not $depComplete) { return $false }
    }
    return $true
}

# ── Find next runnable queue ──────────────────────────────────────────────────
function Get-RunnableQueues {
    param($allQueues)
    return $allQueues | Where-Object {
        $_.status -eq "pending" -and (Dependencies-Met $_ $allQueues)
    } | Sort-Object priority
}

# ── Run a single queue via chain-forge.ps1 ───────────────────────────────────
function Run-Queue {
    param($queue)

    $queueFile = "$libraryPath\$($queue.file)"

    if (-not (Test-Path $queueFile)) {
        Log-Warn "Queue file not found: $queueFile — marking as failed"
        return $false
    }

    # Copy queue file to FORGE projects folder (where forge.ps1 expects it)
    $forgeProjectQueue = "$forgePath\projects\$project\queue.yaml"
    Copy-Item $queueFile $forgeProjectQueue -Force
    Log-Info "Deployed queue: $($queue.file) -> $forgeProjectQueue"

    $env:NODE_OPTIONS            = "--max-old-space-size=8192"
    $env:ANTHROPIC_API_KEY       = $null
    $env:DANGEROUSLY_SKIP_PERMISSIONS = 1

    Log-Info "Launching FORGE for queue: $($queue.id) ($($queue.prompt_count) prompts, ~$($queue.estimated_hours)h)"
    Log-Info "Description: $($queue.description)"

    $startTime = Get-Date

    $tmpOut = "$forgePath\reports\_forge_out_$($queue.id).tmp"
    $tmpErr = "$forgePath\reports\_forge_err_$($queue.id).tmp"
    if (Test-Path $tmpOut) { Remove-Item $tmpOut -Force }
    if (Test-Path $tmpErr) { Remove-Item $tmpErr -Force }

    $proc = Start-Process -FilePath "powershell" `
        -ArgumentList "-ExecutionPolicy Bypass -File `"$forgePath\forge.ps1`" -project $project -startFrom 0" `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $tmpOut `
        -RedirectStandardError $tmpErr

    $lastLine = 0
    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 800
        if (Test-Path $tmpOut) {
            $fs = [System.IO.File]::Open($tmpOut, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $reader = New-Object System.IO.StreamReader($fs)
            $content = $reader.ReadToEnd()
            $reader.Close()
            $fs.Close()
            $all = $content -split "`n" | Where-Object { $_ -ne '' }
            if ($all.Count -gt $lastLine) {
                for ($i = $lastLine; $i -lt $all.Count; $i++) {
                    Write-Host $all[$i]
                    Add-Content -Path $orchestratorLog -Value $all[$i]
                }
                $lastLine = $all.Count
            }
        }
    }
    if (Test-Path $tmpOut) {
        $fs = [System.IO.File]::Open($tmpOut, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($fs)
        $content = $reader.ReadToEnd()
        $reader.Close()
        $fs.Close()
        $all = $content -split "`n" | Where-Object { $_ -ne '' }
        if ($all.Count -gt $lastLine) {
            for ($i = $lastLine; $i -lt $all.Count; $i++) {
                Write-Host $all[$i]
                Add-Content -Path $orchestratorLog -Value $all[$i]
            }
        }
        Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue
        Remove-Item $tmpErr -Force -ErrorAction SilentlyContinue
    }
    $exitCode = $proc.ExitCode
    if ($null -eq $exitCode) { $exitCode = 0 }
    $haltReasonFile = "$forgePath\state\$project\halt-reason.md"
    if (Test-Path $haltReasonFile) {
        $haltFileAge = (Get-Date) - (Get-Item $haltReasonFile).LastWriteTime
        if ($haltFileAge.TotalMinutes -lt 60) {
            Log-Warn "Detected fresh halt-reason.md (written $([math]::Round($haltFileAge.TotalSeconds))s ago) -- overriding unreliable Start-Process exit code"
            $exitCode = 1
            Remove-Item $haltReasonFile -Force -ErrorAction SilentlyContinue
        }
    }

    $elapsed   = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)

    if ($exitCode -eq 0) {
        Log-Pass "Queue $($queue.id) completed in $elapsed minutes"
        return $true
    }
    else {
        Log-Fail "Queue $($queue.id) failed after $elapsed minutes (exit code: $exitCode)"
        return $false
    }
}

# ── Mandatory deploy verification (runs after EVERY queue, success or partial) ─
# Not a per-prompt gate: this fires once per queue, right after Run-Queue
# returns, regardless of whether the queue itself passed or failed. A queue is
# never marked "complete" in the manifest until this passes — production
# drifting from HEAD is exactly the failure mode this closes (see
# scripts/verify-deployment.ts in the target project for why the check reads
# deployment metadata from the Vercel API rather than trusting `vercel
# inspect`/`vercel ls` output).
function Invoke-DeployVerification {
    param([string]$queueId)

    Log-Info ""
    Log-Info "── DEPLOY VERIFICATION (mandatory, queue: $queueId) ──────────────────"

    $deployGate = "$forgePath\gates\deploy_verify.ps1"
    if (-not (Test-Path $deployGate)) {
        Log-Fail "DEPLOYMENT VERIFICATION FAILED: gate script not found at $deployGate"
        return $false
    }

    $outFile = "$forgePath\reports\_deploy_verify_out_$queueId.tmp"
    $errFile = "$forgePath\reports\_deploy_verify_err_$queueId.tmp"
    if (Test-Path $outFile) { Remove-Item $outFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path $errFile) { Remove-Item $errFile -Force -ErrorAction SilentlyContinue }

    $proc = Start-Process -FilePath "powershell" `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$deployGate`" -workDir `"$projectPath`"" `
        -NoNewWindow -PassThru -Wait `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    foreach ($f in @($outFile, $errFile)) {
        if (Test-Path $f) {
            Get-Content $f | Where-Object { $_ -ne '' } | ForEach-Object {
                Write-Host $_
                Add-Content -Path $orchestratorLog -Value $_
            }
            Remove-Item $f -Force -ErrorAction SilentlyContinue
        }
    }

    $exitCode = $proc.ExitCode
    if ($null -eq $exitCode) { $exitCode = 1 }

    if ($exitCode -eq 0) {
        Log-Pass "DEPLOYMENT VERIFIED for queue $queueId — production matches HEAD"
        return $true
    }
    else {
        Log-Fail "DEPLOYMENT VERIFICATION FAILED for queue $queueId — production does not match HEAD (or the deploy itself failed). Queue will NOT be marked complete until this passes. Run scripts/verify-deployment.ts manually in $projectPath to diagnose."
        return $false
    }
}

# ── Main orchestration loop ───────────────────────────────────────────────────
Log-Info "=========================================="
Log-Info "  FORGE Orchestrator Starting"
Log-Info "  Project: $project"
Log-Info "  Manifest: $manifestPath"
Log-Info "  Dry run: $dryRun"
Log-Info "  Time: $timestamp"
Log-Info "=========================================="

$allQueues = Parse-Manifest $manifestPath
$totalQueues = $allQueues.Count
Log-Info "Loaded $totalQueues queues from manifest"

# Handle -only flag
if ($only -ne "") {
    $targetQueue = $allQueues | Where-Object { $_.id -eq $only }
    if (-not $targetQueue) {
        Log-Fail "Queue '$only' not found in manifest"
        exit 1
    }
    Log-Info "Running single queue: $only"
    if ($dryRun) {
        Log-Plan "DRY RUN: Would run $($targetQueue.file)"
        exit 0
    }
    Update-ManifestStatus $targetQueue.id "running"
    $success = Run-Queue $targetQueue
    $deployVerified = Invoke-DeployVerification $targetQueue.id
    Update-ManifestStatus $targetQueue.id $(if ($success -and $deployVerified) { "complete" } else { "failed" })
    exit $(if ($success -and $deployVerified) { 0 } else { 1 })
}

# Print execution plan
$runnable = Get-RunnableQueues $allQueues
Log-Info ""
Log-Info "── EXECUTION PLAN ──────────────────────────────────"
$planOrder = 1
$round = 0
$planStatus = @{}   # simulated "complete" status per queue id; $allQueues itself is never mutated

while ($true) {
    $nextBatch = $allQueues | Where-Object {
        $_.status -eq "pending" -and
        ($planStatus[$_.id] -ne "complete") -and
        (Dependencies-Met-ForPlanning $_ $allQueues $planStatus)
    } | Sort-Object priority

    if ($nextBatch.Count -eq 0) { break }
    $round++
    Log-Plan "Round $round ($($nextBatch.Count) queues):"
    foreach ($q in $nextBatch) {
        Log-Plan "  [$planOrder] $($q.id) — $($q.prompt_count) prompts, ~$($q.estimated_hours)h — $($q.description)"
        $planOrder++
        $planStatus[$q.id] = "complete"
    }
    if ($round -ge $maxRounds) { break }
}

$skippedPlanned = ($allQueues | Where-Object { $_.status -eq "planned" }).Count
$alreadyComplete = ($allQueues | Where-Object { $_.status -eq "complete" }).Count
$totalRunnable = $planOrder - 1

Log-Info ""
Log-Info "Total queues to run: $totalRunnable"
Log-Info "Already complete:    $alreadyComplete"
Log-Info "Planned (deferred):  $skippedPlanned"
$totalPrompts = ($allQueues | Where-Object { $_.status -eq "pending" } | ForEach-Object { [int]$_.prompt_count } | Measure-Object -Sum).Sum
$totalHours   = ($allQueues | Where-Object { $_.status -eq "pending" } | ForEach-Object { [double]$_.estimated_hours } | Measure-Object -Sum).Sum
Log-Info "Total prompts:       $totalPrompts"
Log-Info "Estimated runtime:   ~$totalHours hours"
Log-Info "────────────────────────────────────────────────────"
Log-Info ""

if ($dryRun) {
    Log-Info "DRY RUN complete — no queues executed"
    exit 0
}

# ── Execution loop ────────────────────────────────────────────────────────────
$round          = 0
$queuesRun      = 0
$queuesPassed   = 0
$queuesFailed   = 0
$skippingUntil  = $skipTo -ne ""

while ($true) {
    $round++

    if ($round -gt $maxRounds) {
        Log-Warn "Max rounds ($maxRounds) reached — stopping orchestrator"
        break
    }

    # Reload manifest each round to pick up status updates
    $allQueues = Parse-Manifest $manifestPath
    $runnable  = Get-RunnableQueues $allQueues

    if ($runnable.Count -eq 0) {
        $pending = ($allQueues | Where-Object { $_.status -eq "pending" }).Count
        if ($pending -gt 0) {
            Log-Warn "$pending queues still pending but no runnable queues found — likely blocked by failed dependencies"
            foreach ($q in ($allQueues | Where-Object { $_.status -eq "pending" })) {
                $blockedBy = $q.depends_on | Where-Object {
                    $dep = $_
                    $depQ = $allQueues | Where-Object { $_.id -eq $dep }
                    $depQ -and $depQ.status -ne "complete"
                }
                if ($blockedBy.Count -gt 0) {
                    Log-Warn "  $($q.id) blocked by: $($blockedBy -join ', ')"
                }
            }
        }
        else {
            Log-Pass "All queues complete or planned-deferred. Orchestrator finished."
        }
        break
    }

    Log-Info ""
    Log-Info "── ROUND $round — $($runnable.Count) runnable queue(s) ──────────────────────────"

    foreach ($queue in $runnable) {

        # Handle -skipTo flag
        if ($skippingUntil) {
            if ($queue.id -eq $skipTo) {
                $skippingUntil = $false
                Log-Info "Reached skipTo target: $($queue.id) — resuming execution"
            }
            else {
                Log-Info "Skipping (skipTo): $($queue.id)"
                continue
            }
        }

        # Skip planned (future phase) queues
        if ($queue.status -eq "planned") {
            Log-Info "Skipping planned (future phase): $($queue.id) — $($queue.note)"
            continue
        }

        $queuesRun++
        Log-Info ""
        Log-Info "Starting queue ${queuesRun}: $($queue.id)"
        Log-Info "File: $($queue.file)"
        Log-Info "Prompts: $($queue.prompt_count) | Est: ~$($queue.estimated_hours)h"

        Update-ManifestStatus $queue.id "running"

        $success = Run-Queue $queue

        # Mandatory, runs regardless of $success -- a halted/partial queue can
        # still have pushed commits that drifted production, so this always
        # fires (see Invoke-DeployVerification above).
        $deployVerified = Invoke-DeployVerification $queue.id

        if ($success -and $deployVerified) {
            $queuesPassed++
            Update-ManifestStatus $queue.id "complete"
            Log-Pass "[$queuesRun] $($queue.id) — COMPLETE"

            # Commit manifest update
            Push-Location $projectPath
            git add "$manifestPath" 2>$null
            git commit -m "chore: orchestrator -- $($queue.id) marked complete" 2>$null
            Pop-Location
        }
        else {
            $queuesFailed++
            Update-ManifestStatus $queue.id "failed"
            if ($success -and -not $deployVerified) {
                Log-Fail "[$queuesRun] $($queue.id) — queue prompts passed but DEPLOYMENT VERIFICATION FAILED; not marked complete (continuing to next runnable queue)"
            }
            else {
                Log-Fail "[$queuesRun] $($queue.id) — FAILED (continuing to next runnable queue)"
            }
        }

        # Brief pause between queues
        Start-Sleep -Seconds 10
    }
}

# ── Final summary ─────────────────────────────────────────────────────────────
Log-Info ""
Log-Info "=========================================="
Log-Info "  FORGE Orchestrator Complete"
Log-Info "  Queues run:    $queuesRun"
Log-Info "  Passed:        $queuesPassed"
Log-Info "  Failed:        $queuesFailed"
Log-Info "  Log:           $orchestratorLog"
Log-Info "=========================================="

exit $(if ($queuesFailed -eq 0) { 0 } else { 1 })





