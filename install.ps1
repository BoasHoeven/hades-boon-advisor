<#
    BoonAdvisor installer (Windows)

    Finds Hades, backs up the one file it edits, copies the mod in, and adds a
    single Import line. Safe to run twice.

    Usage:  right-click -> Run with PowerShell
       or:  powershell -ExecutionPolicy Bypass -File install.ps1
       or:  powershell -ExecutionPolicy Bypass -File install.ps1 -GamePath "D:\Games\Hades"
#>

param(
    [string]$GamePath = ""
)

$ErrorActionPreference = "Stop"
$ModName    = "BoonAdvisor"
$ImportLine = 'Import "../Mods/BoonAdvisor/BoonAdvisor.lua"'
$Marker     = '-- BoonAdvisor mod'

function Write-Step($msg) { Write-Host "  $msg" }
function Write-Ok($msg)   { Write-Host "  [ok] $msg" -ForegroundColor Green }
function Write-Err($msg)  { Write-Host "  [!!] $msg" -ForegroundColor Red }

Write-Host ""
Write-Host "BoonAdvisor - Hades boon pick advisor" -ForegroundColor Cyan
Write-Host ""

# --- 1. Locate Hades ---------------------------------------------------------
function Get-SteamLibraries {
    $libs = @()
    $steam = $null
    try {
        $steam = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction Stop).SteamPath
    } catch {
        foreach ($guess in @("C:\Program Files (x86)\Steam", "C:\Program Files\Steam")) {
            if (Test-Path $guess) { $steam = $guess; break }
        }
    }
    if (-not $steam) { return $libs }
    $steam = $steam -replace '/', '\'
    $libs += $steam

    # Extra library folders live in libraryfolders.vdf
    $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
    if (Test-Path $vdf) {
        foreach ($line in Get-Content $vdf) {
            if ($line -match '"path"\s+"([^"]+)"') {
                $libs += ($matches[1] -replace '\\\\', '\')
            }
        }
    }
    return $libs | Select-Object -Unique
}

if ($GamePath -eq "") {
    foreach ($lib in Get-SteamLibraries) {
        $candidate = Join-Path $lib "steamapps\common\Hades"
        if (Test-Path (Join-Path $candidate "Content\Scripts\RoomManager.lua")) {
            $GamePath = $candidate
            break
        }
    }
}

if ($GamePath -eq "" -or -not (Test-Path (Join-Path $GamePath "Content\Scripts\RoomManager.lua"))) {
    Write-Err "Could not find your Hades install."
    Write-Host ""
    Write-Host "  Re-run with the path, for example:"
    Write-Host '    powershell -ExecutionPolicy Bypass -File install.ps1 -GamePath "D:\Games\Hades"'
    Write-Host ""
    Write-Host "  (The folder that contains Content\Scripts\RoomManager.lua.)"
    exit 1
}
Write-Ok "Found Hades: $GamePath"

$Scripts = Join-Path $GamePath "Content\Scripts"
$ModDir  = Join-Path $GamePath "Content\Mods\$ModName"
$Room    = Join-Path $Scripts "RoomManager.lua"
$Backup  = "$Room.BoonAdvisorBackup"

# --- 2. Back up the one vanilla file we touch --------------------------------
if (-not (Test-Path $Backup)) {
    Copy-Item $Room $Backup
    Write-Ok "Backed up RoomManager.lua"
} elseif (-not ([System.IO.File]::ReadAllText($Room) -like "*$Marker*")) {
    # The live file has no import line, so a game update or Steam file
    # verification replaced it since the backup was made. The current file is
    # this game version's vanilla script; keeping the old backup would roll
    # the game back to a previous patch on uninstall.
    Copy-Item $Room $Backup -Force
    Write-Ok "Refreshed the backup (game files changed since the last install)"
} else {
    Write-Step "Backup already exists, keeping the original one"
}

# --- 3. Copy the mod ---------------------------------------------------------
$Source = Join-Path $PSScriptRoot "mod"
if (-not (Test-Path $Source)) {
    Write-Err "Can't find the 'mod' folder next to this script."
    exit 1
}
New-Item -ItemType Directory -Force -Path $ModDir | Out-Null
Copy-Item (Join-Path $Source "*.lua") $ModDir -Force
$count = (Get-ChildItem $ModDir -Filter *.lua).Count
Write-Ok "Installed $count Lua files to Content\Mods\$ModName"

# --- 4. Add the Import line (idempotent) -------------------------------------
$content = [System.IO.File]::ReadAllText($Room)
if ($content -like "*$Marker*") {
    Write-Step "Import line already present"
} else {
    # Append using the file's own newline style (the game ships CRLF).
    $nl = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    if (-not $content.EndsWith("`n")) { $content += $nl }
    $content += "$nl$Marker$nl$ImportLine$nl"
    [System.IO.File]::WriteAllText($Room, $content)
    Write-Ok "Added the Import line to RoomManager.lua"
}

# --- 5. Verify ---------------------------------------------------------------
$verify = [System.IO.File]::ReadAllText($Room)
if (($verify -like "*$ImportLine*") -and (Test-Path (Join-Path $ModDir "BoonAdvisor.lua"))) {
    Write-Host ""
    Write-Host "  Done. Start Hades and take a boon." -ForegroundColor Green
    Write-Host "  Ranks appear on boons, hammers, Poms, Chaos, doors, the shop and keepsakes."
    Write-Host ""
    Write-Host "  To remove it later: uninstall.ps1"
    Write-Host ""
} else {
    Write-Err "Verification failed - the mod may not be installed correctly."
    exit 1
}
