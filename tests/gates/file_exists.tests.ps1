# ============================================================
# file_exists.tests.ps1
# ============================================================
# Regression test for the bracketed-dynamic-route false-negative bug:
# Test-Path (without -LiteralPath) treats `[id]` as a PowerShell wildcard
# character class ("match a single i or d"), not a literal folder name, so
# an existing file like src/app/api/clients/[id]/health/route.ts is
# reported as MISSING.
#
# Two code paths implement the file_exists gate and both must be covered:
#   1. gates/file_exists.ps1   - standalone script (single source of truth
#                                  for compile/build/lint/test/deploy_verify,
#                                  but file_exists historically duplicated
#                                  its own inline logic instead of delegating)
#   2. forge.ps1 Run-Gate      - the orchestrator's inline "file_exists" case,
#                                  which is what actually runs during a queue
#                                  and is where the Jul-29 fix never landed.
#
# Run with: Invoke-Pester -Path tests\gates\file_exists.tests.ps1
# ============================================================

$FORGE_ROOT = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$gateScript = Join-Path $FORGE_ROOT "gates\file_exists.ps1"
$forgeScript = Join-Path $FORGE_ROOT "forge.ps1"

$bracketedRelPath = "src\app\api\clients\[id]\health\route.ts"
$bracketedRelPathMissing = "src\app\api\clients\[id]\health\missing-route.ts"
$tempWorkDir = Join-Path $env:TEMP ("forge-file-exists-test-" + [guid]::NewGuid().ToString("N"))
$testProjectName = "pester-file-exists-test-tmp"

try {
    # ---- Fixture: a real file at a bracketed dynamic-route path ----
    $bracketedFullPath = Join-Path $tempWorkDir $bracketedRelPath
    New-Item -ItemType Directory -Path (Split-Path -Parent $bracketedFullPath) -Force | Out-Null
    Set-Content -LiteralPath $bracketedFullPath -Value "// fixture" -Encoding UTF8

    # ---- Load forge.ps1's functions (incl. Run-Gate) without running the pipeline ----
    # forge.ps1 guards its bottom "Execute" block on InvocationName -ne '.', so
    # dot-sourcing it only defines functions/config - it does not start a build.
    . $forgeScript -project $testProjectName

    Describe "file_exists gate - bracketed dynamic-route paths" {

        Context "gates/file_exists.ps1 (standalone script)" {

            It "PASSes for a file that exists under a [id]-bracketed folder" {
                $env:FORGE_WORK_DIR = $tempWorkDir
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gateScript -files $bracketedRelPath 2>&1 | Out-Null
                $LASTEXITCODE | Should Be 0
            }

            It "FAILs for a genuinely missing file under a [id]-bracketed folder" {
                $env:FORGE_WORK_DIR = $tempWorkDir
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gateScript -files $bracketedRelPathMissing 2>&1 | Out-Null
                $LASTEXITCODE | Should Not Be 0
            }
        }

        Context "forge.ps1 Run-Gate 'file_exists' case (live orchestrator path)" {

            It "PASSes for a file that exists under a [id]-bracketed folder" {
                $result = Run-Gate -gateType "file_exists" -workDir $tempWorkDir -gateConfig @{ files = @($bracketedRelPath -replace '\\','/') }
                $result.pass | Should Be $true
            }

            It "FAILs for a genuinely missing file under a [id]-bracketed folder" {
                $result = Run-Gate -gateType "file_exists" -workDir $tempWorkDir -gateConfig @{ files = @($bracketedRelPathMissing -replace '\\','/') }
                $result.pass | Should Be $false
            }
        }
    }
}
finally {
    Remove-Item -Path $tempWorkDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $FORGE_ROOT "state\$testProjectName") -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $FORGE_ROOT "logs\$testProjectName") -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\FORGE_WORK_DIR -ErrorAction SilentlyContinue
}
