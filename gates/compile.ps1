# ============================================================
# gates/compile.ps1 — Gate 1: TypeScript Compile
# ============================================================
# Runs `pnpm tsc --noEmit` in the target project directory.
# Exit code 0 = PASS (zero type errors), non-zero = FAIL.
#
# Standalone usage:   .\gates\compile.ps1 -workDir C:\path\to\app
# Called by forge.ps1 as part of the gate sequence.
# ============================================================

param(
    [Parameter(Mandatory = $false)]
    [string]$workDir = (Get-Location).Path
)

if (-not (Test-Path $workDir)) {
    Write-Host "[GATE:compile] FAIL — work directory does not exist: $workDir" -ForegroundColor Red
    exit 1
}

Push-Location $workDir
try {
    Write-Host "[GATE:compile] pnpm tsc --noEmit  (in $workDir)" -ForegroundColor Cyan
    $output = & pnpm tsc --noEmit 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($output.Trim()) { Write-Host $output }

    if ($code -eq 0) {
        Write-Host "[GATE:compile] PASS — zero TypeScript errors" -ForegroundColor Green
        exit 0
    }
    else {
        Write-Host "[GATE:compile] FAIL — tsc exited with code $code" -ForegroundColor Red
        exit 1
    }
}
finally {
    Pop-Location
}
