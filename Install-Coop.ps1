[CmdletBinding()]
param(
    [string]$GameWin64Dir,
    [string]$UE4SSZip
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$modSource = Join-Path $projectRoot 'Mods\LastCaretakerCoop'
$gameExeName = 'VoyageSteam-Win64-Shipping.exe'
$loaderDllRelativePath = 'ue4ss\UE4SS.dll'

if (-not (Test-Path -LiteralPath (Join-Path $modSource 'scripts\main.lua') -PathType Leaf)) {
    throw "The co-op mod files are missing from '$modSource'. Keep Install-Coop.ps1 in the project root."
}

function Resolve-GameWin64Dir {
    param([string]$RequestedPath)

    if ($RequestedPath) {
        $candidate = (Resolve-Path -LiteralPath $RequestedPath).Path
        $possibleDirs = @(
            $candidate,
            (Join-Path $candidate 'Binaries\Win64'),
            (Join-Path $candidate 'Voyage\Binaries\Win64'),
            (Join-Path $candidate 'Voyage\Voyage\Binaries\Win64')
        )
        foreach ($directory in $possibleDirs) {
            if (Test-Path -LiteralPath (Join-Path $directory $gameExeName) -PathType Leaf) {
                return (Resolve-Path -LiteralPath $directory).Path
            }
        }
        throw "Could not find $gameExeName under '$RequestedPath'. Pass the Win64 folder containing the executable, or the game's Voyage install folder."
    }

    $steamRoots = [System.Collections.Generic.List[string]]::new()

    # Read the Steam installation path from the registry, then include common
    # install locations as a fallback for portable or first-run installations.

    foreach ($registryKey in @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )) {
        $steamInfo = Get-ItemProperty -LiteralPath $registryKey -ErrorAction SilentlyContinue
        if ($steamInfo) {
            foreach ($propertyName in @('SteamPath', 'InstallPath')) {
                $steamPathProperty = $steamInfo.PSObject.Properties[$propertyName]
                if ($steamPathProperty -and $steamPathProperty.Value) {
                    $steamRoots.Add(([string]$steamPathProperty.Value).Replace('/', '\'))
                }
            }
        }
    }
    if (${env:ProgramFiles(x86)}) { $steamRoots.Add((Join-Path ${env:ProgramFiles(x86)} 'Steam')) }
    if ($env:ProgramFiles) { $steamRoots.Add((Join-Path $env:ProgramFiles 'Steam')) }
    if ($env:LOCALAPPDATA) { $steamRoots.Add((Join-Path $env:LOCALAPPDATA 'Steam')) }

    # Steam's VDF lists additional library locations. Read those so the script
    # also works when the game is installed outside the default Steam folder.
    foreach ($steamRoot in @($steamRoots.ToArray())) {
        $vdfPath = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdfPath -PathType Leaf) {
            $vdf = Get-Content -LiteralPath $vdfPath -Raw
            foreach ($match in [regex]::Matches($vdf, '"path"\s+"([^"]+)"')) {
                $libraryPath = $match.Groups[1].Value -replace '\\\\', '\'
                if ($libraryPath) { $steamRoots.Add($libraryPath) }
            }
        }
    }

    $seen = @{}
    foreach ($steamRoot in $steamRoots) {
        if (-not $steamRoot) { continue }
        $root = [System.IO.Path]::GetFullPath($steamRoot)
        $rootKey = $root.TrimEnd('\').ToLowerInvariant()
        if ($seen.ContainsKey($rootKey)) { continue }
        $seen[$rootKey] = $true

        $installDirs = [System.Collections.Generic.List[string]]::new()
        $manifestPath = Join-Path $root 'steamapps\appmanifest_1783560.acf'
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            $manifest = [System.IO.File]::ReadAllText($manifestPath)
            $installMatch = [regex]::Match($manifest, '(?im)^\s*"installdir"\s+"(?<name>[^"]+)"')
            if ($installMatch.Success) { $installDirs.Add($installMatch.Groups['name'].Value) }
        }
        # The manifest covers normal Steam installs. These names cover manual
        # installs and Steam setups where that manifest cannot be read.
        foreach ($fallbackName in @('Voyage', 'The Last Caretaker', 'TheLastCaretaker')) {
            if ($installDirs -notcontains $fallbackName) { $installDirs.Add($fallbackName) }
        }

        foreach ($installDir in $installDirs) {
            $installRoot = Join-Path $root (Join-Path 'steamapps\common' $installDir)
            $possibleDirs = @(
                (Join-Path $installRoot 'Voyage\Voyage\Binaries\Win64'),
                (Join-Path $installRoot 'Voyage\Binaries\Win64'),
                (Join-Path $installRoot 'Binaries\Win64')
            )
            foreach ($candidate in $possibleDirs) {
                if (Test-Path -LiteralPath (Join-Path $candidate $gameExeName) -PathType Leaf) {
                    Write-Host "Found The Last Caretaker in $candidate"
                    return (Resolve-Path -LiteralPath $candidate).Path
                }
            }
        }
    }

    while ($true) {
        $manualPath = (Read-Host "Enter the game Win64 folder (the one containing $gameExeName)").Trim().Trim('"').Trim("'")
        if (-not $manualPath) { continue }
        try {
            return Resolve-GameWin64Dir -RequestedPath $manualPath
        }
        catch {
            Write-Warning $_.Exception.Message
        }
    }
}

function Find-UE4SSPayloadRoot {
    param([string]$StagingDirectory)

    $loader = Get-ChildItem -LiteralPath $StagingDirectory -Filter 'UE4SS.dll' -File -Recurse |
        Where-Object { $_.Directory.Name -ieq 'ue4ss' } |
        Select-Object -First 1
    if (-not $loader) {
        throw 'The selected ZIP does not contain ue4ss\UE4SS.dll. Download the "UE4SS TLC UE5 8" package, not the source-code archive.'
    }

    $payloadRoot = $loader.Directory.Parent.FullName
    $proxyNames = @('dwmapi.dll', 'xinput1_3.dll', 'winmm.dll', 'version.dll', 'dxgi.dll', 'd3d11.dll')
    $candidate = $payloadRoot
    while ($candidate -and $candidate.StartsWith($StagingDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
        $hasExpectedLayout = Test-Path -LiteralPath (Join-Path $candidate 'ue4ss\UE4SS.dll') -PathType Leaf
        $hasLoaderProxy = $false
        foreach ($proxyName in $proxyNames) {
            if (Test-Path -LiteralPath (Join-Path $candidate $proxyName) -PathType Leaf) {
                $hasLoaderProxy = $true
                break
            }
        }
        if ($hasExpectedLayout -and $hasLoaderProxy) { return $candidate }

        if ($candidate -eq $StagingDirectory) { break }
        $candidate = Split-Path -Parent $candidate
    }

    # The game-specific package may use a proxy DLL name outside this list.
    # The ue4ss folder is still a useful payload root in that case.
    return $payloadRoot
}

function Backup-ExistingFile {
    param(
        [string]$TargetPath,
        [string]$RelativePath
    )

    if (Test-Path -LiteralPath $TargetPath -PathType Leaf) {
        $backupPath = Join-Path $backupRoot $RelativePath
        $backupParent = Split-Path -Parent $backupPath
        New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
        Copy-Item -LiteralPath $TargetPath -Destination $backupPath -Force
        $script:madeBackup = $true
    }
}

function Copy-FileIfChanged {
    param(
        [string]$SourcePath,
        [string]$TargetPath,
        [string]$RelativePath
    )

    if (Test-Path -LiteralPath $TargetPath -PathType Leaf) {
        $sourceHash = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash
        $targetHash = (Get-FileHash -LiteralPath $TargetPath -Algorithm SHA256).Hash
        if ($sourceHash -eq $targetHash) { return $false }
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $TargetPath) -Force | Out-Null
    Backup-ExistingFile -TargetPath $TargetPath -RelativePath $RelativePath
    Copy-Item -LiteralPath $SourcePath -Destination $TargetPath -Force
    return $true
}

$gameWin64 = Resolve-GameWin64Dir -RequestedPath $GameWin64Dir
if (Get-Process -Name 'VoyageSteam-Win64-Shipping' -ErrorAction SilentlyContinue) {
    throw 'Close The Last Caretaker before installing the mod, then run this script again.'
}

$localAppData = $env:LOCALAPPDATA
if (-not $localAppData) { $localAppData = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData) }
if (-not $localAppData) { throw 'Windows did not provide a local application data folder for backups and logs.' }

# Check permissions up front so an installation under a protected Steam folder
# fails with a useful next step instead of partway through copying the loader.
$writeProbe = Join-Path $gameWin64 ('.LastCaretakerCoop-write-check-' + [guid]::NewGuid().ToString('N'))
try {
    [System.IO.File]::WriteAllText($writeProbe, '')
}
catch {
    throw "Cannot write to '$gameWin64'. If Steam installed the game under Program Files, close the launcher and rerun PowerShell as Administrator. Details: $($_.Exception.Message)"
}
finally {
    Remove-Item -LiteralPath $writeProbe -Force -ErrorAction SilentlyContinue
}

$ue4ssRoot = Join-Path $gameWin64 'ue4ss'
$ue4ssDll = Join-Path $gameWin64 $loaderDllRelativePath
$modsDir = Join-Path $ue4ssRoot 'Mods'
$modsTxt = Join-Path $modsDir 'mods.txt'

$timestamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$backupRoot = Join-Path $localAppData "LastCaretakerCoop\install-backups\$timestamp"
$madeBackup = $false
$stage = $null

if (-not (Test-Path -LiteralPath $ue4ssDll -PathType Leaf) -or $UE4SSZip) {
    if (-not $UE4SSZip) {
        $localPackages = @(Get-ChildItem -LiteralPath $projectRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)UE4SS.*(TLC|UE5[ _-]?8)' } |
            Sort-Object LastWriteTime -Descending)
        $userProfile = $env:USERPROFILE
        if (-not $userProfile) { $userProfile = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile) }
        $downloadDir = if ($userProfile) { Join-Path $userProfile 'Downloads' } else { $null }
        $downloadedPackages = @()
        if ($downloadDir -and (Test-Path -LiteralPath $downloadDir -PathType Container)) {
            $downloadedPackages = @(Get-ChildItem -LiteralPath $downloadDir -Filter '*.zip' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '(?i)UE4SS.*(TLC|UE5[ _-]?8)' } |
                Sort-Object LastWriteTime -Descending)
        }

        if ($localPackages.Count -eq 1) {
            $UE4SSZip = $localPackages[0].FullName
            Write-Host "Found extracted UE4SS package: $UE4SSZip"
        }
        elseif ($downloadedPackages.Count -eq 1) {
            $UE4SSZip = $downloadedPackages[0].FullName
            Write-Host "Found UE4SS package: $UE4SSZip"
        }
        else {
            Write-Host ''
            Write-Host 'Download the manual "UE4SS TLC UE5 8" v1.3 package from:'
            Write-Host 'https://www.nexusmods.com/thelastcaretaker/mods/4?tab=files'
            Write-Host 'You may paste either the ZIP path or the folder where you extracted it.'
            $UE4SSZip = (Read-Host 'UE4SS package path').Trim().Trim('"').Trim("'")
        }
    }

    if (-not (Test-Path -LiteralPath $UE4SSZip)) {
        throw "UE4SS package path not found: '$UE4SSZip'"
    }

    if (Test-Path -LiteralPath $UE4SSZip -PathType Container) {
        $sourcePackageRoot = (Resolve-Path -LiteralPath $UE4SSZip).Path
    }
    else {
        if ([System.IO.Path]::GetExtension($UE4SSZip) -ine '.zip') {
            throw 'UE4SS package must be a .zip file or an extracted folder.'
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $stage = Join-Path ([System.IO.Path]::GetTempPath()) ('TLC-Coop-UE4SS-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $stage | Out-Null

        # Reject rooted paths and traversal entries before extracting the archive.
        $stageFullPath = [System.IO.Path]::GetFullPath($stage).TrimEnd('\')
        $stagePrefix = $stageFullPath + '\'
        $archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $UE4SSZip).Path)
        try {
            foreach ($entry in $archive.Entries) {
                $entryName = $entry.FullName.Replace('/', '\')
                if ([System.IO.Path]::IsPathRooted($entryName) -or $entryName.Contains(':') -or $entryName -match '(^|\\)\.\.?($|\\)') {
                    throw "Unsafe path in UE4SS archive: '$($entry.FullName)'"
                }
                $entryTarget = [System.IO.Path]::GetFullPath((Join-Path $stageFullPath $entryName))
                if (-not $entryTarget.StartsWith($stagePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "Unsafe path in UE4SS archive: '$($entry.FullName)'"
                }
            }
        }
        finally {
            $archive.Dispose()
        }

        [System.IO.Compression.ZipFile]::ExtractToDirectory((Resolve-Path -LiteralPath $UE4SSZip).Path, $stage)
        $sourcePackageRoot = $stage
    }

    $payloadRoot = Find-UE4SSPayloadRoot -StagingDirectory $sourcePackageRoot
    $payloadFullPath = [System.IO.Path]::GetFullPath($payloadRoot).TrimEnd('\')

    Get-ChildItem -LiteralPath $payloadFullPath -File -Recurse | ForEach-Object {
        $relativePath = $_.FullName.Substring($payloadFullPath.Length).TrimStart([char[]]@('\', '/'))
        $targetPath = Join-Path $gameWin64 $relativePath
        # Preserve installed mods and their load list; add package defaults only
        # when their target files do not already exist.
        if ($relativePath -match '^(?i:ue4ss[\\/]+Mods[\\/])' -and
            (Test-Path -LiteralPath $targetPath -PathType Leaf)) { return }

        Copy-FileIfChanged -SourcePath $_.FullName -TargetPath $targetPath -RelativePath (Join-Path 'UE4SS' $relativePath) | Out-Null
    }
}
elseif (-not $UE4SSZip) {
    Write-Host "UE4SS already exists at '$ue4ssDll'; reusing it. To update it, rerun with -UE4SSZip <path-to-zip>."
}

if (-not (Test-Path -LiteralPath $ue4ssDll -PathType Leaf)) {
    throw "UE4SS extraction did not create '$ue4ssDll'. Check that you selected the TLC UE5 8 package."
}

New-Item -ItemType Directory -Path $modsDir -Force | Out-Null
$modFiles = Get-ChildItem -LiteralPath $modSource -File -Recurse
foreach ($file in $modFiles) {
    $relativePath = $file.FullName.Substring($modSource.Length).TrimStart([char[]]@('\', '/'))
    $targetPath = Join-Path (Join-Path $modsDir 'LastCaretakerCoop') $relativePath
    Copy-FileIfChanged -SourcePath $file.FullName -TargetPath $targetPath -RelativePath (Join-Path 'Mod' (Join-Path 'LastCaretakerCoop' $relativePath)) | Out-Null
}

$currentModsTxt = ''
if (Test-Path -LiteralPath $modsTxt -PathType Leaf) {
    $currentModsTxt = [System.IO.File]::ReadAllText($modsTxt)
}
$updatedLines = [System.Collections.Generic.List[string]]::new()
if ($currentModsTxt.Length -gt 0) {
    foreach ($line in ($currentModsTxt -split "`r?`n")) {
        if ($line -notmatch '^\s*LastCaretakerCoop\s*:') { $updatedLines.Add($line) }
    }
}
while ($updatedLines.Count -gt 0 -and $updatedLines[$updatedLines.Count - 1] -eq '') {
    $updatedLines.RemoveAt($updatedLines.Count - 1)
}
$updatedLines.Add('LastCaretakerCoop : 1')
$updatedModsTxt = [string]::Join("`r`n", $updatedLines.ToArray()) + "`r`n"
$normalizedCurrent = $currentModsTxt
if ($normalizedCurrent.Length -gt 0 -and -not $normalizedCurrent.EndsWith("`n")) {
    $normalizedCurrent += "`r`n"
}
if ($updatedModsTxt -cne $normalizedCurrent) {
    Backup-ExistingFile -TargetPath $modsTxt -RelativePath 'Mods\mods.txt'
    [System.IO.File]::WriteAllText($modsTxt, $updatedModsTxt, [System.Text.UTF8Encoding]::new($false))
}

if ($stage) {
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $stageToRemove = [System.IO.Path]::GetFullPath($stage)
    if ($stageToRemove.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $stageToRemove).StartsWith('TLC-Coop-UE4SS-', [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $stageToRemove -Recurse -Force
    }
}

$stateRoot = Join-Path $localAppData 'LastCaretakerCoop'
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $stateRoot 'game-win64.txt'), $gameWin64, [System.Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host 'Installed or updated LastCaretakerCoop.' -ForegroundColor Green
Write-Host "Game folder: $gameWin64"
Write-Host "Mod folder:  $(Join-Path $modsDir 'LastCaretakerCoop')"
Write-Host "Enabled in:  $modsTxt"
Write-Host 'The current prototype syncs player poses over LAN; shared world state is still in progress.'
if ($madeBackup) {
    Write-Host "Backups of replaced files: $backupRoot"
}
