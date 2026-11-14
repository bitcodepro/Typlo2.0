param([Parameter(Mandatory)][string]$ArchivePath, [string]$Root = (Split-Path $PSScriptRoot))
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/release-common.ps1"
$version = Get-ReleaseVersion -Root $Root
$candidate = (Resolve-Path -LiteralPath $ArchivePath).Path
$candidateHash = (Get-FileHash $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
Add-Type -AssemblyName System.IO.Compression.FileSystem
$layout = [IO.Compression.ZipFile]::OpenRead($candidate)
try {
    $renamed = $null -ne $layout.GetEntry('Typlo.exe')
    $hasLegacy = $null -ne $layout.GetEntry('typlo-rust.exe')
    $archiveExes = @($layout.Entries | Where-Object { $_.FullName -notmatch '/' -and $_.FullName.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object FullName | Sort-Object -CaseSensitive)
} finally { $layout.Dispose() }
$expected = @(Get-WindowsPackageBinaries $Root | Sort-Object -CaseSensitive)
if (($archiveExes -join ',') -cne ($expected -join ',')) { throw 'Archive EXE names do not match the checked-out source contract' }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('TyploLegacyPackage-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $temporary)
$legacy = Join-Path $temporary 'v0.1.7.zip'
# Last published client before the EXE rename. Its immutable archive contract
# rejects Typlo.exe; this is an explicit manual handoff, not an automatic upgrade.
Invoke-WebRequest 'https://github.com/bitcodepro/Typlo/releases/download/v0.1.7/typlo-win-x64.zip' -OutFile $legacy -TimeoutSec 180
if ((Get-FileHash $legacy -Algorithm SHA256).Hash.ToLowerInvariant() -cne '22fa7baa2c43b052ca97ac1c1372fd69bed75b7cb20fb8d2419f356c14bf9845') { throw 'Published v0.1.7 ZIP SHA256 mismatch' }
$zip = [IO.Compression.ZipFile]::OpenRead($legacy)
$resident = Join-Path $temporary 'typlo-rust.exe'
try {
    $entry = $zip.GetEntry('typlo-rust.exe')
    if (!$entry) { throw 'Published resident missing' }
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $resident)
} finally { $zip.Dispose() }
$spec = [Diagnostics.ProcessStartInfo]::new($resident)
$spec.UseShellExecute = $false
$spec.CreateNoWindow = $true
$spec.RedirectStandardError = $true
$spec.WorkingDirectory = $temporary
foreach ($argument in @('--verify-update-package', $candidate, $version, $candidateHash)) { $spec.ArgumentList.Add($argument) }
$process = [Diagnostics.Process]::Start($spec)
try {
    $errorRead = $process.StandardError.ReadToEndAsync()
    if (!$process.WaitForExit(60000)) { $process.Kill($true); throw 'v0.1.7 package verification timed out' }
    $detail = $errorRead.GetAwaiter().GetResult()
    if ($renamed) {
        if ($process.ExitCode -eq 0 -or $detail -notlike '*Unsafe or oversized update entry*') { throw "Expected v0.1.7 to reject renamed archive, got $($process.ExitCode): $detail" }
    } elseif ($process.ExitCode -ne 0) { throw "Historical source format rejected by v0.1.7: $detail" }
} finally { $process.Dispose() }
# Simulate a manual extraction without launching a resident or using a real profile.
$manual = Join-Path $temporary 'manual install with spaces'
[IO.Compression.ZipFile]::ExtractToDirectory($candidate, $manual)
$required = @('typlo-settings.exe', 'resources/language-detection/words.sqlite3', 'README.md', 'LICENSE')
if ($hasLegacy) { $required += 'typlo-rust.exe' }
if ($renamed) { $required += 'Typlo.exe' }
foreach ($name in $required) {
    if (!(Test-Path -LiteralPath (Join-Path $manual $name) -PathType Leaf)) { throw "Manual installation missing: $name" }
}
if (!$renamed) {
    Write-Host 'PASS historical queued source keeps its old archive contract and v0.1.7 verification'
    return
}
if (!$hasLegacy) {
    $actual = @((Get-ChildItem $manual -File -Filter '*.exe').Name | Sort-Object -CaseSensitive)
    if (($actual -join ',') -cne ($expected -join ',')) { throw 'Unexpected current Windows EXE payload' }
    if (Get-ChildItem $manual -Recurse -File -Filter 'typlo-rust.exe') { throw 'Windows shim leaked into the new archive' }
    # Preserve the published three-EXE verifier, pinned independently of the
    # v0.1.7 check above. Removing its required shim is a manual handoff.
    $oldArchive = Join-Path $temporary 'v0.1.9.zip'
    Invoke-WebRequest 'https://github.com/bitcodepro/Typlo/releases/download/v0.1.9/typlo-win-x64.zip' -OutFile $oldArchive -TimeoutSec 180
    if ((Get-FileHash $oldArchive -Algorithm SHA256).Hash.ToLowerInvariant() -cne 'b0eebc342735241e6aeb3ef88ff5d84d58726c0681304dc6eaa9fd8eaa3e2d0a') { throw 'Published v0.1.9 ZIP SHA256 mismatch' }
    $oldZip = [IO.Compression.ZipFile]::OpenRead($oldArchive)
    $oldExe = Join-Path $temporary 'published-0.1.9.exe'
    try { [IO.Compression.ZipFileExtensions]::ExtractToFile($oldZip.GetEntry('Typlo.exe'), $oldExe) } finally { $oldZip.Dispose() }
    $spec = [Diagnostics.ProcessStartInfo]::new($oldExe)
    $spec.UseShellExecute = $false
    $spec.CreateNoWindow = $true
    $spec.RedirectStandardError = $true
    foreach ($argument in @('--verify-update-package', $candidate, $version, $candidateHash)) { $spec.ArgumentList.Add($argument) }
    $old = [Diagnostics.Process]::Start($spec)
    try {
        $errors = $old.StandardError.ReadToEndAsync()
        if (!$old.WaitForExit(60000)) { $old.Kill($true); throw 'v0.1.9 verifier timed out' }
        $detail = $errors.GetAwaiter().GetResult()
        if ($old.ExitCode -eq 0 -or $detail -notlike '*missing an executable or dictionary*') { throw "Expected v0.1.9 to require its missing shim: $detail" }
    } finally { $old.Dispose() }
    # Test the current verifier, including native failure status, without any
    # install/profile access. Spaces exercise argument handling.
    $copy = Join-Path $temporary 'current archive with spaces.zip'
    Copy-Item $candidate $copy
    foreach ($hash in @($candidateHash, ('0' * 64))) {
        $spec = [Diagnostics.ProcessStartInfo]::new((Join-Path $manual 'Typlo.exe'))
        $spec.UseShellExecute = $false
        $spec.CreateNoWindow = $true
        $spec.RedirectStandardError = $true
        foreach ($argument in @('--verify-update-package', $copy, $version, $hash)) { $spec.ArgumentList.Add($argument) }
        $child = [Diagnostics.Process]::Start($spec)
        try {
            $errors = $child.StandardError.ReadToEndAsync()
            if (!$child.WaitForExit(60000)) { $child.Kill($true); throw 'Current verifier timed out' }
            $detail = $errors.GetAwaiter().GetResult()
            if (($hash -ceq $candidateHash) -ne ($child.ExitCode -eq 0)) { throw "Current verifier status incorrect: $detail" }
            if ($hash -cne $candidateHash -and $detail -notlike '*SHA-256 does not match*') { throw "Digest check was not exercised: $detail" }
        } finally { $child.Dispose() }
    }
    Write-Host 'PASS exactly two Windows EXEs, no shim, current SHA256 verifier; published v0.1.9 rejects missing shim so manual handoff is required (no live upgrade tested)'
    return
}
# Exercise the shipped old-name launcher with real arguments and native exit
# codes. Both valid and invalid hashes must reach the canonical verifier.
$forwardedArchive = Join-Path $temporary 'archive with spaces.zip'
Copy-Item -LiteralPath $candidate -Destination $forwardedArchive
foreach ($hash in @($candidateHash, ('0' * 64))) {
    $spec = [Diagnostics.ProcessStartInfo]::new((Join-Path $manual 'typlo-rust.exe'))
    $spec.UseShellExecute = $false
    $spec.CreateNoWindow = $true
    $spec.RedirectStandardError = $true
    foreach ($argument in @('--verify-update-package', $forwardedArchive, $version, $hash)) { $spec.ArgumentList.Add($argument) }
    $child = [Diagnostics.Process]::Start($spec)
    try {
        $errors = $child.StandardError.ReadToEndAsync()
        if (!$child.WaitForExit(60000)) { $child.Kill($true); throw 'Legacy launcher timed out' }
        $detail = $errors.GetAwaiter().GetResult()
        if (($hash -ceq $candidateHash) -ne ($child.ExitCode -eq 0)) { throw "Legacy launcher lost verifier status: $detail" }
        if ($hash -cne $candidateHash -and $detail -notlike '*SHA-256 does not match*') { throw "Legacy launcher did not forward the digest check: $detail" }
    } finally { $child.Dispose() }
}
Write-Host 'PASS manual layout and legacy shortcut argument/exit forwarding; published v0.1.7 rejects the new format, so manual handoff is required (no live upgrade tested)'
