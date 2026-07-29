param([string[]]$files)
$workDir = $env:FORGE_WORK_DIR
if (-not $workDir) { Write-Error "FORGE_WORK_DIR not set"; exit 1 }
$failed = @()
foreach ($f in $files) {
    $full = Join-Path $workDir $f
    if (-not (Test-Path -LiteralPath $full)) { $failed += $f }
}
if ($failed.Count -gt 0) {
    Write-Error "file_exists gate FAILED. Missing files:`n$($failed -join "`n")"
    exit 1
}
Write-Host "file_exists gate PASSED. All $($files.Count) file(s) present."
exit 0
