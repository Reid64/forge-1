# ============================================================
# gates/deploy_verify.ps1 — Deploy Verification Gate
# ============================================================
# Runs `vercel --prod`, then confirms the resulting production deployment's
# recorded commit SHA matches the target project's git HEAD. Delegates the
# actual deploy+verify logic to scripts/verify-deployment.ts inside the
# target project repo (single source of truth, shared with the standalone
# manual tool and this gate — see that file for why the check reads
# deployment metadata from the Vercel API rather than trusting `vercel
# inspect`/`vercel ls` output).
#
# FAILS LOUDLY: scripts/verify-deployment.ts prints
# "DEPLOYMENT VERIFICATION FAILED: ..." and exits non-zero on any SHA
# mismatch, failed deploy, non-READY state, or missing VERCEL_TOKEN. This
# gate mirrors that exit code so forge.ps1's Run-Gate treats it like any
# other gate: exit 0 = PASS, non-zero = FAIL.
#
# Standalone usage:   .\gates\deploy_verify.ps1 -workDir C:\path\to\app
# Called by:
#   - forge.ps1's Run-Gate, when a prompt's gates list includes
#     "type: deploy_verify" (intended as the LAST gate on a queue's final
#     prompt, so it fires once per queue, not once per prompt)
#   - forge-orchestrator.ps1, as a mandatory step after every queue
#     completes (success or partial) — see Invoke-DeployVerification
# ============================================================

param(
    [Parameter(Mandatory = $false)]
    [string]$workDir = (Get-Location).Path
)

if (-not (Test-Path $workDir)) {
    Write-Host "DEPLOYMENT VERIFICATION FAILED: work directory does not exist: $workDir" -ForegroundColor Red
    exit 1
}

$scriptPath = Join-Path $workDir "scripts\verify-deployment.ts"
if (-not (Test-Path $scriptPath)) {
    Write-Host "DEPLOYMENT VERIFICATION FAILED: scripts\verify-deployment.ts not found in $workDir" -ForegroundColor Red
    exit 1
}

Push-Location $workDir
try {
    Write-Host "[GATE:deploy_verify] pnpm tsx scripts/verify-deployment.ts  (in $workDir)" -ForegroundColor Cyan
    $output = & pnpm tsx scripts/verify-deployment.ts 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($output.Trim()) { Write-Host $output }

    if ($code -eq 0) {
        Write-Host "[GATE:deploy_verify] PASS — production verified to match HEAD" -ForegroundColor Green
        exit 0
    }
    else {
        Write-Host "[GATE:deploy_verify] FAIL — deployment verification exited with code $code" -ForegroundColor Red
        exit 1
    }
}
finally {
    Pop-Location
}
