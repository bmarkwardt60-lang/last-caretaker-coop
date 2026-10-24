[CmdletBinding()]
param(
    [string]$ProjectRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryOwner = 'bmarkwardt60-lang'
$repositoryName = 'last-caretaker-coop'
$releaseApi = "https://api.github.com/repos/$repositoryOwner/$repositoryName/releases/latest"
$userAgent = 'LastCaretakerCoop-Updater'
$temporaryRoot = $null

try {
    $resolvedProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
    if (-not (Test-Path -LiteralPath (Join-Path $resolvedProjectRoot 'Start-Coop.ps1') -PathType Leaf)) {
        throw 'Project folder does not contain Start-Coop.ps1.'
    }

    try {
        $release = Invoke-RestMethod -Method Get -Uri $releaseApi -Headers @{ 'User-Agent' = $userAgent; Accept = 'application/vnd.github+json' } -TimeoutSec 15
    }
    catch {
        $statusCode = 0
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
        if ($statusCode -eq 404) {
            Write-Host 'No published GitHub release yet; continuing with the installed files.' -ForegroundColor DarkGray
            return
        }
        Write-Host 'Could not check GitHub for updates; continuing with the installed files.' -ForegroundColor Yellow
        return
    }

    $latestTag = [string]$release.tag_name
    if ($latestTag -notmatch '^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
        Write-Host 'The latest GitHub release has no supported version tag; skipping the update.' -ForegroundColor Yellow
        return
    }

    $versionFile = Join-Path $resolvedProjectRoot 'VERSION'
    $installedTag = ''
    if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
        $installedTag = [System.IO.File]::ReadAllText($versionFile).Trim()
    }
    if ($installedTag -eq $latestTag) {
        Write-Host "Co-op files are up to date ($latestTag)." -ForegroundColor DarkGray
        return
    }

    $archiveUrl = [string]$release.zipball_url
    $expectedPrefix = "https://api.github.com/repos/$repositoryOwner/$repositoryName/zipball/"
    if (-not $archiveUrl.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'GitHub returned an unexpected release archive URL.'
    }

    Write-Host "Updating co-op files: $installedTag -> $latestTag" -ForegroundColor Cyan
    $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('LastCaretakerCoop-Update-' + [guid]::NewGuid().ToString('N'))
    $extractRoot = Join-Path $temporaryRoot 'source'
    $archivePath = Join-Path $temporaryRoot 'release.zip'
    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
    Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath -Headers @{ 'User-Agent' = $userAgent; Accept = 'application/vnd.github+json' } -UseBasicParsing -TimeoutSec 60

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $extractFullPath = [System.IO.Path]::GetFullPath($extractRoot).TrimEnd('\', '/')
    $extractPrefix = $extractFullPath + [System.IO.Path]::DirectorySeparatorChar
    $archive = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        foreach ($entry in $archive.Entries) {
            $entryName = $entry.FullName.Replace('/', '\')
            if ([System.IO.Path]::IsPathRooted($entryName) -or $entryName.Contains(':') -or $entryName -match '(^|\\)\.\.?($|\\)') {
                throw "Unsafe path in release archive: '$($entry.FullName)'"
            }
            $entryTarget = [System.IO.Path]::GetFullPath((Join-Path $extractFullPath $entryName))
            if (-not $entryTarget.StartsWith($extractPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Unsafe path in release archive: '$($entry.FullName)'"
            }
        }
    }
    finally {
        $archive.Dispose()
    }

    [System.IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $extractRoot)
    $archiveRoots = @(Get-ChildItem -LiteralPath $extractRoot -Directory -Force)
    if ($archiveRoots.Count -ne 1) { throw 'Release archive did not contain the expected source folder.' }
    $sourceRoot = $archiveRoots[0].FullName

    $sourcePrefix = [System.IO.Path]::GetFullPath($sourceRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    foreach ($file in @(Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -Force)) {
        $relativePath = $file.FullName.Substring($sourcePrefix.Length)
        if ($relativePath -ieq 'Start-Coop.cmd') { continue }
        $destination = Join-Path $resolvedProjectRoot $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    }
    [System.IO.File]::WriteAllText($versionFile, $latestTag, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Updated co-op files to $latestTag." -ForegroundColor Green
}
catch {
    Write-Host "Update was not applied; continuing with the installed files. $($_.Exception.Message)" -ForegroundColor Yellow
}
finally {
    if ($temporaryRoot -and (Test-Path -LiteralPath $temporaryRoot -PathType Container)) {
        $systemTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        $resolvedTemporaryRoot = [System.IO.Path]::GetFullPath($temporaryRoot)
        if ($resolvedTemporaryRoot.StartsWith($systemTempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedTemporaryRoot).StartsWith('LastCaretakerCoop-Update-', [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
