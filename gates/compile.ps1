# ============================================================
# gates/compile.ps1 — Gate 1: TypeScript Compile + Real Build
# ============================================================
# `pnpm tsc --noEmit` alone is NOT sufficient: it excludes files matched
# by tsconfig "exclude" (e.g. src/__tests__/**) and does not run ESLint,
# so it misses build-fatal ESLint errors that Vercel's/Railway's actual
# `next build` (or `pnpm run build`) enforces. That gap let 28 consecutive
# deploys fail in production while this gate reported PASS.
#
# `pnpm tsc --noEmit` still runs first as a fast pre-check (cheap, quick
# feedback on type errors), but this gate does NOT report PASS unless the
# real build command — the same one Vercel/Railway actually run — also
# succeeds.
#
# Exit code 0 = PASS (tsc clean AND real build succeeds), non-zero = FAIL.
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
    # --- Step 1: fast tsc pre-check (does NOT cover src/__tests__/** or ESLint) ---
    Write-Host "[GATE:compile] pnpm tsc --noEmit  (in $workDir)" -ForegroundColor Cyan
    $tscOutput = & pnpm tsc --noEmit 2>&1 | Out-String
    $tscCode = $LASTEXITCODE
    if ($tscOutput.Trim()) { Write-Host $tscOutput }

    if ($tscCode -ne 0) {
        Write-Host "[GATE:compile] FAIL — tsc exited with code $tscCode" -ForegroundColor Red
        exit 1
    }
    Write-Host "[GATE:compile] tsc pre-check PASS — zero TypeScript errors (note: excludes test files, no ESLint)" -ForegroundColor Green

    # --- Step 2: real build command — matches what Vercel/Railway actually run ---
    Write-Host "[GATE:compile] pnpm run build  (in $workDir)" -ForegroundColor Cyan
    $buildOutput = & pnpm run build 2>&1 | Out-String
    $buildCode = $LASTEXITCODE
    if ($buildOutput.Trim()) { Write-Host $buildOutput }

    if ($buildCode -eq 0) {
        Write-Host "[GATE:compile] PASS — tsc clean and real build succeeded" -ForegroundColor Green
        exit 0
    }
    else {
        Write-Host "[GATE:compile] FAIL — pnpm run build exited with code $buildCode (this is what Vercel/Railway enforce)" -ForegroundColor Red
        exit 1
    }
}
finally {
    Pop-Location
}
