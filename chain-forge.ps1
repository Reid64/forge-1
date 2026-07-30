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
    $queueFile = Join-Path $projectPath $queue

    if (-not (Test-Path $queueFile)) {
        # Try FORGE projects folder (where staged queue files actually live)
        $queueFile = Join-Path $forgeProjectPath $queue
    }

    if (-not (Test-Path $queueFile)) {
        # Try Downloads folder
        $queueFile = Join-Path "$env:USERPROFILE\Downloads" $queue
    }

    if (-not (Test-Path $queueFile)) {
        Log-Chain "[ERROR] Queue file not found: $queue (checked project dir, FORGE projects dir, and Downloads)"
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
    
    # Push after each queue
    Set-Location $projectPath
    git add -A 2>$null
    git commit -m "FORGE chain complete: $queue" 2>$null
    git push 2>$null
    Log-Chain "Git push complete for $queue"
    
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
