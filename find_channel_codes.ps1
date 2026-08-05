<#
.SYNOPSIS
  Discovers the HID++ 2.0 feature index used for host/channel switching on a
  Logitech multi-host mouse/receiver pair, so you can adapt SwitchChannel()
  in mouse_jumper.ahk / mouse_jumper_v2.ahk to your own hardware.

.DESCRIPTION
  This project's default byte codes (device index 1 or 2, feature index
  0x0A) were found on a Logitech MX Master 3 paired to a Logitech receiver
  (VID:PID 046D:C52B). Other mice/receivers are very likely to need
  different values, because the HID++ "feature table" (which slot a given
  feature lands on) is assigned per firmware/pairing, not fixed across
  hardware -- and some receivers don't even expose the same feature.

  This script automates the discovery instead of requiring a USB sniffer,
  and doesn't assume anything about which exact mouse/receiver you have:
    1. Lists the matching HID collections as a table (VID:PID, usagePage,
       usage, interface), so you can confirm what's actually connected.
    2. Auto-detects which usage on that usagePage is the live HID++ channel
       (a single usagePage often has several collections, e.g. short vs.
       long HID++ reports, and only one answers).
    3. Quick-checks each device index for the two features known to relate
       to host switching: CHANGE_HOST (0x1814, used by this project's
       original MX Master 3 setup) and HOSTS_INFO (0x1815, used on newer
       receivers/devices).
    4. If neither is found anywhere, falls back to dumping the *entire*
       HID++ feature table of every responding device index, so you can
       identify the right feature even if it's neither of the above.
    5. Lets you brute-force a small set of likely function numbers against
       a chosen device/feature index combo, firing a real "switch to
       channel N" command after each try so you can visually confirm the
       mouse actually jumps before committing the values into your .ahk
       script.

.PARAMETER HidApiTester
  Path to hidapitester.exe. Defaults to a copy sitting next to this script.

.PARAMETER VidPid
  Vendor/Product ID filter passed to hidapitester (hex). Defaults to just
  the Logitech vendor ID (046D) so it matches most Logitech receivers.

.PARAMETER UsagePage
  HID usage page filter. Logitech's HID++ vendor collection is usually
  0xFF00 -- change this if Step 1's listing shows something else.

.PARAMETER Usage
  HID usage filter. Left empty by default, the script auto-detects it by
  trying the common candidates (0x0001 "short" reports, 0x0002 "long",
  0x0004) against your receiver and locking onto whichever one actually
  answers -- a single -usagePage can match several collections (e.g. short
  vs. long HID++ reports) and only one of them is the right one to use.
  Pass this explicitly to skip auto-detection.

.PARAMETER MaxDeviceIndex
  Highest HID++ device index to probe (paired-device slot count). 6 covers
  Unifying/Bolt receivers; raise it if your receiver supports more.

.EXAMPLE
  .\find_channel_codes.ps1

.EXAMPLE
  .\find_channel_codes.ps1 -VidPid 046D:C548 -UsagePage 0xFF00 -Usage 0x0001
#>

param(
    [string]$HidApiTester = (Join-Path $PSScriptRoot "hidapitester.exe"),
    [string]$VidPid = "046D",
    [string]$UsagePage = "0xFF00",
    [string]$Usage = "",
    [int]$MaxDeviceIndex = 6,
    [int]$TimeoutMs = 400
)

# HID++ 2.0 feature IDs relevant to host/channel switching (from the public
# Logitech HID++ 2.0 spec, as catalogued by the Solaar project). CHANGE_HOST
# is what this project's MX Master 3 setup uses; HOSTS_INFO is a newer,
# related feature seen on other devices/receivers.
$HostSwitchCandidateIds = [ordered]@{
    0x1814 = "CHANGE_HOST"
    0x1815 = "HOSTS_INFO"
    0x1816 = "BLE_PRO_PRE_PAIRING"
    0x1500 = "FORCE_PAIRING"
}

# A few other common feature IDs, purely so the full-table dump (Step 3) is
# readable instead of a wall of bare hex. Not exhaustive -- unrecognized IDs
# just print as "(unknown)", which is still perfectly usable.
$KnownFeatureNames = [ordered]@{
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

function Invoke-HidApiTester {
    param([string[]]$ArgList)
    & $HidApiTester @ArgList 2>&1 | Out-String
}

function Get-OpenFilterArgs {
    $filterArgs = @("--vidpid", $VidPid, "--usagePage", $UsagePage)
    if ($Usage -ne "") { $filterArgs += @("--usage", $Usage) }
    return $filterArgs
}

function Get-HexBytesAfterMarker {
    param([string]$Text, [string]$Marker, [int]$Count)
    $idx = $Text.IndexOf($Marker)
    if ($idx -lt 0) { return $null }
    $tail = $Text.Substring($idx + $Marker.Length)
    $hexMatches = [regex]::Matches($tail, '\b[0-9A-Fa-f]{2}\b')
    if ($hexMatches.Count -lt $Count) { return $null }
    $bytes = New-Object 'System.Collections.Generic.List[byte]'
    for ($i = 0; $i -lt $Count; $i++) {
        $bytes.Add([Convert]::ToByte($hexMatches[$i].Value, 16))
    }
    return $bytes
}

# Sends a HID++ 2.0 short report and reads the 7-byte reply, or $null on timeout.
function Send-HidPPRequest {
    param([int]$DevIdx, [int]$FeatureIndex, [int]$FunctionByte, [int]$P1 = 0, [int]$P2 = 0, [int]$P3 = 0)
    $request = "0x10,0x{0:X2},0x{1:X2},0x{2:X2},0x{3:X2},0x{4:X2},0x{5:X2}" -f $DevIdx, $FeatureIndex, $FunctionByte, $P1, $P2, $P3
    $probeArgs = (Get-OpenFilterArgs) + @(
        "--open", "--length", "7",
        "--send-output", $request,
        "--timeout", $TimeoutMs,
        "--read-input",
        "--close"
    )
    $output = Invoke-HidApiTester -ArgList $probeArgs
    return Get-HexBytesAfterMarker -Text $output -Marker "read " -Count 7
}

# root.getFeature(featureId) -> the feature's index on this device, or $null.
function Get-FeatureIndexFor {
    param([int]$DevIdx, [int]$FeatureId)
    $response = Send-HidPPRequest -DevIdx $DevIdx -FeatureIndex 0x00 -FunctionByte 0x01 -P1 (($FeatureId -shr 8) -band 0xFF) -P2 ($FeatureId -band 0xFF)
    if ($null -eq $response) { return $null }
    if ($response[0] -eq 0x10 -and $response[1] -eq $DevIdx -and $response[2] -eq 0x00 -and $response[4] -ne 0x00) {
        return $response[4]
    }
    return $null
}

# FEATURE_SET.getCount() + getFeatureID(i) for every i -> full feature table.
function Get-FullFeatureTable {
    param([int]$DevIdx)
    $fsIndex = Get-FeatureIndexFor -DevIdx $DevIdx -FeatureId 0x0001
    if ($null -eq $fsIndex) { return $null }

    $countResp = Send-HidPPRequest -DevIdx $DevIdx -FeatureIndex $fsIndex -FunctionByte 0x01
    if ($null -eq $countResp) { return $null }
    $count = $countResp[4]

    $table = @()
    for ($i = 1; $i -le $count; $i++) {
        $idResp = Send-HidPPRequest -DevIdx $DevIdx -FeatureIndex $fsIndex -FunctionByte 0x11 -P1 $i
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

Write-Host "=== Step 1: HID collections matching vid $VidPid ===" -ForegroundColor Cyan
$listOutput = Invoke-HidApiTester -ArgList @("--vidpid", $VidPid, "--list-detail")
$devices = ConvertFrom-HidApiTesterListDetail -Text $listOutput
if ($devices.Count -gt 0) {
    $devices | Format-Table VidPid, Name, usagePage, usage, interface -AutoSize | Out-String | Write-Host
} else {
    Write-Host "(none found -- raw hidapitester output below)"
    Write-Host $listOutput
}
Write-Host "If your receiver isn't listed, or nothing responds below, re-run with -VidPid / -UsagePage adjusted to match what's shown above."
Write-Host ""

if ($Usage -eq "") {
    Write-Host "=== Step 1b: auto-detecting which HID usage actually answers HID++ ===" -ForegroundColor Cyan
    Write-Host "A single -UsagePage can match several collections (e.g. short vs. long HID++ reports);"
    Write-Host "probing each candidate with a harmless root-feature ping to find the live one."
    $usageCandidates = @("0x0001", "0x0002", "0x0004")
    $pickedUsage = $null
    foreach ($candidateUsage in $usageCandidates) {
        $Usage = $candidateUsage
        # Root-feature ping for FEATURE_SET (0x0001) on device index 1. Any correctly
        # addressed 7-byte reply -- even "feature not found" -- proves this usage/collection
        # is the live HID++ channel; a fully unrelated collection just times out instead.
        $rawProbe = Send-HidPPRequest -DevIdx 1 -FeatureIndex 0x00 -FunctionByte 0x01 -P1 0x00 -P2 0x01
        $isAlive = ($null -ne $rawProbe) -and ($rawProbe[0] -eq 0x10) -and ($rawProbe[1] -eq 1) -and ($rawProbe[2] -eq 0x00)
        if ($isAlive) {
            Write-Host ("  usage {0}: responds -- using this one" -f $candidateUsage) -ForegroundColor Green
            $pickedUsage = $candidateUsage
            break
        } else {
            Write-Host ("  usage {0}: no response" -f $candidateUsage) -ForegroundColor DarkGray
        }
    }
    if ($null -eq $pickedUsage) {
        Write-Host "  none of the common usages responded on device index 1 -- leaving usage unfiltered and hoping for the best." -ForegroundColor Yellow
        $Usage = ""
    }
    Write-Host ""
}

Write-Host "=== Step 2: probing device indices 1..$MaxDeviceIndex for known host-switch features ===" -ForegroundColor Cyan
$found = @()
$respondingIndices = @()

for ($devIdx = 1; $devIdx -le $MaxDeviceIndex; $devIdx++) {
    $hits = @()

    foreach ($featureId in $HostSwitchCandidateIds.Keys) {
        $featureIndex = Get-FeatureIndexFor -DevIdx $devIdx -FeatureId $featureId
        if ($null -ne $featureIndex) {
            $hits += [PSCustomObject]@{ DeviceIndex = $devIdx; FeatureIndex = $featureIndex; FeatureId = $featureId; Name = $HostSwitchCandidateIds[$featureId] }
        }
    }

    if ($hits.Count -gt 0) {
        $respondingIndices += $devIdx
        foreach ($hit in $hits) {
            Write-Host ("Device index {0}: {1} (0x{2:X4}) found at feature index 0x{3:X2}" -f $hit.DeviceIndex, $hit.Name, $hit.FeatureId, $hit.FeatureIndex) -ForegroundColor Green
            $found += $hit
        }
    } else {
        # Distinguish "device present but none of our candidate features matched"
        # from "nothing there at all", by probing the always-present root feature.
        $rootProbe = Get-FeatureIndexFor -DevIdx $devIdx -FeatureId 0x0001
        if ($null -ne $rootProbe) {
            $respondingIndices += $devIdx
            Write-Host ("Device index {0}: responded, but none of the known host-switch features matched" -f $devIdx) -ForegroundColor DarkGray
        } else {
            Write-Host ("Device index {0}: no response" -f $devIdx) -ForegroundColor DarkGray
        }
    }
}

if ($found.Count -eq 0) {
    if ($respondingIndices.Count -eq 0) {
        Write-Host ""
        Write-Host "No device responded on any index 1..$MaxDeviceIndex." -ForegroundColor Yellow
        Write-Host "Adjust -VidPid / -UsagePage / -Usage using the Step 1 listing above, or raise -MaxDeviceIndex."
        exit 1
    }

    Write-Host ""
    Write-Host "=== Step 3: none of the known feature IDs matched -- dumping full feature tables ===" -ForegroundColor Cyan
    Write-Host "Look for anything pairing/host-related; '(unknown)' entries can still be tried in Step 4 below."
    Write-Host ""

    foreach ($devIdx in $respondingIndices) {
        Write-Host ("--- Device index {0} ---" -f $devIdx)
        $table = Get-FullFeatureTable -DevIdx $devIdx
        if ($null -eq $table -or $table.Count -eq 0) {
            Write-Host "  (couldn't enumerate -- FEATURE_SET not found or didn't respond)" -ForegroundColor DarkGray
            continue
        }
        foreach ($row in $table) {
            $name = $KnownFeatureNames[[int]$row.FeatureId]
            if ($null -eq $name) { $name = "(unknown)" }
            $marker = ""
            if ($HostSwitchCandidateIds.Contains([int]$row.FeatureId)) { $marker = "  <-- known host-switch feature" }
            Write-Host ("  feature index 0x{0:X2} = 0x{1:X4} {2}{3}" -f $row.FeatureIndex, $row.FeatureId, $name, $marker)
            if ($marker -ne "") {
                $found += [PSCustomObject]@{ DeviceIndex = $devIdx; FeatureIndex = $row.FeatureIndex; FeatureId = $row.FeatureId; Name = $name }
            }
        }
    }

    if ($found.Count -eq 0) {
        Write-Host ""
        Write-Host "None of the responding devices exposed a recognized host-switch feature." -ForegroundColor Yellow
        Write-Host "Pick a plausible-looking row from the tables above (e.g. an '(unknown)' entry with a small"
        Write-Host "index, since pairing/host features tend to sit early in the table) and try it manually in Step 4."
        $chosenDev = Read-Host "Enter a device index to try"
        $chosenFeature = Read-Host "Enter a feature index to try (hex, e.g. 0A)"
        $found = @([PSCustomObject]@{ DeviceIndex = [int]$chosenDev; FeatureIndex = [Convert]::ToInt32($chosenFeature, 16); FeatureId = 0; Name = "(manual)" })
    }
}

Write-Host ""
Write-Host "=== Step 4: test candidates ===" -ForegroundColor Cyan
Write-Host "For each candidate, this tries a small set of likely function numbers, sending a real"
Write-Host "'switch to channel' command after each one so you can watch whether the mouse jumps."
Write-Host ""

# CHANGE_HOST's switch function is known (function 1, from this project's own
# reverse-engineering). HOSTS_INFO's isn't documented publicly (Solaar itself
# doesn't implement switching), so function 2 -- the gap between HOSTS_INFO's
# known getHostInfo(1)/getHostName(3)/setHostName(4) -- is tried first as the
# best guess, followed by the others as a general fallback.
$defaultFunctionOrder = @(1, 2, 3, 4)

foreach ($candidate in ($found | Sort-Object -Property @{Expression = { $_.FeatureId -eq 0x1814 }; Descending = $true }, @{Expression = { $_.FeatureId -eq 0x1815 }; Descending = $true })) {
    Write-Host ("Candidate: device index {0}, feature index 0x{1:X2} ({2})" -f $candidate.DeviceIndex, $candidate.FeatureIndex, $candidate.Name)
    $tryIt = Read-Host "  Test this candidate? (y/N)"
    if ($tryIt -ne "y" -and $tryIt -ne "Y") { continue }

    $channel = Read-Host "  Channel to switch to (1, 2 or 3)"
    $channelByte = [int]$channel - 1

    $functionOrder = $defaultFunctionOrder
    if ($candidate.FeatureId -eq 0x1815) { $functionOrder = @(2, 1, 3, 4) }

    foreach ($fn in $functionOrder) {
        $functionByte = ($fn * 16) + 1   # function nibble | swID (swID = 1, arbitrary)
        Write-Host ("  Trying function {0} (byte 0x{1:X2})..." -f $fn, $functionByte)
        Send-HidPPRequest -DevIdx $candidate.DeviceIndex -FeatureIndex $candidate.FeatureIndex -FunctionByte $functionByte -P1 $channelByte | Out-Null

        $worked = Read-Host "  Did the mouse switch to channel $channel? (y/N/stop)"
        if ($worked -eq "stop") { break }
        if ($worked -eq "y" -or $worked -eq "Y") {
            Write-Host ""
            Write-Host "Found it! Use this in SwitchChannel() in your .ahk script:" -ForegroundColor Green
            Write-Host ("  0x10,0x{0:X2},0x{1:X2},0x{2:X2},0x<channel>,0x00,0x00" -f $candidate.DeviceIndex, $candidate.FeatureIndex, $functionByte) -ForegroundColor Green
            Write-Host "  (replace 0x<channel> with 0x00 / 0x01 / 0x02 for channel 1 / 2 / 3, and update ReceiverVidPid to match your receiver)"
            exit 0
        }
    }
}

Write-Host ""
Write-Host "No candidate confirmed a switch. Re-run with a wider -MaxDeviceIndex, double check the mouse" -ForegroundColor Yellow
Write-Host "has multi-host/Easy-Switch enabled and is actually paired on this receiver, or inspect the full"
Write-Host "feature tables above for a candidate this script didn't think to flag."
