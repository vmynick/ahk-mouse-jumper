<#
.SYNOPSIS
  Discovers the HID++ 2.0 "Change Host" feature index for a Logitech
  multi-host mouse/receiver pair, so you can adapt SwitchChannel() in
  mouse_jumper.ahk / mouse_jumper_v2.ahk to your own hardware.

.DESCRIPTION
  This project's default byte codes (device index 1 or 2, feature index
  0x0A) were found on a Logitech MX Master 3 paired to a Logitech receiver
  (VID:PID 046D:C52B). Other mice/receivers are very likely to need a
  different device index and/or feature index, because the HID++ "feature
  table" is assigned per firmware/pairing, not fixed across hardware.

  This script automates the discovery instead of requiring a USB sniffer:
    1. Lists the Logitech HID collections it can see, so you can confirm
       VID:PID / usagePage / usage.
    2. Sends a HID++ 2.0 root "getFeature(0x1814)" request (0x1814 = the
       "Change Host" feature ID) to each candidate device index, and reads
       the reply to find which device index/feature index combo supports it.
    3. Lets you fire a real "switch to channel N" command against a
       candidate, so you can visually confirm the mouse actually jumps
       before you commit the values into your .ahk script.

.PARAMETER HidApiTester
  Path to hidapitester.exe. Defaults to a copy sitting next to this script.

.PARAMETER VidPid
  Vendor/Product ID filter passed to hidapitester (hex). Defaults to just
  the Logitech vendor ID (046D) so it matches most Logitech receivers.

.PARAMETER UsagePage
  HID usage page filter. Logitech's HID++ vendor collection is usually
  0xFF00 -- change this if Step 1's listing shows something else.

.PARAMETER Usage
  Optional HID usage filter, only needed if -UsagePage alone matches more
  than one collection on your receiver.

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

# HID++ 2.0 feature ID for "Change Host" (the multi-host channel-switch feature)
$ChangeHostFeatureId = @(0x18, 0x14)

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

Write-Host "=== Step 1: Logitech HID collections matching vid $VidPid ===" -ForegroundColor Cyan
Write-Host (Invoke-HidApiTester -ArgList @("--vidpid", $VidPid, "--list-detail"))
Write-Host "If your receiver isn't listed, or Step 2 below fails to open a device, re-run with -VidPid / -UsagePage / -Usage adjusted to match what's shown above."
Write-Host ""

Write-Host "=== Step 2: probing device indices 1..$MaxDeviceIndex for the 'Change Host' feature (0x1814) ===" -ForegroundColor Cyan
$found = @()

for ($devIdx = 1; $devIdx -le $MaxDeviceIndex; $devIdx++) {
    # HID++ 2.0 short report: reportId, deviceIndex, featureIndex(0=root), function<<4|swID, params...
    # Function 0 of the root feature is "getFeature(featureId)".
    $request = "0x10,0x{0:X2},0x00,0x01,0x{1:X2},0x{2:X2},0x00" -f $devIdx, $ChangeHostFeatureId[0], $ChangeHostFeatureId[1]

    $probeArgs = (Get-OpenFilterArgs) + @(
        "--open", "--length", "7",
        "--send-output", $request,
        "--timeout", $TimeoutMs,
        "--read-input",
        "--close"
    )

    $output = Invoke-HidApiTester -ArgList $probeArgs
    $response = Get-HexBytesAfterMarker -Text $output -Marker "read " -Count 7

    if ($null -eq $response) {
        Write-Host ("Device index {0}: no response" -f $devIdx) -ForegroundColor DarkGray
        continue
    }

    # A successful getFeature reply echoes reportId/deviceIndex/rootFeatureIndex(0x00)/function|swID
    # in bytes 0-3, and returns the discovered feature index in byte 4 (0x00 = not supported here).
    if ($response[0] -eq 0x10 -and $response[1] -eq $devIdx -and $response[2] -eq 0x00 -and $response[4] -ne 0x00) {
        $featureIndex = $response[4]
        Write-Host ("Device index {0}: Change Host feature found at index 0x{1:X2}" -f $devIdx, $featureIndex) -ForegroundColor Green
        $found += [PSCustomObject]@{ DeviceIndex = $devIdx; FeatureIndex = $featureIndex }
    } else {
        Write-Host ("Device index {0}: responded, but Change Host not supported there" -f $devIdx) -ForegroundColor DarkGray
    }
}

if ($found.Count -eq 0) {
    Write-Host ""
    Write-Host "No 'Change Host' feature found on any device index 1..$MaxDeviceIndex." -ForegroundColor Yellow
    Write-Host "Things to try: increase -MaxDeviceIndex, adjust -UsagePage/-Usage using the Step 1 listing above,"
    Write-Host "or confirm your mouse actually has multi-host/Easy-Switch support and is paired to this receiver."
    exit 1
}

Write-Host ""
Write-Host "=== Step 3: test an actual switch ===" -ForegroundColor Cyan
foreach ($candidate in $found) {
    Write-Host ("Candidate: device index {0}, feature index 0x{1:X2}" -f $candidate.DeviceIndex, $candidate.FeatureIndex)
}

$chosenDev = Read-Host "Enter the device index to test"
$chosenFeature = Read-Host "Enter the feature index to test (hex, e.g. 0A)"
$chosenChannel = Read-Host "Enter the channel to switch to (1, 2 or 3)"

$channelByte = [int]$chosenChannel - 1
# Function 1 of the Change Host feature is "setCurrentHost(channel)"; swID nibble is arbitrary.
$testCmd = "0x10,0x{0:X2},0x{1:X2},0x11,0x{2:X2},0x00,0x00" -f [int]$chosenDev, [Convert]::ToInt32($chosenFeature, 16), $channelByte

$testArgs = (Get-OpenFilterArgs) + @("--open", "--length", "7", "--send-output", $testCmd, "--close")
Write-Host "Sending: $testCmd"
Write-Host (Invoke-HidApiTester -ArgList $testArgs)
Write-Host "Did the mouse switch to channel $chosenChannel? If yes, use this in SwitchChannel() in your .ahk script:"
Write-Host ""
Write-Host ("  0x10,0x{0:X2},0x{1:X2},0x11,0x<channel>,0x00,0x00" -f [int]$chosenDev, [Convert]::ToInt32($chosenFeature, 16)) -ForegroundColor Green
Write-Host "  (replace 0x<channel> with 0x00 / 0x01 / 0x02 for channel 1 / 2 / 3, and update ReceiverVidPid to match your receiver)"
