# ============================================================
# gates/build.ps1 — Gate 2: Production Build
# ============================================================
# Runs `pnpm run build` in the target project directory.
# Exit code 0 = PASS, non-zero = FAIL.
# Build warnings are acceptable; build errors are not.
#
# Standalone usage:   .\gates\build.ps1 -workDir C:\path\to\app
# Called by forge.ps1 as part of the gate sequence.
# ============================================================

param(
    [Parameter(Mandatory = $false)]
    [string]$workDir = (Get-Location).Path
)

if (-not (Test-Path $workDir)) {
    Write-Host "[GATE:build] FAIL — work directory does not exist: $workDir" -ForegroundColor Red
    exit 1
}

Push-Location $workDir
try {
    Write-Host "[GATE:build] pnpm run build  (in $workDir)" -ForegroundColor Cyan
    $output = & pnpm run build 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($output.Trim()) { Write-Host $output }

    if ($code -eq 0) {
        Write-Host "[GATE:build] PASS — build completed" -ForegroundColor Green
        exit 0
    }
    else {
        Write-Host "[GATE:build] FAIL — build exited with code $code" -ForegroundColor Red
        exit 1
    }
}
finally {
    Pop-Location
}
