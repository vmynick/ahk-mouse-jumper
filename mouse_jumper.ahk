#Persistent
#NoEnv
#SingleInstance Force
SetWorkingDir %A_ScriptDir%
SetBatchLines, -1                       ; Maximum execution speed

; Work around DPI scaling discrepancies
DllCall("SetThreadDpiAwarenessContext", "ptr", -3)

; ==============================================================================
; CONFIG FILE AND SETTINGS MANAGEMENT (.INI)
; ==============================================================================
global IniFile := A_ScriptDir . "\settings.ini"

; Load settings from file (falls back to defaults if missing)
IniRead, SavedPos, %IniFile%, Settings, Position, BOTTOM
IniRead, SavedChan, %IniFile%, Settings, TargetChannel, 0

global Position := SavedPos
global TargetChannel := SavedChan
global ReceiverVidPid := "046D:C52B"
global HidApiTesterPath := A_ScriptDir . "\hidapitester.exe"

global Armed := false
global ZoneEnterTime := 0
global DwellMs := 567
global SetupMode := false
global SetupStep := 0

; Show the startup OSD
StartStartupSequence()
return

; ==============================================================================
; INTERACTIVE STARTUP OSD SEQUENCE (WITH EXTENDED TIME WINDOW)
; ==============================================================================
StartStartupSequence() {
    global Position, TargetChannel, SetupMode, SetupStep
    SetupMode := true
    SetupStep := 0

    ShowOSD("Mode: " . Position . " | Target: Ch " . (TargetChannel + 1) . "`nPress [SPACE] to change settings", -1, true)

    ; Wait 8 seconds for SPACE to be pressed (more time to decide)
    SetTimer, StartupTimeout, -8000
}

#If (SetupMode)
Space::
    SetTimer, StartupTimeout, Off
    SetupStep := 1
    ShowOSD("Press [T] for TOP  or  [B] for BOTTOM", -1, true)

    ; Exit setup if nothing is pressed within 15 seconds
    SetTimer, SetupStepTimeout, -15000
return

t::
b::
    if (SetupStep != 1)
        return

    SetTimer, SetupStepTimeout, Off
    SubKey := A_ThisHotkey
    if (SubKey = "t")
        Position := "TOP"
    else
        Position := "BOTTOM"

    ; SAVE TO THE INI FILE IMMEDIATELY
    IniWrite, %Position%, %IniFile%, Settings, Position

    SetupStep := 2
    ShowOSD("Press [1], [2] or [3] for Channel", -1, true)

    ; Another 15 seconds to pick the channel
    SetTimer, SetupStepTimeout, -15000
return

1::
2::
3::
    if (SetupStep != 2)
        return

    SetTimer, SetupStepTimeout, Off
    SubChan := A_ThisHotkey
    TargetChannel := SubChan - 1

    ; SAVE TO THE INI FILE IMMEDIATELY
    IniWrite, %TargetChannel%, %IniFile%, Settings, TargetChannel

    SetupStep := 0
    ShowOSD("Settings Saved!", -1, true)

    ; Confirmation message stays visible for 2 seconds
    SetTimer, FinishSetup, -2000
return
#If

SetupStepTimeout:
StartupTimeout:
FinishSetup:
    SetTimer, StartupTimeout, Off
    SetTimer, SetupStepTimeout, Off
    SetupMode := false
    SetupStep := 0
    ShowOSD("Mouse Switcher Active", -1, true)
    SetTimer, HideOSD_Timer, -1000
    SetTimer, CheckScreenEdge, 30   ; Fast polling cycle (30ms)
return

; ==============================================================================
; MONITORING AND SCREEN EDGE DETECTION
; ==============================================================================
CheckScreenEdge:
    if (SetupMode)
        return

    SysGet, VLeft, 76
    SysGet, VTop, 77
    SysGet, VWidth, 78
    SysGet, VHeight, 79
    VBottom := VTop + VHeight

    CoordMode, Mouse, Screen
    MouseGetPos, xpos, ypos

    ; TOP machine → switches at the bottom edge | BOTTOM machine → switches at the top edge
    InZone := (Position = "TOP" && ypos >= VBottom - 5)
           || (Position = "BOTTOM" && ypos <= VTop + 5)

    if (!InZone) {
        Armed := true
        if (ZoneEnterTime != 0) {   ; Left the zone before switching → reset
            ZoneEnterTime := 0
            HideOSD()
        }
        return
    }

    if (!Armed)
        return

    ; Entered the zone → start the counter + show OSD with a progress bar
    if (ZoneEnterTime = 0) {
        ZoneEnterTime := A_TickCount
        ShowOSD("Switching channel...", 0)
        return
    }

    ; Compute elapsed time and update the progress bar (0 - 100%)
    ElapsedTime := A_TickCount - ZoneEnterTime
    ProgressPercent := Min(100, Round((ElapsedTime / DwellMs) * 100))
    UpdateOSDProgress(ProgressPercent)

    ; Dwell time hasn't elapsed yet
    if (ElapsedTime < DwellMs)
        return

    ; Elapsed → switch
    Armed := false
    ZoneEnterTime := 0
    SetTimer, CheckScreenEdge, Off

    CenterX := VLeft + Round(VWidth / 2)

    ; Compute the OSD's Y position so the cursor lands on it
    SysGet, ScreenHeight, 1
    if (Position = "BOTTOM")
        PosY := Round(ScreenHeight * 0.06)
    else
        PosY := Round(ScreenHeight * 0.88)

    ; Move the cursor right onto the center of the OSD box
    MouseMove, CenterX, PosY + 20, 0

    ; Send the HID++ command
    SwitchChannel(TargetChannel)

    ; Successful switch: progress bar disappears (-1), centered "Switched" text
    ShowOSD("Switched", -1)

    SetTimer, HideOSD_Timer, -600
    Sleep, 400
    SetTimer, CheckScreenEdge, On
return

; ==============================================================================
; UNIFYING HID++ CHANNEL SWITCH FUNCTION
; ==============================================================================
SwitchChannel(channel) {
    if !FileExist(HidApiTesterPath)
        return

    cmd := Format("""{}"" --vidpid {} --usagePage 0xFF00 --open --length 7 --send-output 0x10,0x01,0x0A,0x1e,0x{:02x},0x00,0x00", HidApiTesterPath, ReceiverVidPid, channel)
    Run, %cmd%, , Hide
}

; ==============================================================================
; ROUNDED, ALWAYS-CENTERED OSD ELEMENT
; ==============================================================================
ShowOSD(Text, ProgressVal := -1, CenterOSD := false) {
    global                      ; Global function mode

    Gui, OSD:Destroy
    Gui, OSD:+AlwaysOnTop +ToolWindow -Caption +HwndhOSD
    Gui, OSD:Margin, 20, 10
    Gui, OSD:Color, 1E1E1E
    Gui, OSD:Font, s11 c00FF7F SemiBold, Segoe UI

    if (ProgressVal >= 0) {
        Gui, OSD:Add, Text, Center w140 vOSDText, %Text%
        Gui, OSD:Add, Progress, w140 h4 Background2A2A2A c00FF7F vOSDProgressRange %ProgressVal%
    } else {
        Gui, OSD:Add, Text, Center vOSDText, %Text%
    }

    SysGet, ScreenHeight, 1

    if (CenterOSD) {
        PosY := Round(ScreenHeight * 0.45)
    } else {
        if (Position = "BOTTOM")
            PosY := Round(ScreenHeight * 0.06)
        else
            PosY := Round(ScreenHeight * 0.88)
    }

    Gui, OSD:Show, NoActivate xCenter y%PosY%

    ; Round the corners via a WinAPI call
    WinGetPos, , , WinW, WinH, ahk_id %hOSD%
    hRgn := DllCall("CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", WinW, "Int", WinH, "Int", 12, "Int", 12)
    DllCall("SetWindowRgn", "Ptr", hOSD, "Ptr", hRgn, "UInt", true)

    WinSet, Transparent, 190, ahk_id %hOSD%
}

UpdateOSDProgress(Value) {
    GuiControl, OSD:, OSDProgressRange, %Value%
}

HideOSD() {
    Gui, OSD:Destroy
}

HideOSD_Timer:
    HideOSD()
return

Min(a, b) {
    return a < b ? a : b
}
