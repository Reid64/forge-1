# ============================================================
# gates/lint.ps1 — Gate 3: Lint
# ============================================================
# Runs `pnpm lint` in the target project directory.
# Exit code 0 = PASS, non-zero = FAIL.
#
# Standalone usage:   .\gates\lint.ps1 -workDir C:\path\to\app
# Called by forge.ps1 as part of the gate sequence.
# ============================================================

param(
    [Parameter(Mandatory = $false)]
    [string]$workDir = (Get-Location).Path
)

if (-not (Test-Path $workDir)) {
    Write-Host "[GATE:lint] FAIL — work directory does not exist: $workDir" -ForegroundColor Red
    exit 1
}

Push-Location $workDir
try {
    Write-Host "[GATE:lint] pnpm lint  (in $workDir)" -ForegroundColor Cyan
    $output = & pnpm lint 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($output.Trim()) { Write-Host $output }

    if ($code -eq 0) {
        Write-Host "[GATE:lint] PASS — no lint errors" -ForegroundColor Green
        exit 0
    }
    else {
        Write-Host "[GATE:lint] FAIL — lint exited with code $code" -ForegroundColor Red
        exit 1
    }
}
finally {
    Pop-Location
}
