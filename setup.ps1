<#
.SYNOPSIS
  One-time setup helper for this repo: checks for AutoHotkey, downloads
  hidapitester.exe if missing, and optionally creates a Startup shortcut for
  the script you want running on this machine.

.DESCRIPTION
  This project needs three things to actually run:
    1. AutoHotkey installed on this machine -- v1.1 for mouse_jumper_pro.ahk,
       v2.0 for mouse_jumper_pro_v2.ahk.
    2. hidapitester.exe sitting next to the .ahk script (not included in this
       repo, see README).
    3. A shortcut in your Startup folder, if you want it to launch
       automatically at login (optional).

  This script checks/handles all three. It never overwrites an existing
  hidapitester.exe or Startup shortcut, and always asks before creating a
  shortcut.

.PARAMETER Script
  Which script to create a Startup shortcut for. Skips that step entirely if
  omitted -- you can re-run later with this set once you've decided.

.EXAMPLE
  .\setup.ps1

.EXAMPLE
  .\setup.ps1 -Script mouse_jumper_pro.ahk
#>

param(
    [ValidateSet("mouse_jumper_pro.ahk", "mouse_jumper_pro_v2.ahk")]
    [string]$Script
)

$repoRoot = $PSScriptRoot

function Write-Step {
    param([string]$Text)
    Write-Host ""
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

# ------------------------------------------------------------------
# 1. AutoHotkey
# ------------------------------------------------------------------
Write-Step "Checking for AutoHotkey"

$ahkCandidates = @(
    "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey.exe",
    "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe",
    "$env:ProgramFiles\AutoHotkey\UX\AutoHotkeyUX.exe",
    "${env:ProgramFiles(x86)}\AutoHotkey\AutoHotkey.exe"
)
$foundAhk = $ahkCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $foundAhk -and (Test-Path "$env:ProgramFiles\AutoHotkey")) {
    $foundAhk = Get-ChildItem -Path "$env:ProgramFiles\AutoHotkey" -Recurse -Filter "AutoHotkey*.exe" -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}

if ($foundAhk) {
    Write-Host "Found: $foundAhk" -ForegroundColor Green
} else {
    Write-Host "AutoHotkey doesn't look installed." -ForegroundColor Yellow
    Write-Host "Get it from https://www.autohotkey.com/ -- v1.1 for mouse_jumper_pro.ahk, v2.0 for mouse_jumper_pro_v2.ahk -- then re-run this script."
}

# ------------------------------------------------------------------
# 2. hidapitester.exe
# ------------------------------------------------------------------
Write-Step "Checking for hidapitester.exe"

$hidApiTesterPath = Join-Path $repoRoot "hidapitester.exe"
if (Test-Path $hidApiTesterPath) {
    Write-Host "Already present at $hidApiTesterPath" -ForegroundColor Green
} else {
    Write-Host "Not found -- downloading the latest Windows build from GitHub releases..."
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/todbot/hidapitester/releases/latest" -Headers @{ "User-Agent" = "ahk-mouse-jumper-setup" }
        $asset = $release.assets | Where-Object { $_.name -match "(?i)win" -and $_.name -match "(?i)\.zip$|\.exe$" } | Select-Object -First 1

        if (-not $asset) {
            Write-Host "Couldn't find a Windows build in the latest release." -ForegroundColor Yellow
            Write-Host "Download one manually from https://github.com/todbot/hidapitester/releases and place hidapitester.exe next to the script you use."
        } else {
            $downloadPath = Join-Path $env:TEMP $asset.name
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $downloadPath -UseBasicParsing

            if ($asset.name -match "\.zip$") {
                $extractDir = Join-Path $env:TEMP ("hidapitester_" + [guid]::NewGuid())
                Expand-Archive -Path $downloadPath -DestinationPath $extractDir -Force
                $exe = Get-ChildItem -Path $extractDir -Recurse -Filter "hidapitester.exe" | Select-Object -First 1
                if ($exe) {
                    Copy-Item -Path $exe.FullName -Destination $hidApiTesterPath -Force
                }
                Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue
            } else {
                Copy-Item -Path $downloadPath -Destination $hidApiTesterPath -Force
            }
            Remove-Item -Path $downloadPath -Force -ErrorAction SilentlyContinue

            if (Test-Path $hidApiTesterPath) {
                Write-Host "Downloaded to $hidApiTesterPath" -ForegroundColor Green
            } else {
                Write-Host "Download finished but hidapitester.exe wasn't found inside it." -ForegroundColor Yellow
                Write-Host "Grab it manually from https://github.com/todbot/hidapitester/releases."
            }
        }
    } catch {
        Write-Host "Automatic download failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "Download it manually from https://github.com/todbot/hidapitester/releases and place hidapitester.exe next to the script you use."
    }
}

# ------------------------------------------------------------------
# 3. Startup shortcut (optional, never done without asking)
# ------------------------------------------------------------------
Write-Step "Startup shortcut"

if (-not $Script) {
    Write-Host "No -Script specified, skipping. Re-run with e.g. -Script mouse_jumper_pro.ahk to create one."
} else {
    $scriptPath = Join-Path $repoRoot $Script
    if (-not (Test-Path $scriptPath)) {
        Write-Host "$Script not found next to this setup script -- skipping shortcut." -ForegroundColor Yellow
    } else {
        $startupDir = [Environment]::GetFolderPath("Startup")
        $shortcutPath = Join-Path $startupDir ([IO.Path]::GetFileNameWithoutExtension($Script) + ".lnk")

        if (Test-Path $shortcutPath) {
            Write-Host "A shortcut already exists at $shortcutPath -- leaving it alone." -ForegroundColor Yellow
        } else {
            $confirm = Read-Host "Create a Startup shortcut for $Script so it launches at login? (y/N)"
            if ($confirm -eq "y" -or $confirm -eq "Y") {
                $shell = New-Object -ComObject WScript.Shell
                $shortcut = $shell.CreateShortcut($shortcutPath)
                $shortcut.TargetPath = $scriptPath
                $shortcut.WorkingDirectory = $repoRoot
                $shortcut.Save()
                Write-Host "Created $shortcutPath" -ForegroundColor Green
            } else {
                Write-Host "Skipped."
            }
        }
    }
}

# ------------------------------------------------------------------
# 4. Hardware-specific codes
# ------------------------------------------------------------------
Write-Step "Next step"
Write-Host "If your mouse/receiver isn't a Logitech MX Master 3, run .\find_channel_codes.ps1 to discover"
Write-Host "the HID++ codes for your hardware before relying on channel switching -- see README.md."
