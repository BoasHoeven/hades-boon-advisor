<#
    BoonAdvisor uninstaller (Windows)

    Removes the Import line and the mod folder. The current RoomManager.lua is
    edited in place rather than replaced with the install-time backup, so a
    game updated since installation keeps its updated script.
#>

param(
    [string]$GamePath = ""
)

$ErrorActionPreference = "Stop"
$Marker = '-- BoonAdvisor mod'

function Write-Ok($msg)  { Write-Host "  [ok] $msg" -ForegroundColor Green }
function Write-Err($msg) { Write-Host "  [!!] $msg" -ForegroundColor Red }

Write-Host ""
Write-Host "BoonAdvisor uninstaller" -ForegroundColor Cyan
Write-Host ""

if ($GamePath -eq "") {
    try {
        $steam = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction Stop).SteamPath -replace '/', '\'
    } catch { $steam = "C:\Program Files (x86)\Steam" }
    $libs = @($steam)
    $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
    if (Test-Path $vdf) {
        foreach ($line in Get-Content $vdf) {
            if ($line -match '"path"\s+"([^"]+)"') { $libs += ($matches[1] -replace '\\\\', '\') }
        }
    }
    foreach ($lib in ($libs | Select-Object -Unique)) {
        $c = Join-Path $lib "steamapps\common\Hades"
        if (Test-Path (Join-Path $c "Content\Scripts\RoomManager.lua")) { $GamePath = $c; break }
    }
}

if ($GamePath -eq "" -or -not (Test-Path (Join-Path $GamePath "Content\Scripts\RoomManager.lua"))) {
    Write-Err "Could not find Hades. Re-run with -GamePath ""D:\Games\Hades"""
    exit 1
}

$Room   = Join-Path $GamePath "Content\Scripts\RoomManager.lua"
$Backup = "$Room.BoonAdvisorBackup"
$ModDir = Join-Path $GamePath "Content\Mods\BoonAdvisor"

# Strip exactly what the installer appended: the marker line, the Import line,
# and the blank separator line before the marker. Editing in place works no
# matter which game version is installed; restoring the backup would roll
# RoomManager.lua back to the version the game shipped when the mod was first
# installed. Preserve the file's own newline style rather than rewriting it.
$content = [System.IO.File]::ReadAllText($Room)
if (($content -like "*$Marker*") -or ($content -like "*Mods/BoonAdvisor/BoonAdvisor.lua*")) {
    $nl = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    # PowerShell -split keeps trailing empty entries, so joining with $nl
    # reproduces the file's final newline state exactly.
    $lines = $content -split "`r`n|`n"
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -like "*$Marker*") {
            if ($kept.Count -gt 0 -and $kept[$kept.Count - 1] -eq "") { $kept.RemoveAt($kept.Count - 1) }
            continue
        }
        if ($line -like "*Mods/BoonAdvisor/BoonAdvisor.lua*") { continue }
        $kept.Add($line)
    }
    $result = $kept -join $nl
    # The game ships RoomManager.lua without a trailing newline and the
    # installer added one to terminate the last line; the backup shows
    # whether the vanilla file ended without one, so undo it exactly.
    if ((Test-Path $Backup) -and $result.EndsWith($nl) -and
        -not ([System.IO.File]::ReadAllText($Backup)).EndsWith("`n")) {
        $result = $result.Substring(0, $result.Length - $nl.Length)
    }
    [System.IO.File]::WriteAllText($Room, $result)
    Write-Ok "Removed the Import line from RoomManager.lua"
} else {
    Write-Ok "RoomManager.lua has no BoonAdvisor lines"
}

if (Test-Path $Backup) {
    Remove-Item $Backup -Force
    Write-Ok "Removed the install-time backup"
}

if (Test-Path $ModDir) {
    Remove-Item $ModDir -Recurse -Force
    Write-Ok "Removed Content\Mods\BoonAdvisor"
}

Write-Host ""
Write-Host "  Done. Hades is back to vanilla." -ForegroundColor Green
Write-Host ""
