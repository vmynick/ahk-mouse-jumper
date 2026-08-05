#Requires AutoHotkey v2.0
#SingleInstance Force
SetWorkingDir(A_ScriptDir)

; Work around DPI scaling discrepancies
DllCall("SetThreadDpiAwarenessContext", "ptr", -3)

; ==============================================================================
; CONFIG FILE AND SETTINGS MANAGEMENT (.INI)
; ==============================================================================
global IniFile := A_ScriptDir . "\settings.ini"

; Load settings from file (falls back to defaults if missing: bottom machine)
global Position := IniRead(IniFile, "Settings", "Position", "BOTTOM")
global TargetChannel := Integer(IniRead(IniFile, "Settings", "TargetChannel", "0"))
global ReceiverVidPid := "046D:C52B"
global HidApiTesterPath := A_ScriptDir . "\hidapitester.exe"
global OSDGui := ""
global OSDProgressCtrl := ""

global Armed := false           ; Arming: can only switch after leaving the zone first
global ZoneEnterTime := 0       ; When the cursor entered the zone (0 = not inside)
global DwellMs := 567           ; How long the cursor must stay at the edge before switching (ms)
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
    SetTimer(EndSetup, -8000)
}

; These hotkeys deliberately have NO "~" prefix, so the keypress
; is swallowed during setup mode instead of leaking into the active window.
#HotIf SetupMode
Space::BeginPositionChoice()
t::HandlePositionChoice()
b::HandlePositionChoice()
1::HandleChannelChoice()
2::HandleChannelChoice()
3::HandleChannelChoice()
#HotIf

BeginPositionChoice() {
    global SetupStep
    SetTimer(EndSetup, 0)
    SetupStep := 1
    ShowOSD("Press [T] for TOP  or  [B] for BOTTOM", -1, true)

    ; Exit setup if nothing is pressed within 15 seconds
    SetTimer(EndSetup, -15000)
}

HandlePositionChoice() {
    global SetupStep, Position, IniFile
    if (SetupStep != 1)
        return

    SetTimer(EndSetup, 0)
    Position := (A_ThisHotkey = "t") ? "TOP" : "BOTTOM"

    ; SAVE TO THE INI FILE IMMEDIATELY
    IniWrite(Position, IniFile, "Settings", "Position")

    SetupStep := 2
    ShowOSD("Press [1], [2] or [3] for Channel", -1, true)

    ; Another 15 seconds to pick the channel
    SetTimer(EndSetup, -15000)
}

HandleChannelChoice() {
    global SetupStep, TargetChannel, IniFile
    if (SetupStep != 2)
        return

    SetTimer(EndSetup, 0)
    TargetChannel := Integer(A_ThisHotkey) - 1

    ; SAVE TO THE INI FILE IMMEDIATELY
    IniWrite(TargetChannel, IniFile, "Settings", "TargetChannel")

    SetupStep := 0
    ShowOSD("Settings Saved!", -1, true)

    ; Confirmation message stays visible for 2 seconds
    SetTimer(EndSetup, -2000)
}

EndSetup() {
    global SetupMode, SetupStep
    SetupMode := false
    SetupStep := 0
    ShowOSD("Mouse Switcher Active", -1, true)
    SetTimer(HideOSD, -1000)
    SetTimer(CheckScreenEdge, 30)   ; Fast polling cycle (30ms)
}

; ==============================================================================
; MONITORING AND SCREEN EDGE DETECTION
; ==============================================================================
CheckScreenEdge() {
    global Armed, ZoneEnterTime, DwellMs, SetupMode, Position, TargetChannel

    if (SetupMode)
        return

    VLeft := SysGet(76)
    VTop := SysGet(77)
    VWidth := SysGet(78)
    VHeight := SysGet(79)
    VBottom := VTop + VHeight

    CoordMode("Mouse", "Screen")
    MouseGetPos(&xpos, &ypos)

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
    SetTimer(CheckScreenEdge, 0)

    CenterX := VLeft + Round(VWidth / 2)

    ; Compute the OSD's Y position so the cursor lands on it
    ScreenHeight := SysGet(1)
    if (Position = "BOTTOM")
        PosY := Round(ScreenHeight * 0.06)
    else
        PosY := Round(ScreenHeight * 0.88)

    ; Move the cursor right onto the center of the OSD box
    MouseMove(CenterX, PosY + 20, 0)

    ; Send the HID++ command
    SwitchChannel(TargetChannel)

    ; Successful switch: progress bar disappears (-1), centered "Switched" text
    ShowOSD("Switched", -1)

    SetTimer(HideOSD, -600)
    Sleep(400)
    SetTimer(CheckScreenEdge, 30)
}

; ==============================================================================
; UNIFYING HID++ CHANNEL SWITCH FUNCTION
; ==============================================================================
SwitchChannel(channel) {
    if !FileExist(HidApiTesterPath)
        return

    cmd := Format('"{1}" --vidpid {2} --usagePage 0xFF00 --usage 0x0001 --open --length 7 --send-output 0x10,0x02,0x0A,0x1e,0x{3:02x},0x00,0x00', HidApiTesterPath, ReceiverVidPid, channel)
    Run(cmd, , "Hide")
}

; ==============================================================================
; ROUNDED, ALWAYS-CENTERED OSD ELEMENT
; ==============================================================================
ShowOSD(Text, ProgressVal := -1, CenterOSD := false) {
    global OSDGui, OSDProgressCtrl, Position

    if (OSDGui)
        OSDGui.Destroy()

    OSDGui := Gui("+AlwaysOnTop +ToolWindow -Caption")
    OSDGui.MarginX := 20
    OSDGui.MarginY := 10
    OSDGui.BackColor := "1E1E1E"
    OSDGui.SetFont("s11 c00FF7F w600", "Segoe UI")

    if (ProgressVal >= 0) {
        OSDGui.Add("Text", "Center w140", Text)
        OSDProgressCtrl := OSDGui.Add("Progress", "w140 h4 Background2A2A2A c00FF7F", ProgressVal)
    } else {
        OSDGui.Add("Text", "Center", Text)
        OSDProgressCtrl := ""
    }

    ScreenHeight := SysGet(1)

    if (CenterOSD)
        PosY := Round(ScreenHeight * 0.45)
    else if (Position = "BOTTOM")
        PosY := Round(ScreenHeight * 0.06)
    else
        PosY := Round(ScreenHeight * 0.88)

    OSDGui.Show("NoActivate xCenter y" . PosY)

    ; Round the corners (v2 style)
    OSDGui.GetPos(&WinX, &WinY, &WinW, &WinH)
    hRgn := DllCall("CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", WinW, "Int", WinH, "Int", 12, "Int", 12, "Ptr")
    DllCall("SetWindowRgn", "Ptr", OSDGui.Hwnd, "Ptr", hRgn, "UInt", true)

    WinSetTransparent(190, OSDGui.Hwnd)
}

UpdateOSDProgress(Value) {
    global OSDProgressCtrl
    if (OSDProgressCtrl)
        OSDProgressCtrl.Value := Value
}

HideOSD() {
    global OSDGui
    if (OSDGui) {
        OSDGui.Destroy()
        OSDGui := ""
    }
}
