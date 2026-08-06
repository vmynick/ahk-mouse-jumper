#Requires AutoHotkey v2.0
#SingleInstance Force
SetWorkingDir(A_ScriptDir)

; ==============================================================================
; MOUSE JUMPER PRO (v2)
; ==============================================================================
; AutoHotkey v2 port of mouse_jumper_pro.ahk, using the same HID++ bytes as
; mouse_jumper_v2.ahk (device index 2, usage 0x0001) since this is the pro
; build for the machine that runs the v2 script. Keeps its own
; settings_pro.ini, so trying it never touches settings.ini or the
; non-pro scripts.
;
; Same feature set as mouse_jumper_pro.ahk:
;   - System tray menu with its own icon (Windows' "Mouse" control-panel
;     icon) -- Reconfigure, Pause/Resume, Switch Now, Open Script Folder,
;     Reload, Exit. No keyboard shortcuts; everything is a tray click away.
;   - LEFT/RIGHT edge support, not just TOP/BOTTOM
;   - Edge detection anchored to a specific monitor's bounds instead of the
;     whole virtual desktop, with a setup step to pick which one
;   - Startup checks that warn (via tray notification) if hidapitester.exe
;     or the configured receiver isn't found
;   - Optional logging of switches/warnings to mouse_jumper_pro.log
; ==============================================================================

; Work around DPI scaling discrepancies
DllCall("SetThreadDpiAwarenessContext", "ptr", -3)

; ==============================================================================
; CONFIG FILE AND SETTINGS MANAGEMENT (.INI)
; ==============================================================================
global IniFile := A_ScriptDir . "\settings_pro.ini"
global LogFile := A_ScriptDir . "\mouse_jumper_pro.log"

; Load settings from file (falls back to defaults if missing)
global Position := IniRead(IniFile, "Settings", "Position", "BOTTOM")
global TargetChannel := Integer(IniRead(IniFile, "Settings", "TargetChannel", "0"))
global MonitorIndex := Integer(IniRead(IniFile, "Settings", "MonitorIndex", "0"))
global EnableLogging := Integer(IniRead(IniFile, "Settings", "EnableLogging", "0"))
global ReceiverVidPid := "046D:C52B"
global HidApiTesterPath := A_ScriptDir . "\hidapitester.exe"
global OSDGui := ""
global OSDProgressCtrl := ""

global Armed := false
global ZoneEnterTime := 0
global DwellMs := 567
global SetupMode := false
global SetupStep := 0
global Paused := false

global MonitorCount := MonitorGetCount()

; Show the tray menu, run startup checks, then the startup OSD
SetupTrayMenu()
CheckDependencies()
StartStartupSequence()
return

; ==============================================================================
; INTERACTIVE STARTUP OSD SEQUENCE (POSITION, MONITOR, CHANNEL)
; ==============================================================================
StartStartupSequence() {
    global Position, TargetChannel, MonitorIndex, MonitorCount, SetupMode, SetupStep
    SetupMode := true
    SetupStep := 0

    effectiveMonitor := MonitorIndex
    if (effectiveMonitor < 1 || effectiveMonitor > MonitorCount)
        effectiveMonitor := MonitorGetPrimary()

    ShowOSD("Mode: " . Position . " | Ch " . (TargetChannel + 1) . " | Monitor " . effectiveMonitor . "`nPress [SPACE] to change settings", -1, true)

    ; Wait 8 seconds for SPACE to be pressed (more time to decide)
    SetTimer(EndSetup, -8000)
}

; These hotkeys deliberately have NO "~" prefix, so the keypress is
; swallowed during setup mode instead of leaking into the active window.
#HotIf SetupMode
Space::BeginPositionChoice()
t::HandlePositionChoice()
b::HandlePositionChoice()
l::HandlePositionChoice()
r::HandlePositionChoice()
1::HandleDigit()
2::HandleDigit()
3::HandleDigit()
4::HandleDigit()
5::HandleDigit()
6::HandleDigit()
7::HandleDigit()
8::HandleDigit()
9::HandleDigit()
#HotIf

BeginPositionChoice() {
    global SetupStep
    SetTimer(EndSetup, 0)
    SetupStep := 1
    ShowOSD("Press [T]op [B]ottom [L]eft [R]ight", -1, true)

    ; Exit setup if nothing is pressed within 15 seconds
    SetTimer(EndSetup, -15000)
}

HandlePositionChoice() {
    global SetupStep, Position, IniFile, MonitorCount, MonitorIndex
    if (SetupStep != 1)
        return

    SetTimer(EndSetup, 0)
    key := A_ThisHotkey
    if (key = "t")
        Position := "TOP"
    else if (key = "b")
        Position := "BOTTOM"
    else if (key = "l")
        Position := "LEFT"
    else
        Position := "RIGHT"

    ; SAVE TO THE INI FILE IMMEDIATELY
    IniWrite(Position, IniFile, "Settings", "Position")

    if (MonitorCount > 1) {
        SetupStep := 2
        ShowOSD("Press [1]-[" . MonitorCount . "] to pick the Monitor", -1, true)
        SetTimer(EndSetup, -15000)
    } else {
        MonitorIndex := 1
        IniWrite(MonitorIndex, IniFile, "Settings", "MonitorIndex")
        SetupStep := 3
        ShowOSD("Press [1], [2] or [3] for Channel", -1, true)
        SetTimer(EndSetup, -15000)
    }
}

HandleDigit() {
    global SetupStep, MonitorIndex, MonitorCount, TargetChannel, IniFile
    digit := Integer(A_ThisHotkey)

    if (SetupStep = 2) {
        if (digit > MonitorCount)
            return

        SetTimer(EndSetup, 0)
        MonitorIndex := digit

        ; SAVE TO THE INI FILE IMMEDIATELY
        IniWrite(MonitorIndex, IniFile, "Settings", "MonitorIndex")

        SetupStep := 3
        ShowOSD("Press [1], [2] or [3] for Channel", -1, true)

        ; Another 15 seconds to pick the channel
        SetTimer(EndSetup, -15000)
    } else if (SetupStep = 3) {
        if (digit > 3)
            return

        SetTimer(EndSetup, 0)
        TargetChannel := digit - 1

        ; SAVE TO THE INI FILE IMMEDIATELY
        IniWrite(TargetChannel, IniFile, "Settings", "TargetChannel")

        SetupStep := 0
        ShowOSD("Settings Saved!", -1, true)

        ; Confirmation message stays visible for 2 seconds
        SetTimer(EndSetup, -2000)
    }
}

EndSetup() {
    global SetupMode, SetupStep, Paused
    SetupMode := false
    SetupStep := 0
    ShowOSD("Mouse Jumper Pro Active", -1, true)
    SetTimer(HideOSD, -1000)
    if (!Paused)
        SetTimer(CheckScreenEdge, 30)   ; Fast polling cycle (30ms)
    UpdateTrayTip()
}

; ==============================================================================
; POWER-USER ACTIONS (triggered from the tray menu)
; ==============================================================================
TogglePause() {
    global Paused, SetupMode
    if (SetupMode)
        return

    Paused := !Paused
    if (Paused) {
        SetTimer(CheckScreenEdge, 0)
        ShowOSD("Mouse Jumper Paused", -1, true)
        WriteLog("Paused via tray menu")
    } else {
        ShowOSD("Mouse Jumper Resumed", -1, true)
        SetTimer(HideOSD, -1000)
        SetTimer(CheckScreenEdge, 30)
        WriteLog("Resumed via tray menu")
    }
    UpdateTrayTip()
}

ManualSwitch() {
    global SetupMode, Paused
    if (SetupMode || Paused)
        return

    SetTimer(CheckScreenEdge, 0)
    PerformSwitch()
    SetTimer(HideOSD, -600)
    Sleep(400)
    SetTimer(CheckScreenEdge, 30)
}

ReconfigureNow() {
    global SetupMode, Paused
    if (SetupMode)
        return

    Paused := false
    SetTimer(CheckScreenEdge, 0)
    StartStartupSequence()
}

; ==============================================================================
; SYSTEM TRAY MENU
; ==============================================================================
SetupTrayMenu() {
    ; Custom tray icon: the classic Windows "Mouse" control-panel icon (a
    ; picture of a mouse device), pulled from main.cpl instead of shipping a
    ; separate .ico file. Icon group 1 was verified (by extracting and
    ; inspecting it directly) to be the mouse icon; falls back to the
    ; default AutoHotkey tray icon if main.cpl isn't found.
    trayIconFile := A_WinDir . "\System32\main.cpl"
    if FileExist(trayIconFile)
        TraySetIcon(trayIconFile, 1)

    ; A_TrayMenu.Delete() clears the standard Open/Exit items (v2's
    ; equivalent of v1's "Menu, Tray, NoStandard"), then rebuilt from
    ; scratch below. Each item's callback is a small arrow-function wrapper
    ; ((*) => ...) because v2 menu callbacks always receive (ItemName,
    ; ItemPos, Menu) -- the action functions themselves stay plain,
    ; zero-argument functions.
    A_TrayMenu.Delete()
    A_TrayMenu.Add("Reconfigure...", (*) => ReconfigureNow())
    A_TrayMenu.Add("Pause/Resume Switching", (*) => TogglePause())
    A_TrayMenu.Add()
    A_TrayMenu.Add("Switch Now", (*) => ManualSwitch())
    A_TrayMenu.Add()
    A_TrayMenu.Add("Open Script Folder", (*) => Run('explorer.exe "' . A_ScriptDir . '"'))
    A_TrayMenu.Add("Reload Script", (*) => Reload())
    A_TrayMenu.Add("Exit", (*) => ExitApp())

    UpdateTrayTip()
}

UpdateTrayTip() {
    global Position, TargetChannel, Paused, MonitorIndex
    state := Paused ? "PAUSED" : "Active"
    A_IconTip := "Mouse Jumper Pro [" . state . "]`n" . Position . " | Ch " . (TargetChannel + 1) . " | Monitor " . MonitorIndex
}

; ==============================================================================
; STARTUP DEPENDENCY CHECKS
; ==============================================================================
CheckDependencies() {
    global HidApiTesterPath, ReceiverVidPid

    if !FileExist(HidApiTesterPath) {
        WriteLog("ERROR: hidapitester.exe not found at " . HidApiTesterPath)
        msg := "hidapitester.exe not found next to the script -- channel switching is disabled until it's added. See README."
        TrayTip(msg, "Mouse Jumper Pro", "Icon!")
        return
    }

    ; Best-effort check that the receiver is actually visible to Windows.
    ; Non-fatal either way -- this only ever produces a heads-up notification.
    tempOut := A_Temp . "\mjp_check_" . A_TickCount . ".txt"
    q := Chr(34)   ; built via Chr(34) rather than doubled-quote escaping, so the quote count can't drift
    cmd := q . HidApiTesterPath . q . " --vidpid " . ReceiverVidPid . " --list > " . q . tempOut . q . " 2>&1"
    comspec := EnvGet("ComSpec")
    ; cmd.exe's /c has a well-known quirk: when the command starts with a
    ; quoted token (the exe path here), it needs the *whole* command wrapped
    ; in one more, outer pair of quotes or the redirection silently never
    ; runs (verified directly: without the extra wrap, the temp file never
    ; got created at all, which is what made this check always "fail").
    RunWait(comspec . ' /c "' . cmd . '"', , "Hide")

    outText := ""
    if FileExist(tempOut) {
        outText := FileRead(tempOut)
        FileDelete(tempOut)
    }

    vidPidSlash := StrReplace(ReceiverVidPid, ":", "/")
    if !InStr(outText, vidPidSlash) && !InStr(outText, ReceiverVidPid) {
        WriteLog("WARNING: receiver " . ReceiverVidPid . " not found via hidapitester --list")
        msg := "Receiver " . ReceiverVidPid . " wasn't detected. Plug it in, or update ReceiverVidPid in the script."
        TrayTip(msg, "Mouse Jumper Pro", "Icon!")
    }
}

; ==============================================================================
; LOGGING (opt-in via EnableLogging=1 in settings_pro.ini)
; ==============================================================================
WriteLog(msg) {
    global EnableLogging, LogFile
    if (!EnableLogging)
        return
    timestamp := A_YYYY . "-" . A_MM . "-" . A_DD . " " . A_Hour . ":" . A_Min . ":" . A_Sec
    FileAppend(timestamp . " " . msg . "`n", LogFile)
}

; ==============================================================================
; MONITOR BOUNDS (picked monitor, falling back to the primary one)
; ==============================================================================
GetMonitorBounds(&OutLeft, &OutTop, &OutRight, &OutBottom) {
    global MonitorIndex, MonitorCount

    idx := MonitorIndex
    if (idx < 1 || idx > MonitorCount)
        idx := MonitorGetPrimary()

    MonitorGet(idx, &OutLeft, &OutTop, &OutRight, &OutBottom)
}

; ==============================================================================
; MONITORING AND SCREEN EDGE DETECTION
; ==============================================================================
CheckScreenEdge() {
    global Armed, ZoneEnterTime, DwellMs, SetupMode, Paused, Position, TargetChannel

    if (SetupMode || Paused)
        return

    GetMonitorBounds(&MLeft, &MTop, &MRight, &MBottom)

    CoordMode("Mouse", "Screen")
    MouseGetPos(&xpos, &ypos)

    ; TOP/BOTTOM watch the vertical edges of the chosen monitor, LEFT/RIGHT the horizontal ones
    InZone := false
    if (Position = "TOP" && ypos >= MBottom - 5)
        InZone := true
    else if (Position = "BOTTOM" && ypos <= MTop + 5)
        InZone := true
    else if (Position = "LEFT" && xpos >= MRight - 5)
        InZone := true
    else if (Position = "RIGHT" && xpos <= MLeft + 5)
        InZone := true

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

    PerformSwitch(MLeft, MTop, MRight, MBottom)

    SetTimer(HideOSD, -600)
    Sleep(400)
    SetTimer(CheckScreenEdge, 30)
}

; ==============================================================================
; PERFORM THE ACTUAL SWITCH (shared by the edge trigger and "Switch Now")
; ==============================================================================
PerformSwitch(MLeft := "", MTop := "", MRight := "", MBottom := "") {
    global Position, TargetChannel

    if (MLeft = "")
        GetMonitorBounds(&MLeft, &MTop, &MRight, &MBottom)

    ; Park the cursor on the monitor edge the OSD appears at, so it lands
    ; right on top of the "Switched" confirmation.
    if (Position = "TOP" || Position = "BOTTOM") {
        CenterX := MLeft + Round((MRight - MLeft) / 2)
        if (Position = "BOTTOM")
            PosY := MTop + Round((MBottom - MTop) * 0.06)
        else
            PosY := MTop + Round((MBottom - MTop) * 0.88)
        MouseMove(CenterX, PosY + 20, 0)
    } else {
        CenterY := MTop + Round((MBottom - MTop) / 2)
        if (Position = "RIGHT")
            PosX := MLeft + Round((MRight - MLeft) * 0.06)
        else
            PosX := MLeft + Round((MRight - MLeft) * 0.88)
        MouseMove(PosX + 20, CenterY, 0)
    }

    ; Send the HID++ command
    SwitchChannel(TargetChannel)
    WriteLog("Switched to channel " . (TargetChannel + 1))

    ; Successful switch: progress bar disappears (-1), centered "Switched" text
    ShowOSD("Switched", -1)
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
; ROUNDED OSD ELEMENT, EXPLICITLY POSITIONED ON THE CHOSEN MONITOR
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

    ; Show off-screen first to measure the real size, then reposition it onto
    ; the chosen monitor explicitly -- the "xCenter"/"yCenter" keywords always
    ; resolve against the *primary* monitor's work area, regardless of which
    ; monitor MonitorIndex actually points at.
    OSDGui.Show("NoActivate x-2000 y-2000")
    OSDGui.GetPos(&WinX, &WinY, &WinW, &WinH)

    GetMonitorBounds(&MLeft, &MTop, &MRight, &MBottom)
    MonW := MRight - MLeft
    MonH := MBottom - MTop

    if (CenterOSD) {
        PosX := MLeft + Round((MonW - WinW) / 2)
        PosY := MTop + Round(MonH * 0.45)
    } else if (Position = "TOP" || Position = "BOTTOM") {
        PosX := MLeft + Round((MonW - WinW) / 2)
        if (Position = "BOTTOM")
            PosY := MTop + Round(MonH * 0.06)
        else
            PosY := MTop + Round(MonH * 0.88)
    } else {
        PosY := MTop + Round((MonH - WinH) / 2)
        if (Position = "RIGHT")
            PosX := MLeft + Round(MonW * 0.06)
        else
            PosX := MLeft + Round(MonW * 0.88)
    }

    OSDGui.Show("NoActivate x" . PosX . " y" . PosY)

    ; Round the corners (v2 style)
    hRgn := DllCall("CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", WinW, "Int", WinH, "Int", 12, "Int", 12, "Ptr")
    DllCall("SetWindowRgn", "Ptr", OSDGui.Hwnd, "Ptr", hRgn, "UInt", true)

    WinSetTransparent(190, OSDGui.Hwnd)
}

UpdateOSDProgress(Value) {
    global OSDProgressCtrl
    if (OSDProgressCtrl) {
        ; A HideOSD() fired via an earlier SetTimer (e.g. the "Active"
        ; confirmation's -1000ms auto-hide) can destroy whatever OSD is
        ; *currently* showing -- which may by then be a later dwell-progress
        ; popup -- without this stale reference finding out. Catch instead
        ; of crashing the whole script, and drop the dangling reference.
        try {
            OSDProgressCtrl.Value := Value
        } catch {
            OSDProgressCtrl := ""
        }
    }
}

HideOSD() {
    global OSDGui, OSDProgressCtrl
    if (OSDGui) {
        OSDGui.Destroy()
        OSDGui := ""
        OSDProgressCtrl := ""
    }
}
