<#
.SYNOPSIS
  Fully autonomously discovers the HID++ 2.0 identifiers (device index,
  feature index, function number, channel byte) needed to switch hosts on a
  Logitech multi-host mouse/receiver pair, so you can adapt SwitchChannel()
  in mouse_jumper_pro.ahk / mouse_jumper_pro_v2.ahk to your own hardware.

.DESCRIPTION
  This project's default byte codes (device index 1 or 2, feature index
  0x0A) were found on a Logitech MX Master 3 paired to a Logitech receiver
  (VID:PID 046D:C52B). Other mice/receivers are very likely to need
  different values, because the HID++ "feature table" (which slot a given
  feature lands on) is assigned per firmware/pairing, not fixed across
  hardware -- and some receivers don't even expose the same feature.

  This script needs no manual input and doesn't assume anything about which
  exact mouse/receiver you have, or which HID report conventions it uses:
    1. Lists the matching HID collections as a table (VID:PID, usagePage,
       usage, interface).
    2. Scans every device index, and for each one auto-detects which
       (usage, report-length) combination gets real replies out of it, then
       checks it for the HID++ features known to relate to host switching
       (CHANGE_HOST, HOSTS_INFO, and a couple of related pairing features).
       This isn't detected once globally, because a single usagePage often
       has several collections (e.g. one for 7-byte "short" HID++ reports,
       one for 20-byte "long" reports) and, as it turns out, even different
       device indices *on the very same receiver* can need different ones --
       the receiver's own pseudo-index (0xFF) may only answer short reports
       while an actual paired device only answers long ones, or vice versa.
       If none of the known features are found anywhere, it dumps the full
       feature table of every responding device index for you to inspect --
       but it will NOT blindly fire commands at unrecognized features, since
       some HID++ features (device reset, DFU mode, ...) are destructive and
       guessing at those is not safe to automate.
    3. For every found candidate, autonomously tries the plausible function
       numbers, channels, and report lengths, sending a real "switch host"
       command each time. Success is detected by the device going silent on
       this receiver right after a command -- i.e. it actually jumped to
       another host -- with no need to eyeball the mouse. The moment that
       happens, it stops and prints the exact bytes to use in
       SwitchChannel().

  NOTE: because this really fires host-switch commands, if it succeeds your
  mouse WILL jump off this PC during the test. That's expected -- it's
  proof the codes work. Use the mouse's physical Easy-Switch button (or
  just wait) to bring it back, or run this same script on the other
  machine once the mouse arrives there.

.PARAMETER HidApiTester
  Path to hidapitester.exe. Defaults to a copy sitting next to this script.

.PARAMETER VidPid
  Vendor/Product ID filter passed to hidapitester (hex). Defaults to just
  the Logitech vendor ID (046D) so it matches most Logitech receivers.

.PARAMETER UsagePage
  HID usage page filter. Logitech's HID++ vendor collection is usually
  0xFF00 -- change this if Step 1's listing shows something else.

.PARAMETER MaxDeviceIndex
  Highest HID++ device index to probe (paired-device slot count). 6 covers
  Unifying/Bolt receivers; raise it if your receiver supports more.

.PARAMETER Apply
  On a confirmed switch, also patch the matching .ahk file(s) in place with
  the new bytes instead of just printing them. A one-time ".bak" backup of
  each file is made first (never overwritten if one already exists). Off by
  default -- pass this explicitly to opt in.

  By default only the essential lines are shown (what was found, the final result, and
  where to edit your .ahk file). Pass -Verbose to also see every combination and attempt
  it tried along the way.

.EXAMPLE
  .\find_channel_codes.ps1

.EXAMPLE
  .\find_channel_codes.ps1 -VidPid 046D:C548 -UsagePage 0xFF00

.EXAMPLE
  .\find_channel_codes.ps1 -Verbose

.EXAMPLE
  .\find_channel_codes.ps1 -Apply
#>

[CmdletBinding()]
param(
    [string]$HidApiTester = (Join-Path $PSScriptRoot "hidapitester.exe"),
    [string]$VidPid = "046D",
    [string]$UsagePage = "0xFF00",
    [int]$MaxDeviceIndex = 6,
    [int]$TimeoutMs = 400,
    [switch]$Apply
)

# HID++ 2.0 feature IDs known to relate to host/channel switching (from the
# public Logitech HID++ 2.0 spec, as catalogued by the Solaar project).
# CHANGE_HOST is what this project's MX Master 3 setup uses; the others are
# related pairing/host features seen on other devices/receivers. This is
# also the *safe list* -- the only features this script will ever send
# unsolicited commands to, since unrelated HID++ features can be destructive
# (device reset, DFU mode, ...) and guessing at those is not safe to automate.
# Plain @{} on purpose, not [ordered]@{}: OrderedDictionary's indexer treats
# an Int32 key as a *positional* lookup (it implements IOrderedDictionary),
# so with integer feature IDs as keys, $dict[0x1814] would silently try to
# return "the item at index 6164" instead of looking up the key -- returning
# nothing instead of the name, with no error. Plain Hashtable has no such
# ambiguity. Iteration order isn't relied on here; priority ordering happens
# explicitly via Sort-Object where it matters (Step 3).
$HostSwitchCandidateIds = @{
    0x1814 = "CHANGE_HOST"
    0x1815 = "HOSTS_INFO"
    0x1816 = "BLE_PRO_PRE_PAIRING"
    0x1500 = "FORCE_PAIRING"
}

# A few other common feature IDs, purely so the diagnostic full-table dump
# (when nothing on the safe list is found) is readable instead of a wall of
# bare hex. Not exhaustive -- unrecognized IDs just print as "(unknown)".
$KnownFeatureNames = @{
    0x0000 = "ROOT"
    0x0001 = "FEATURE_SET"
    0x0002 = "FEATURE_INFO"
    0x0003 = "DEVICE_FW_VERSION"
    0x0004 = "DEVICE_UNIT_ID"
    0x0005 = "DEVICE_NAME"
    0x0007 = "DEVICE_FRIENDLY_NAME"
    0x0008 = "KEEP_ALIVE"
    0x0020 = "CONFIG_CHANGE"
    0x00C0 = "DFUCONTROL_LEGACY"
    0x00C3 = "DFUCONTROL"
    0x00D0 = "DFU"
    0x1000 = "BATTERY_STATUS"
    0x1004 = "UNIFIED_BATTERY"
    0x1500 = "FORCE_PAIRING"
    0x1800 = "GENERIC_TEST"
    0x1802 = "DEVICE_RESET"
    0x1805 = "OOBSTATE"
    0x1806 = "CONFIG_DEVICE_PROPS"
    0x1814 = "CHANGE_HOST"
    0x1815 = "HOSTS_INFO"
    0x1816 = "BLE_PRO_PRE_PAIRING"
    0x1DF0 = "REMAINING_PAIRING"
    0x2001 = "LEFT_RIGHT_SWAP"
    0x2110 = "SMART_SHIFT"
    0x2111 = "SMART_SHIFT_ENHANCED"
    0x2121 = "HIRES_WHEEL"
    0x2201 = "ADJUSTABLE_DPI"
    0x2202 = "EXTENDED_ADJUSTABLE_DPI"
    0x2205 = "POINTER_SPEED"
}

if (-not (Test-Path $HidApiTester)) {
    Write-Error "hidapitester.exe not found at '$HidApiTester'. Download it from https://github.com/todbot/hidapitester/releases and place it next to this script, or pass -HidApiTester <path>."
    exit 1
}

# Fallback (usage, report length) used only if a caller doesn't specify one
# explicitly. Step 2 finds the real working combo per device index instead
# of relying on a single global value -- see $comboCandidates below.
$script:QueryUsage = ""
$script:QueryLength = 7

function Invoke-HidApiTester {
    param([string[]]$ArgList)
    & $HidApiTester @ArgList 2>&1 | Out-String
}

function Get-FilterArgs {
    param([string]$UsageValue)
    $filterArgs = @("--vidpid", $VidPid, "--usagePage", $UsagePage)
    if ($UsageValue -ne "") { $filterArgs += @("--usage", $UsageValue) }
    return $filterArgs
}

# Extracts the hex byte dump that follows hidapitester's "read N bytes:"
# line. Anchoring on a regex match (not a plain string search past "read ")
# matters: the byte count N itself is printed right there ("read 20 bytes:"),
# and for 20-byte reports "20" is itself a valid-looking 2-hex-digit token --
# a plain search would swallow it as a fake leading byte and misalign every
# byte after it. Matching the whole "read \d+ bytes:" phrase and starting
# just past it sidesteps that regardless of how many digits the count has.
function Get-HexBytesAfterMarker {
    param([string]$Text, [int]$Count)
    $readMatch = [regex]::Match($Text, 'read \d+ bytes:')
    if (-not $readMatch.Success) { return $null }
    $tail = $Text.Substring($readMatch.Index + $readMatch.Length)
    $hexMatches = [regex]::Matches($tail, '\b[0-9A-Fa-f]{2}\b')
    if ($hexMatches.Count -lt $Count) { return $null }
    $bytes = New-Object 'System.Collections.Generic.List[byte]'
    for ($i = 0; $i -lt $Count; $i++) {
        $bytes.Add([Convert]::ToByte($hexMatches[$i].Value, 16))
    }
    return $bytes
}

# Sends one HID++ 2.0 report and reads the reply, or $null on timeout.
# ReportLength 7 = "short" report (reportId 0x10, 3 param bytes);
# ReportLength 20 = "long" report (reportId 0x11, 16 param bytes). Which one
# a given device actually replies to for *queries* varies by hardware, and
# even by device index on the same receiver -- see $comboCandidates below.
function Send-HidPPRequest {
    param(
        [int]$DevIdx, [int]$FeatureIndex, [int]$FunctionByte,
        [int]$P1 = 0, [int]$P2 = 0, [int]$P3 = 0,
        [int]$ReportLength = $script:QueryLength,
        [string]$UsageValue = $script:QueryUsage
    )
    if ($ReportLength -eq 20) {
        $reportIdByte = "0x11"
        $paramCount = 16
    } else {
        $reportIdByte = "0x10"
        $paramCount = 3
    }
    $params = @($P1, $P2, $P3)
    while ($params.Count -lt $paramCount) { $params += 0 }
    $paramHex = ($params | ForEach-Object { "0x{0:X2}" -f $_ }) -join ","
    $request = "{0},0x{1:X2},0x{2:X2},0x{3:X2},{4}" -f $reportIdByte, $DevIdx, $FeatureIndex, $FunctionByte, $paramHex

    $probeArgs = (Get-FilterArgs -UsageValue $UsageValue) + @(
        "--open", "--length", $ReportLength,
        "--send-output", $request,
        "--timeout", $TimeoutMs,
        "--read-input",
        "--close"
    )
    $output = Invoke-HidApiTester -ArgList $probeArgs
    return Get-HexBytesAfterMarker -Text $output -Count $ReportLength
}

# True if a reply's header is a correctly addressed HID++ 2.0 response to our
# request -- either success (byte2 echoes the featureIndex we asked, e.g.
# 0x00 for a root request) or an explicit protocol error (byte2 = 0x8F).
# Either proves the (usage, length) combo and device index are genuinely
# talking HID++; only a raw timeout (which hidapitester still pads out to a
# zeroed buffer) means nothing is there.
function Test-ValidHidPPReply {
    param([array]$Response, [int]$DevIdx, [int]$ReportLength, [int]$RequestFeatureIndex)
    if ($null -eq $Response) { return $false }
    $expectedReportId = 0x10
    if ($ReportLength -eq 20) { $expectedReportId = 0x11 }
    return ($Response[0] -eq $expectedReportId) -and ($Response[1] -eq $DevIdx) -and (($Response[2] -eq $RequestFeatureIndex) -or ($Response[2] -eq 0x8F))
}

# True if a device index answers at all right now, via a given (usage,
# report length) combo -- root-feature ping (FEATURE_SET = 0x0001).
function Test-DeviceAlive {
    param([int]$DevIdx, [int]$ReportLength = $script:QueryLength, [string]$UsageValue = $script:QueryUsage)
    $response = Send-HidPPRequest -DevIdx $DevIdx -FeatureIndex 0x00 -FunctionByte 0x01 -P1 0x00 -P2 0x01 -ReportLength $ReportLength -UsageValue $UsageValue
    return Test-ValidHidPPReply -Response $response -DevIdx $DevIdx -ReportLength $ReportLength -RequestFeatureIndex 0x00
}

# root.getFeature(featureId) -> the feature's index on this device, or $null.
function Get-FeatureIndexFor {
    param([int]$DevIdx, [int]$FeatureId, [int]$ReportLength = $script:QueryLength, [string]$UsageValue = $script:QueryUsage)
    $response = Send-HidPPRequest -DevIdx $DevIdx -FeatureIndex 0x00 -FunctionByte 0x01 -P1 (($FeatureId -shr 8) -band 0xFF) -P2 ($FeatureId -band 0xFF) -ReportLength $ReportLength -UsageValue $UsageValue
    if (-not (Test-ValidHidPPReply -Response $response -DevIdx $DevIdx -ReportLength $ReportLength -RequestFeatureIndex 0x00)) { return $null }
    if ($response[2] -eq 0x00 -and $response[4] -ne 0x00) { return $response[4] }
    return $null
}

# FEATURE_SET.getCount() + getFeatureID(i) for every i -> full feature table.
function Get-FullFeatureTable {
    param([int]$DevIdx, [int]$ReportLength = $script:QueryLength, [string]$UsageValue = $script:QueryUsage)
    $fsIndex = Get-FeatureIndexFor -DevIdx $DevIdx -FeatureId 0x0001 -ReportLength $ReportLength -UsageValue $UsageValue
    if ($null -eq $fsIndex) { return $null }

    $countResp = Send-HidPPRequest -DevIdx $DevIdx -FeatureIndex $fsIndex -FunctionByte 0x01 -ReportLength $ReportLength -UsageValue $UsageValue
    if ($null -eq $countResp) { return $null }
    $count = $countResp[4]

    $table = @()
    for ($i = 1; $i -le $count; $i++) {
        $idResp = Send-HidPPRequest -DevIdx $DevIdx -FeatureIndex $fsIndex -FunctionByte 0x11 -P1 $i -ReportLength $ReportLength -UsageValue $UsageValue
        if ($null -ne $idResp) {
            $featureId = ($idResp[4] * 256) + $idResp[5]
            $table += [PSCustomObject]@{ FeatureIndex = $i; FeatureId = $featureId }
        }
    }
    return $table
}

# Parses hidapitester's --list-detail text output (one indented "key: value"
# block per device/collection, blank-line separated) into objects, so it
# displays as a readable table regardless of vendor/device -- this doesn't
# assume anything Logitech-specific.
function ConvertFrom-HidApiTesterListDetail {
    param([string]$Text)
    $devices = @()
    $blocks = [regex]::Split($Text.Trim(), '(?:\r?\n){2,}')
    foreach ($block in $blocks) {
        $lines = $block -split '\r?\n'
        if ($lines.Count -eq 0) { continue }
        $header = $lines[0]
        if ($header -notmatch '^([0-9A-Fa-f]{4}/[0-9A-Fa-f]{4}):\s*(.*)$') { continue }

        $fields = [ordered]@{ VidPid = $Matches[1]; Name = $Matches[2] }
        foreach ($line in $lines[1..($lines.Count - 1)]) {
            if ($line -match '^\s*([A-Za-z_]+)\s*:\s*(.*?)\s*$') {
                $fields[$Matches[1]] = $Matches[2]
            }
        }
        $devices += [PSCustomObject]$fields
    }
    return $devices
}

# Finds the SwitchChannel() byte-sequence line in a .ahk file next to this
# script and prints exactly what to change it to (or, with -Apply, actually
# makes the change). Only handles the common 7-byte-report case with a
# straight token swap (deviceIndex, featureIndex, functionByte -- the
# channel placeholder and surrounding zero bytes are left untouched);
# anything else gets pointed at the byte string printed above instead,
# since the file would need a bigger structural edit.
function Show-AhkFileInstructions {
    param([int]$DeviceIndex, [int]$FeatureIndex, [int]$FunctionByte, [int]$WriteLength, [bool]$DoApply = $false)

    $ahkFiles = Get-ChildItem -Path $PSScriptRoot -Filter "*.ahk" -File -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "=== Where to change it ===" -ForegroundColor Cyan
    if ($ahkFiles.Count -eq 0) {
        Write-Host "No .ahk files found next to this script -- update SwitchChannel() in yours by hand using the bytes above."
        return
    }

    if ($WriteLength -ne 7) {
        Write-Host "This project's .ahk scripts send SwitchChannel() as a 7-byte report; your working" -ForegroundColor Yellow
        Write-Host "command needs $WriteLength bytes instead, which is a bigger change than a simple byte swap"
        Write-Host "(the --length and the whole report layout differ) -- edit SwitchChannel() by hand using"
        Write-Host "the byte string printed above."
        return
    }

    $pattern = '0x10,0x[0-9A-Fa-f]{2},0x[0-9A-Fa-f]{2},0x[0-9A-Fa-f]{2},(0x\{[^,}]*\}),0x00,0x00'
    $newDevice = "0x{0:X2}" -f $DeviceIndex
    $newFeature = "0x{0:X2}" -f $FeatureIndex
    $newFunction = "0x{0:X2}" -f $FunctionByte

    foreach ($file in $ahkFiles) {
        $lines = Get-Content -LiteralPath $file.FullName
        $matchedLineNum = $null
        $oldSegment = $null
        $placeholder = $null
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $m = [regex]::Match($lines[$i], $pattern)
            if ($m.Success) {
                $matchedLineNum = $i + 1
                $oldSegment = $m.Value
                $placeholder = $m.Groups[1].Value
                break
            }
        }

        Write-Host ""
        if ($null -eq $matchedLineNum) {
            Write-Host "$($file.Name): couldn't find the SwitchChannel byte pattern automatically -- edit it by hand using the bytes above." -ForegroundColor Yellow
            continue
        }

        $newSegment = "0x10,$newDevice,$newFeature,$newFunction,$placeholder,0x00,0x00"

        Write-Host "$($file.Name), line ${matchedLineNum}, inside SwitchChannel():" -ForegroundColor Green
        Write-Host "  old: $oldSegment"
        Write-Host "  new: $newSegment" -ForegroundColor Green

        if ($DoApply) {
            $backupPath = "$($file.FullName).bak"
            if (-not (Test-Path $backupPath)) {
                Copy-Item -LiteralPath $file.FullName -Destination $backupPath
            }
            # -Raw preserves the file's exact line endings/trailing newline; the
            # replacement is passed via a MatchEvaluator so $ characters in
            # $newSegment are never misread as regex backreferences.
            $content = Get-Content -LiteralPath $file.FullName -Raw
            $updated = [regex]::Replace($content, [regex]::Escape($oldSegment), { $newSegment }, 1)
            Set-Content -LiteralPath $file.FullName -Value $updated -NoNewline
            Write-Host "  Applied. Backup saved to $backupPath" -ForegroundColor Green
        }

        $currentVidPid = $null
        foreach ($line in $lines) {
            $vpMatch = [regex]::Match($line, 'ReceiverVidPid\s*:?=\s*"([^"]+)"')
            if ($vpMatch.Success) { $currentVidPid = $vpMatch.Groups[1].Value; break }
        }
        if ($null -ne $currentVidPid) {
            Write-Host "  Also double check ReceiverVidPid := `"$currentVidPid`" near the top of the file matches your receiver from Step 1 above."
        }
    }
}

Write-Host "=== Step 1: HID collections matching vid $VidPid ===" -ForegroundColor Cyan
$listOutput = Invoke-HidApiTester -ArgList @("--vidpid", $VidPid, "--list-detail")
$devices = ConvertFrom-HidApiTesterListDetail -Text $listOutput
if ($devices.Count -gt 0) {
    $devices | Format-Table VidPid, Name, usagePage, usage, interface -AutoSize | Out-String | Write-Host
} else {
    Write-Host "(none found -- if that's wrong, re-run with -VidPid / -UsagePage adjusted)" -ForegroundColor Yellow
    Write-Verbose $listOutput
}
Write-Host ""

# (usage, report length) combinations to try. Different devices/receivers
# need different ones for *query* commands, and -- as this project's own
# hardware turned out to demonstrate -- even different device indices on the
# very same receiver can require different combos (the receiver's own
# pseudo-index 0xFF answers short reports while an actual paired device
# answers only long ones, or vice versa). So this isn't detected once
# up front; each device index below finds its own working combo.
$comboCandidates = @(
    @{ Usage = "0x0002"; Length = 20 }
    @{ Usage = "0x0001"; Length = 7 }
    @{ Usage = "0x0001"; Length = 20 }
    @{ Usage = "0x0002"; Length = 7 }
    @{ Usage = "0x0004"; Length = 20 }
    @{ Usage = "0x0004"; Length = 7 }
    @{ Usage = ""; Length = 7 }
    @{ Usage = ""; Length = 20 }
)
$script:lastWorkingCombo = $null

function Get-OrderedCombos {
    if ($null -eq $script:lastWorkingCombo) { return $comboCandidates }
    $rest = $comboCandidates | Where-Object { -not ($_.Usage -eq $script:lastWorkingCombo.Usage -and $_.Length -eq $script:lastWorkingCombo.Length) }
    return @($script:lastWorkingCombo) + $rest
}

function Format-ComboLabel {
    param($Combo)
    $usageLabel = $Combo.Usage
    if ($usageLabel -eq "") { $usageLabel = "(unfiltered)" }
    return "usage $usageLabel, $($Combo.Length)-byte reports"
}

Write-Host "=== Step 2: scanning device indices 1..$MaxDeviceIndex for known host-switch features ===" -ForegroundColor Cyan
Write-Verbose "For each device index, tries (usage, HID++ report length) combinations until one gets a real reply -- a single -UsagePage can match several collections, and which one answers *queries* varies by device (short 7-byte vs. long 20-byte reports), sometimes even per device index."
$found = @()
$respondingIndices = @()

for ($devIdx = 1; $devIdx -le $MaxDeviceIndex; $devIdx++) {
    $workingCombo = $null
    foreach ($combo in (Get-OrderedCombos)) {
        $response = Send-HidPPRequest -DevIdx $devIdx -FeatureIndex 0x00 -FunctionByte 0x01 -P1 0x00 -P2 0x01 -ReportLength $combo.Length -UsageValue $combo.Usage
        if (Test-ValidHidPPReply -Response $response -DevIdx $devIdx -ReportLength $combo.Length -RequestFeatureIndex 0x00) {
            $workingCombo = $combo
            $script:lastWorkingCombo = $combo
            break
        }
    }

    if ($null -eq $workingCombo) {
        Write-Verbose ("Device index {0}: no response on any (usage, report length) combination" -f $devIdx)
        continue
    }

    $respondingIndices += [PSCustomObject]@{ DeviceIndex = $devIdx; Combo = $workingCombo }
    $hits = @()
    foreach ($featureId in $HostSwitchCandidateIds.Keys) {
        $featureIndex = Get-FeatureIndexFor -DevIdx $devIdx -FeatureId $featureId -ReportLength $workingCombo.Length -UsageValue $workingCombo.Usage
        if ($null -ne $featureIndex) {
            $hits += [PSCustomObject]@{ DeviceIndex = $devIdx; FeatureIndex = $featureIndex; FeatureId = $featureId; Name = $HostSwitchCandidateIds[$featureId]; Usage = $workingCombo.Usage; Length = $workingCombo.Length }
        }
    }

    if ($hits.Count -gt 0) {
        foreach ($hit in $hits) {
            Write-Host ("Device index {0} ({1}): {2} (0x{3:X4}) found at feature index 0x{4:X2}" -f $hit.DeviceIndex, (Format-ComboLabel $workingCombo), $hit.Name, $hit.FeatureId, $hit.FeatureIndex) -ForegroundColor Green
            $found += $hit
        }
    } else {
        Write-Verbose ("Device index {0} ({1}): responded, but none of the known host-switch features matched" -f $devIdx, (Format-ComboLabel $workingCombo))
    }
}

if ($found.Count -eq 0) {
    if ($respondingIndices.Count -eq 0) {
        Write-Host ""
        Write-Host "No device responded on any index 1..$MaxDeviceIndex." -ForegroundColor Yellow
        Write-Host "Adjust -VidPid / -UsagePage using the Step 1 listing above, or raise -MaxDeviceIndex."
        exit 1
    }

    Write-Host ""
    Write-Host "=== Diagnostic: none of the known safe feature IDs matched -- full feature tables ===" -ForegroundColor Cyan
    Write-Host "This script only ever sends commands to the known host-switch feature list above --"
    Write-Host "not to arbitrary features below, since some HID++ features (device reset, DFU mode, ...)"
    Write-Host "are destructive and guessing at those isn't safe to automate."
    Write-Host ""

    foreach ($responding in $respondingIndices) {
        Write-Host ("--- Device index {0} ({1}) ---" -f $responding.DeviceIndex, (Format-ComboLabel $responding.Combo))
        $table = Get-FullFeatureTable -DevIdx $responding.DeviceIndex -ReportLength $responding.Combo.Length -UsageValue $responding.Combo.Usage
        if ($null -eq $table -or $table.Count -eq 0) {
            Write-Host "  (couldn't enumerate -- FEATURE_SET not found or didn't respond)" -ForegroundColor DarkGray
            continue
        }
        foreach ($row in $table) {
            $name = $KnownFeatureNames[[int]$row.FeatureId]
            if ($null -eq $name) { $name = "(unknown)" }
            Write-Host ("  feature index 0x{0:X2} = 0x{1:X4} {2}" -f $row.FeatureIndex, $row.FeatureId, $name)
        }
    }

    Write-Host ""
    Write-Host "No known-safe host-switch feature found. If one of the '(unknown)' entries above looks" -ForegroundColor Yellow
    Write-Host "plausible, you can extend `$HostSwitchCandidateIds at the top of this script and re-run,"
    Write-Host "or open an issue on the repo with the table above."
    exit 1
}

Write-Host ""
Write-Host "=== Step 3: autonomously testing candidates ===" -ForegroundColor Cyan
Write-Host "This sends real 'switch host' commands. Success is detected by the device going silent on" -ForegroundColor Yellow
Write-Host "this receiver right after a command (i.e. it actually jumped elsewhere) -- if it works, your" -ForegroundColor Yellow
Write-Host "mouse WILL disconnect from this PC. Use its physical Easy-Switch button (or just wait) to" -ForegroundColor Yellow
Write-Host "bring it back, or run this script on the other machine once it arrives there." -ForegroundColor Yellow
Write-Host ""

# CHANGE_HOST's switch function is known (function 1, from this project's own
# reverse-engineering). HOSTS_INFO's isn't documented publicly (Solaar itself
# doesn't implement switching), so function 2 -- the gap between HOSTS_INFO's
# known getHostInfo(1)/getHostName(3)/setHostName(4) -- is tried first as the
# best guess, followed by the others as a general fallback.
$defaultFunctionOrder = @(1, 2, 3, 4)
$orderedCandidates = $found | Sort-Object -Property @{Expression = { $_.FeatureId -eq 0x1814 }; Descending = $true }, @{Expression = { $_.FeatureId -eq 0x1815 }; Descending = $true }

# Try the *write* command with both report lengths: many devices (like this
# project's original MX Master 3 setup) only need short 7-byte reports for a
# one-way "set" command even when queries required long 20-byte ones, but
# that's not guaranteed for every device, so both are attempted.
$writeLengthOrder = @(7, 20)

foreach ($candidate in $orderedCandidates) {
    Write-Verbose ("Candidate: device index {0}, feature index 0x{1:X2} ({2})" -f $candidate.DeviceIndex, $candidate.FeatureIndex, $candidate.Name)

    $functionOrder = $defaultFunctionOrder
    if ($candidate.FeatureId -eq 0x1815) { $functionOrder = @(2, 1, 3, 4) }

    foreach ($fn in $functionOrder) {
        $functionByte = ($fn * 16) + 1   # function nibble | swID (swID = 1, arbitrary)

        foreach ($writeLength in $writeLengthOrder) {
            foreach ($channel in @(1, 2, 3)) {
                $channelByte = $channel - 1

                if (-not (Test-DeviceAlive -DevIdx $candidate.DeviceIndex -ReportLength $candidate.Length -UsageValue $candidate.Usage)) {
                    Write-Verbose ("  device index {0} stopped responding -- it may have already switched; skipping remaining tries for it" -f $candidate.DeviceIndex)
                    break
                }

                Write-Verbose ("  trying function {0} (byte 0x{1:X2}), {2}-byte report, channel {3}..." -f $fn, $functionByte, $writeLength, $channel)
                # The write itself always goes out via the unfiltered usage (matches
                # this project's proven production convention); only the length varies.
                Send-HidPPRequest -DevIdx $candidate.DeviceIndex -FeatureIndex $candidate.FeatureIndex -FunctionByte $functionByte -P1 $channelByte -ReportLength $writeLength -UsageValue "" | Out-Null
                Start-Sleep -Milliseconds 500

                if (-not (Test-DeviceAlive -DevIdx $candidate.DeviceIndex -ReportLength $candidate.Length -UsageValue $candidate.Usage)) {
                    Write-Host ""
                    Write-Host "Success -- device index $($candidate.DeviceIndex) went silent right after that command, meaning it switched." -ForegroundColor Green
                    Write-Host "Use this in SwitchChannel() in your .ahk script:" -ForegroundColor Green
                    if ($writeLength -eq 20) {
                        Write-Host ("  0x11,0x{0:X2},0x{1:X2},0x{2:X2},0x<channel>,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00" -f $candidate.DeviceIndex, $candidate.FeatureIndex, $functionByte) -ForegroundColor Green
                        Write-Host "  (--length 20 in the --send-output command)"
                    } else {
                        Write-Host ("  0x10,0x{0:X2},0x{1:X2},0x{2:X2},0x<channel>,0x00,0x00" -f $candidate.DeviceIndex, $candidate.FeatureIndex, $functionByte) -ForegroundColor Green
                        Write-Host "  (--length 7 in the --send-output command)"
                    }
                    Write-Host "  (replace 0x<channel> with 0x00 / 0x01 / 0x02 for channel 1 / 2 / 3, and update ReceiverVidPid to match your receiver)"
                    Show-AhkFileInstructions -DeviceIndex $candidate.DeviceIndex -FeatureIndex $candidate.FeatureIndex -FunctionByte $functionByte -WriteLength $writeLength -DoApply $Apply.IsPresent
                    exit 0
                }
            }
        }
    }
}

Write-Host ""
Write-Host "None of the known-safe candidates caused a switch." -ForegroundColor Yellow
Write-Host "Double check the mouse has multi-host/Easy-Switch enabled and is actually paired on this"
Write-Host "receiver, or try a wider -MaxDeviceIndex. If it's still stuck, temporarily comment out the"
Write-Host "matches from `$HostSwitchCandidateIds at the top of this script and re-run -- with nothing on"
Write-Host "the safe list left to find, it will fall back to printing the full feature table instead, so"
Write-Host "you can look for a candidate this script didn't think to try."
