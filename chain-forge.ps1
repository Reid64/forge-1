# chain-forge.ps1
# Runs multiple FORGE queue files sequentially with automatic push between runs.
# Usage: powershell -ExecutionPolicy Bypass -File chain-forge.ps1 -project benavora -queues "queue-3f.yaml","queue-3f-gov.yaml","queue-3gh.yaml"

param(
    [Parameter(Mandatory=$true)]
    [string]$project,
    
    [Parameter(Mandatory=$true)]
    [string[]]$queues,
    
    [int]$startFrom = 0
)

$forgePath = "C:\Users\manag\Documents\FORGE"
$projectPath = "C:\Users\manag\Documents\$project"
$forgeProjectPath = "$forgePath\projects\$project"
# 2026-09-19: the library is where queue files and library-manifest.yaml
# actually live, and it was not in the search chain - every AR-13..AR-23
# queue resolved NOT_FOUND on the first launch attempt.
$libraryPath = "$forgePath\library\$project"
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$chainLog = "$forgePath\reports\chain_${project}_${timestamp}.log"

function Log-Chain {
    param([string]$msg)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
    Write-Host $line
    Add-Content -Path $chainLog -Value $line
}

Log-Chain "=========================================="
Log-Chain "  FORGE Chain Runner Starting"
Log-Chain "  Project: $project"
Log-Chain "  Queues: $($queues -join ', ')"
Log-Chain "  Time: $timestamp"
Log-Chain "=========================================="

$env:NODE_OPTIONS = "--max-old-space-size=8192"
$env:ANTHROPIC_API_KEY = $null
$env:DANGEROUSLY_SKIP_PERMISSIONS = 1

$totalPassed = 0
$totalFailed = 0
$totalSkipped = 0
$queueResults = @()

foreach ($queue in $queues) {
    # An absolute or already-valid path is used as given. Join-Path mangles an
    # absolute second argument ("C:\a" + "C:\b" -> "C:\a\C:\b"), so this must
    # come first or a caller passing a full path silently gets NOT_FOUND.
    $queueFile = $queue

    if (-not (Test-Path $queueFile)) {
        $queueFile = Join-Path $libraryPath $queue      # canonical: FORGE\library\<project>
    }

    if (-not (Test-Path $queueFile)) {
        $queueFile = Join-Path $projectPath $queue
    }

    if (-not (Test-Path $queueFile)) {
        # FORGE projects folder (staged queue files)
        $queueFile = Join-Path $forgeProjectPath $queue
    }

    if (-not (Test-Path $queueFile)) {
        # Downloads folder
        $queueFile = Join-Path "$env:USERPROFILE\Downloads" $queue
    }

    if (-not (Test-Path $queueFile)) {
        Log-Chain "[ERROR] Queue file not found: $queue"
        Log-Chain "        searched, in order:"
        Log-Chain "          as given:     $queue"
        Log-Chain "          library:      $libraryPath"
        Log-Chain "          project dir:  $projectPath"
        Log-Chain "          FORGE staged: $forgeProjectPath"
        Log-Chain "          Downloads:    $env:USERPROFILE\Downloads"
        $queueResults += @{ queue = $queue; status = "NOT_FOUND"; passed = 0; failed = 0 }
        continue
    }
    
    Log-Chain ""
    Log-Chain "------------------------------------"
    Log-Chain "  Starting queue: $queue"
    Log-Chain "------------------------------------"
    
    # Copy queue file into FORGE project
    Copy-Item $queueFile "$forgeProjectPath\queue.yaml" -Force
    Log-Chain "Copied $queue to FORGE project queue.yaml"
    
    # Determine startFrom (0 for all queues except first if specified)
    $sf = 0
    if ($queue -eq $queues[0]) { $sf = $startFrom }
    
    # Run FORGE
    Set-Location $forgePath
    $forgeStart = Get-Date
    
    powershell -ExecutionPolicy Bypass -File .\forge.ps1 -project $project -startFrom $sf
    $exitCode = $LASTEXITCODE
    
    $forgeEnd = Get-Date
    $duration = $forgeEnd - $forgeStart
    
    Log-Chain "Queue $queue completed in $($duration.ToString('hh\:mm\:ss'))"
    
    # Push after each queue -- ONLY when that queue actually succeeded.
    # 2026-09-16: these three lines previously ran unconditionally, so a queue
    # that failed every prompt still had its partial, gate-failing state
    # committed and pushed to the default branch. $exitCode was already being
    # captured two lines above and simply never consulted. A failed queue must
    # leave the remote untouched so the broken state is local and recoverable.
    Set-Location $projectPath
    if ($exitCode -eq 0) {
        git add -A 2>$null
        git commit -m "FORGE chain complete: $queue" 2>$null
        git push 2>$null
        Log-Chain "Git push complete for $queue (queue exited 0)"
    }
    else {
        Log-Chain "SKIPPING git commit/push for $queue - FORGE exited $exitCode. Partial or gate-failing work is NOT pushed. Inspect the working tree locally, then commit by hand if the changes are sound."
    }
    
    # Read the latest report to get pass/fail counts
    $latestReport = Get-ChildItem "$forgePath\reports\${project}_*.md" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latestReport) {
        $reportContent = Get-Content $latestReport.FullName -Raw
        Log-Chain "Report: $($latestReport.Name)"
    }
    
    $queueResults += @{ queue = $queue; status = "COMPLETED"; duration = $duration.ToString('hh\:mm\:ss') }
}

Log-Chain ""
Log-Chain "=========================================="
Log-Chain "  FORGE Chain Runner Complete"
Log-Chain "  Queues processed: $($queues.Count)"
Log-Chain "=========================================="

foreach ($result in $queueResults) {
    Log-Chain "  $($result.queue): $($result.status) ($($result.duration))"
}

Log-Chain "Chain log saved: $chainLog"
