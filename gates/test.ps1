# ============================================================
# gates/test.ps1 — Gate 4: Playwright End-to-End Tests
# ============================================================
# Runs `npx playwright test --reporter=list` in the target
# project directory. Exit code 0 = PASS (all tests green),
# non-zero = FAIL.
#
# If no test files exist yet, this gate is a no-op PASS so the
# pipeline can proceed during early scaffold phases.
#
# Standalone usage:   .\gates\test.ps1 -workDir C:\path\to\app
# Called by forge.ps1 as part of the gate sequence.
# ============================================================

param(
    [Parameter(Mandatory = $false)]
    [string]$workDir = (Get-Location).Path
)

if (-not (Test-Path $workDir)) {
    Write-Host "[GATE:test] FAIL — work directory does not exist: $workDir" -ForegroundColor Red
    exit 1
}

Push-Location $workDir
try {
    # Skip gracefully if there are no Playwright specs yet.
    $hasTests = $false
    foreach ($dir in @("tests", "e2e", "test")) {
        if (Test-Path (Join-Path $workDir $dir)) {
            $specs = Get-ChildItem -Path (Join-Path $workDir $dir) -Recurse -Include "*.spec.ts", "*.spec.js", "*.test.ts" -ErrorAction SilentlyContinue
            if ($specs) { $hasTests = $true; break }
        }
    }

    if (-not $hasTests) {
        Write-Host "[GATE:test] SKIP — no Playwright spec files found (treated as PASS)" -ForegroundColor Yellow
        exit 0
    }

    Write-Host "[GATE:test] npx playwright test --reporter=list  (in $workDir)" -ForegroundColor Cyan
    $output = & npx playwright test --reporter=list 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($output.Trim()) { Write-Host $output }

    if ($code -eq 0) {
        Write-Host "[GATE:test] PASS — all Playwright tests passed" -ForegroundColor Green
        exit 0
    }
    else {
        Write-Host "[GATE:test] FAIL — playwright exited with code $code" -ForegroundColor Red
        exit 1
    }
}
finally {
    Pop-Location
}
