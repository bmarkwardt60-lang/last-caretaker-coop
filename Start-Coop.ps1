[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-PythonRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$PrefixArgs = @()
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    if ($Path -match '(?i)\\WindowsApps\\') { return $null }

    $probeArgs = @($PrefixArgs) + @('--version')
    $probeOutput = & $Path @probeArgs 2>&1
    $probeExitCode = $LASTEXITCODE
    if ($probeExitCode -ne 0) { return $null }

    $versionText = [string](@($probeOutput) -join ' ')
    if ($versionText -notmatch '(?i)\bPython\s+(?<version>\d+\.\d+(?:\.\d+)?)\b') { return $null }
    [version]$version = [version]'0.0'
    if (-not [version]::TryParse($Matches.version, [ref]$version)) { return $null }
    if ($version -lt [version]'3.10') { return $null }

    return [pscustomobject]@{
        Path       = $Path
        PrefixArgs = @($PrefixArgs)
        Version    = $version.ToString(2)
    }
}

function Find-PythonRuntime {
    $launcherPaths = [System.Collections.Generic.List[string]]::new()
    $launcherCommand = Get-Command -Name 'py.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($launcherCommand -and $launcherCommand.Source) { $launcherPaths.Add($launcherCommand.Source) }
    if ($env:LOCALAPPDATA) {
        $localLauncher = Join-Path $env:LOCALAPPDATA 'Programs\Python\Launcher\py.exe'
        if (Test-Path -LiteralPath $localLauncher -PathType Leaf) { $launcherPaths.Add($localLauncher) }
    }

    foreach ($path in ($launcherPaths | Select-Object -Unique)) {
        $runtime = Test-PythonRuntime -Path $path -PrefixArgs @('-3')
        if ($runtime) { return $runtime }
    }

    $pythonPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($commandName in @('python.exe', 'python3.exe')) {
        $pythonCommand = Get-Command -Name $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pythonCommand -and $pythonCommand.Source) { $pythonPaths.Add($pythonCommand.Source) }
    }

    foreach ($basePath in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python'),
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    )) {
        if (-not $basePath) { continue }
        foreach ($pythonFile in @(Get-ChildItem -Path (Join-Path $basePath 'Python3*\python.exe') -File -ErrorAction SilentlyContinue)) {
            $pythonPaths.Add($pythonFile.FullName)
        }
    }

    foreach ($path in ($pythonPaths | Select-Object -Unique)) {
        $runtime = Test-PythonRuntime -Path $path
        if ($runtime) { return $runtime }
    }
    return $null
}

function Get-SteamExecutable {
    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($registryKey in @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )) {
        $steamInfo = Get-ItemProperty -LiteralPath $registryKey -ErrorAction SilentlyContinue
        if ($steamInfo) {
            foreach ($propertyName in @('SteamPath', 'InstallPath')) {
                $property = $steamInfo.PSObject.Properties[$propertyName]
                if ($property -and $property.Value) {
                    $candidates.Add((Join-Path ([string]$property.Value) 'steam.exe'))
                }
            }
        }
    }
    if (${env:ProgramFiles(x86)}) { $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Steam\steam.exe')) }
    if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles 'Steam\steam.exe')) }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Get-PlayerName {
    $defaultName = [string]$env:USERNAME
    if (-not $defaultName) { $defaultName = 'Player' }
    $answer = Read-Host "Name shown to your friend [$defaultName]"
    if (-not $answer) { $answer = $defaultName }
    $cleanName = ($answer -replace '[^A-Za-z0-9_.-]', '_').Trim('_')
    if (-not $cleanName) { $cleanName = 'Player' }
    if ($cleanName.Length -gt 24) { $cleanName = $cleanName.Substring(0, 24) }
    return $cleanName
}

function Select-HostAddress {
    $addresses = @()
    try {
        $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object {
                $_.AddressState -eq 'Preferred' -and
                $_.IPAddress -notmatch '^(127\.|169\.254\.)'
            } |
            Sort-Object -Property InterfaceIndex, IPAddress -Unique)
    }
    catch {
        $addresses = @()
    }

    if ($addresses.Count -eq 1) { return [string]$addresses[0].IPAddress }
    if ($addresses.Count -gt 1) {
        Write-Host ''
        Write-Host 'Choose the address on the network your friend will use:' -ForegroundColor Cyan
        for ($index = 0; $index -lt $addresses.Count; $index++) {
            Write-Host ('  {0}. {1}  ({2})' -f ($index + 1), $addresses[$index].IPAddress, $addresses[$index].InterfaceAlias)
        }
        while ($true) {
            $choice = Read-Host 'Address number [1]'
            if (-not $choice) { $choice = '1' }
            $number = 0
            if ([int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le $addresses.Count) {
                return [string]$addresses[$number - 1].IPAddress
            }
            Write-Host 'Enter one of the listed numbers.' -ForegroundColor Yellow
        }
    }

    while ($true) {
        $manualAddress = (Read-Host 'Could not detect a LAN address. Enter your LAN IPv4 address').Trim()
        [System.Net.IPAddress]$parsedAddress = $null
        if ([System.Net.IPAddress]::TryParse($manualAddress, [ref]$parsedAddress) -and
            $parsedAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
            return $manualAddress
        }
        Write-Host 'Enter a valid IPv4 address, such as 192.168.1.20.' -ForegroundColor Yellow
    }
}

function Read-InviteCode {
    while ($true) {
        $code = (Read-Host 'Paste the invite code from the host').Trim()
        $parts = $code -split '\|', 5
        if ($parts.Count -eq 5 -and $parts[0] -eq 'TLC1') {
            $portNumber = 0
            if ($parts[1] -and [int]::TryParse($parts[2], [ref]$portNumber) -and
                $portNumber -ge 1 -and $portNumber -le 65535 -and $parts[3] -and $parts[4]) {
                return [pscustomobject]@{
                    Host    = $parts[1]
                    Port    = $portNumber
                    Session = $parts[3]
                    Token   = $parts[4]
                }
            }
        }
        Write-Host 'That invite code is not valid. Ask the host to copy it again.' -ForegroundColor Yellow
    }
}

function ConvertTo-CommandLineArgument {
    param([string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Show-RecentBridgeLog {
    param([string[]]$Paths)
    foreach ($path in $Paths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $lines = @(Get-Content -LiteralPath $path -Tail 25 -ErrorAction SilentlyContinue)
            if ($lines.Count -gt 0) {
                Write-Host "--- $path ---" -ForegroundColor DarkGray
                $lines | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
            }
        }
    }
}

function Invoke-CoopWizard {
    $projectRoot = $PSScriptRoot
    $installerPath = Join-Path $projectRoot 'Install-Coop.ps1'
    $bridgePath = Join-Path $projectRoot 'bridge\coop_bridge.py'
    $stateRoot = Join-Path $env:LOCALAPPDATA 'LastCaretakerCoop'
    $gameProcessName = 'VoyageSteam-Win64-Shipping'
    $port = 28770
    $session = 'tlc-coop'

    Clear-Host
    Write-Host 'THE LAST CARETAKER CO-OP' -ForegroundColor Cyan
    Write-Host 'Guided setup and LAN session launcher' -ForegroundColor DarkGray
    Write-Host ''

    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $bridgePath -PathType Leaf)) {
        throw 'The setup files are incomplete. Keep Start-Coop.ps1, Install-Coop.ps1, and the bridge folder together.'
    }

    if (Get-Process -Name $gameProcessName -ErrorAction SilentlyContinue) {
        throw 'The game is already open. Close it first, then double-click Start-Coop.cmd so the mod can be updated before launch.'
    }

    Write-Host 'Checking Python (3.10 or newer)...' -ForegroundColor Cyan
    $pythonRuntime = Find-PythonRuntime
    if (-not $pythonRuntime) {
        $winget = Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($winget) {
            Write-Host 'The LAN bridge needs Python 3.10 or newer.' -ForegroundColor Yellow
            $installPython = Read-Host 'Install Python 3.12 for your Windows account with winget now? [Y/N]'
            if ($installPython -match '^(?i:y|yes)$') {
                & $winget.Source install --id Python.Python.3.12 --exact --scope user --accept-package-agreements --accept-source-agreements
                if ($LASTEXITCODE -ne 0) { throw 'Python installation did not finish successfully. Install Python 3.10+ and run Start-Coop.cmd again.' }
                $pythonRuntime = Find-PythonRuntime
            }
        }
        if (-not $pythonRuntime) {
            throw 'Python 3.10 or newer is required. Install it from https://www.python.org/downloads/ and run Start-Coop.cmd again.'
        }
    }
    Write-Host "Python $($pythonRuntime.Version) is ready." -ForegroundColor Green

    Write-Host ''
    Write-Host 'Step 1 of 3: install or update the game files' -ForegroundColor Cyan
    Write-Host 'The game must stay closed during setup. The installer will find the Steam folder automatically.'
    & $installerPath

    Write-Host ''
    Write-Host 'Step 2 of 3: choose your session role' -ForegroundColor Cyan
    Write-Host '  1. Host a session'
    Write-Host '  2. Join a friend'
    $roleChoice = ''
    while ($roleChoice -notin @('1', '2')) {
        $roleChoice = (Read-Host 'Choose 1 or 2').Trim()
        if ($roleChoice -notin @('1', '2')) { Write-Host 'Enter 1 to host or 2 to join.' -ForegroundColor Yellow }
    }

    $playerName = Get-PlayerName
    $bridgeMode = if ($roleChoice -eq '1') { 'host' } else { 'join' }
    $bridgeArgs = @()
    $inviteCode = $null
    if ($bridgeMode -eq 'host') {
        $hostAddress = Select-HostAddress
        $sessionToken = [guid]::NewGuid().ToString('N')
        $inviteCode = 'TLC1|{0}|{1}|{2}|{3}' -f $hostAddress, $port, $session, $sessionToken
        Write-Host ''
        Write-Host 'Share this invite code with the other player:' -ForegroundColor Green
        Write-Host $inviteCode -ForegroundColor White
        try {
            Set-Clipboard -Value $inviteCode -ErrorAction Stop
            Write-Host 'Copied to the clipboard.' -ForegroundColor Green
        }
        catch {
            Write-Host 'Clipboard access was unavailable; copy the code above.' -ForegroundColor Yellow
        }
        New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $stateRoot 'last-invite.txt'), $inviteCode, [System.Text.UTF8Encoding]::new($false))
        Write-Host 'If Windows Firewall asks, allow Python on private networks.' -ForegroundColor DarkGray
        $bridgeArgs = @('--name', $playerName, '--session', $session, '--token', $sessionToken, '--port', [string]$port)
    }
    else {
        $invite = Read-InviteCode
        $session = $invite.Session
        $sessionToken = $invite.Token
        $hostAddress = $invite.Host
        $port = $invite.Port
        $bridgeArgs = @('--host', $hostAddress, '--name', $playerName, '--session', $session, '--token', $sessionToken, '--port', [string]$port)
    }

    Write-Host ''
    Write-Host 'Step 3 of 3: start the bridge and launch the game' -ForegroundColor Cyan
    Write-Host 'Use a disposable test save on both PCs while this prototype is being tested.' -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    $stdoutLog = Join-Path $stateRoot 'bridge-output.log'
    $stderrLog = Join-Path $stateRoot 'bridge-errors.log'
    Remove-Item -LiteralPath $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue

    $arguments = @($pythonRuntime.PrefixArgs) + @('-u', $bridgePath, $bridgeMode) + $bridgeArgs
    $argumentLine = (($arguments | ForEach-Object { ConvertTo-CommandLineArgument ([string]$_) }) -join ' ')
    $bridgeProcess = $null
    try {
        $bridgeProcess = Start-Process -FilePath $pythonRuntime.Path -ArgumentList $argumentLine -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
        Start-Sleep -Seconds 2
        $bridgeProcess.Refresh()
        if ($bridgeProcess.HasExited) {
            Show-RecentBridgeLog -Paths @($stdoutLog, $stderrLog)
            throw 'The LAN bridge stopped during startup. Check the messages above.'
        }
        Write-Host "LAN bridge is running. Logs: $stateRoot" -ForegroundColor Green

        $steamExe = Get-SteamExecutable
        if ($steamExe) {
            Write-Host 'Launching The Last Caretaker through Steam...' -ForegroundColor Cyan
            Start-Process -FilePath $steamExe -ArgumentList '-applaunch 1783560' | Out-Null
        }
        else {
            Write-Host 'Launching The Last Caretaker through the Steam link...' -ForegroundColor Cyan
            Start-Process -FilePath 'steam://rungameid/1783560' | Out-Null
        }

        $gameProcess = $null
        $launchDeadline = [datetime]::UtcNow.AddMinutes(3)
        while (-not $gameProcess -and [datetime]::UtcNow -lt $launchDeadline) {
            $bridgeProcess.Refresh()
            if ($bridgeProcess.HasExited) {
                Show-RecentBridgeLog -Paths @($stdoutLog, $stderrLog)
                throw 'The LAN bridge stopped while Steam was starting the game.'
            }
            $gameProcess = Get-Process -Name $gameProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $gameProcess) { Start-Sleep -Seconds 2 }
        }
        if (-not $gameProcess) {
            throw "Steam did not start the game within three minutes. Start it from Steam, then run Start-Coop.cmd again. Bridge logs: $stateRoot"
        }

        Write-Host 'The game is running. The bridge will close when the game exits.' -ForegroundColor Green
        Write-Host 'Load a disposable save on both PCs. Press F8 for local details and F9 for the latest peer pose.' -ForegroundColor DarkGray
        $gameProcess.WaitForExit()
        Write-Host 'Game closed; stopping the LAN bridge.' -ForegroundColor DarkGray
    }
    finally {
        if ($bridgeProcess) {
            $bridgeProcess.Refresh()
            if (-not $bridgeProcess.HasExited) {
                Stop-Process -Id $bridgeProcess.Id -Force -ErrorAction SilentlyContinue
                $bridgeProcess.WaitForExit(5000) | Out-Null
            }
        }
    }
}

try {
    Invoke-CoopWizard
    exit 0
}
catch {
    Write-Host ''
    Write-Host "Setup stopped: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
