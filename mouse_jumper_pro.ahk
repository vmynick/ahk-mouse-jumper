#Persistent
#NoEnv
#SingleInstance Force
SetWorkingDir %A_ScriptDir%
SetBatchLines, -1                       ; Maximum execution speed

; ==============================================================================
; MOUSE JUMPER PRO
; ==============================================================================
; An extended build of mouse_jumper.ahk. Kept as a separate file (and a
; separate settings_pro.ini) on purpose, so trying it never touches the
; production mouse_jumper.ahk / mouse_jumper_v2.ahk or their settings.ini.
;
; Adds on top of the base version:
;   - System tray menu -- right-click the tray icon for Reconfigure, Pause/
;     Resume, Switch Now, Open Script Folder, Reload, Exit. No keyboard
;     shortcuts are bound for these on purpose, so there's nothing that could
;     collide with another program's hotkeys; everything is a tray click away.
;   - LEFT/RIGHT edge support, not just TOP/BOTTOM
;   - Edge detection anchored to a specific monitor's bounds instead of the
;     whole virtual desktop, with a setup step to pick which one
;   - A startup check that warns (via tray notification) if hidapitester.exe
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
IniRead, SavedPos, %IniFile%, Settings, Position, BOTTOM
IniRead, SavedChan, %IniFile%, Settings, TargetChannel, 0
IniRead, SavedMonitor, %IniFile%, Settings, MonitorIndex, 0
IniRead, SavedLogging, %IniFile%, Settings, EnableLogging, 0

global Position := SavedPos
global TargetChannel := SavedChan
global MonitorIndex := SavedMonitor + 0
global EnableLogging := SavedLogging + 0
global ReceiverVidPid := "046D:C52B"
global HidApiTesterPath := A_ScriptDir . "\hidapitester.exe"

global Armed := false
global ZoneEnterTime := 0
global DwellMs := 567
global SetupMode := false
global SetupStep := 0
global Paused := false

global MonitorCount := 0
SysGet, MonitorCount, MonitorCount

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
        SysGet, effectiveMonitor, MonitorPrimary

    ShowOSD("Mode: " . Position . " | Ch " . (TargetChannel + 1) . " | Monitor " . effectiveMonitor . "`nPress [SPACE] to change settings", -1, true)

    ; Wait 8 seconds for SPACE to be pressed (more time to decide)
    SetTimer, StartupTimeout, -8000
}

#If (SetupMode)
Space::
    SetTimer, StartupTimeout, Off
    SetupStep := 1
    ShowOSD("Press [T]op [B]ottom [L]eft [R]ight", -1, true)

    ; Exit setup if nothing is pressed within 15 seconds
    SetTimer, SetupStepTimeout, -15000
return

t::
b::
l::
r::
    if (SetupStep != 1)
        return

    SetTimer, SetupStepTimeout, Off
    SubKey := A_ThisHotkey
    if (SubKey = "t")
        Position := "TOP"
    else if (SubKey = "b")
        Position := "BOTTOM"
    else if (SubKey = "l")
        Position := "LEFT"
    else
        Position := "RIGHT"

    ; SAVE TO THE INI FILE IMMEDIATELY
    IniWrite, %Position%, %IniFile%, Settings, Position

    if (MonitorCount > 1) {
        SetupStep := 2
        ShowOSD("Press [1]-[" . MonitorCount . "] to pick the Monitor", -1, true)
        SetTimer, SetupStepTimeout, -15000
    } else {
        MonitorIndex := 1
        IniWrite, %MonitorIndex%, %IniFile%, Settings, MonitorIndex
        SetupStep := 3
        ShowOSD("Press [1], [2] or [3] for Channel", -1, true)
        SetTimer, SetupStepTimeout, -15000
    }
return

1::
2::
3::
4::
5::
6::
7::
8::
9::
    Digit := A_ThisHotkey

    if (SetupStep = 2) {
        if (Digit > MonitorCount)
            return

        SetTimer, SetupStepTimeout, Off
        MonitorIndex := Digit

        ; SAVE TO THE INI FILE IMMEDIATELY
        IniWrite, %MonitorIndex%, %IniFile%, Settings, MonitorIndex

        SetupStep := 3
        ShowOSD("Press [1], [2] or [3] for Channel", -1, true)

        ; Another 15 seconds to pick the channel
        SetTimer, SetupStepTimeout, -15000
    } else if (SetupStep = 3) {
        if (Digit > 3)
            return

        SetTimer, SetupStepTimeout, Off
        TargetChannel := Digit - 1

        ; SAVE TO THE INI FILE IMMEDIATELY
        IniWrite, %TargetChannel%, %IniFile%, Settings, TargetChannel

        SetupStep := 0
        ShowOSD("Settings Saved!", -1, true)

        ; Confirmation message stays visible for 2 seconds
        SetTimer, FinishSetup, -2000
    }
return
#If

SetupStepTimeout:
StartupTimeout:
FinishSetup:
    SetTimer, StartupTimeout, Off
    SetTimer, SetupStepTimeout, Off
    SetupMode := false
    SetupStep := 0
    ShowOSD("Mouse Jumper Pro Active", -1, true)
    SetTimer, HideOSD_Timer, -1000
    if (!Paused)
        SetTimer, CheckScreenEdge, 30   ; Fast polling cycle (30ms)
    UpdateTrayTip()
return

; ==============================================================================
; POWER-USER ACTIONS (triggered from the tray menu)
; ==============================================================================
TogglePause() {
    global Paused, SetupMode
    if (SetupMode)
        return

    Paused := !Paused
    if (Paused) {
        SetTimer, CheckScreenEdge, Off
        ShowOSD("Mouse Jumper Paused", -1, true)
        WriteLog("Paused via tray menu")
    } else {
        ShowOSD("Mouse Jumper Resumed", -1, true)
        SetTimer, HideOSD_Timer, -1000
        SetTimer, CheckScreenEdge, 30
        WriteLog("Resumed via tray menu")
    }
    UpdateTrayTip()
}

ManualSwitch() {
    global SetupMode, Paused
    if (SetupMode || Paused)
        return

    SetTimer, CheckScreenEdge, Off
    PerformSwitch()
    SetTimer, HideOSD_Timer, -600
    Sleep, 400
    SetTimer, CheckScreenEdge, On
}

ReconfigureNow() {
    global SetupMode, Paused
    if (SetupMode)
        return

    Paused := false
    SetTimer, CheckScreenEdge, Off
    StartStartupSequence()
}

; ==============================================================================
; SYSTEM TRAY MENU
; ==============================================================================
; Deliberately does NOT use Menu's Check/Uncheck/Default/Rename sub-commands.
; Both looking an item up by its name text and by position ("N&", which is
; the documented way to do it) failed here with "Nonexistent menu item",
; for reasons that didn't reproduce as any known documented limitation --
; so rather than keep guessing at a fragile workaround, the pause state is
; only shown via the tray tooltip (hover) and the "Paused"/"Resumed" OSD
; popup when toggled; the menu items themselves just fire an action and are
; never looked up again afterward.
SetupTrayMenu() {
    ; Custom tray icon: the classic Windows "Mouse" control-panel icon (a
    ; picture of a mouse device), pulled from main.cpl instead of shipping a
    ; separate .ico file. Icon 1 (AHK's IconNumber is 1-based) was verified
    ; to be the mouse icon on this system; if a future Windows version ships
    ; a different icon order, this just silently falls back to the default
    ; AutoHotkey tray icon (FileExist guards against a missing/renamed file).
    TrayIconFile := A_WinDir . "\System32\main.cpl"
    if FileExist(TrayIconFile)
        Menu, Tray, Icon, %TrayIconFile%, 1

    Menu, Tray, NoStandard
    Menu, Tray, Add, Reconfigure..., TrayReconfigure
    Menu, Tray, Add, Pause/Resume Switching, TrayTogglePause
    Menu, Tray, Add
    Menu, Tray, Add, Switch Now, TrayManualSwitch
    Menu, Tray, Add
    Menu, Tray, Add, Open Script Folder, TrayOpenFolder
    Menu, Tray, Add, Reload Script, TrayReload
    Menu, Tray, Add, Exit, TrayExit
    UpdateTrayTip()
}

TrayReconfigure:
    ReconfigureNow()
return

TrayTogglePause:
    TogglePause()
return

TrayManualSwitch:
    ManualSwitch()
return

TrayOpenFolder:
    Run, explorer.exe "%A_ScriptDir%"
return

TrayReload:
    Reload
return

TrayExit:
    ExitApp
return

UpdateTrayTip() {
    global Position, TargetChannel, Paused, MonitorIndex
    state := Paused ? "PAUSED" : "Active"
    Menu, Tray, Tip, % "Mouse Jumper Pro [" . state . "]`n" . Position . " | Ch " . (TargetChannel + 1) . " | Monitor " . MonitorIndex
}

; ==============================================================================
; STARTUP DEPENDENCY CHECKS
; ==============================================================================
CheckDependencies() {
    global HidApiTesterPath, ReceiverVidPid

    if !FileExist(HidApiTesterPath) {
        WriteLog("ERROR: hidapitester.exe not found at " . HidApiTesterPath)
        ; Built as a variable rather than inline text/expression, so an embedded
        ; comma in the message can never be misread as a TrayTip parameter split.
        msg := "hidapitester.exe not found next to the script -- channel switching is disabled until it's added. See README."
        TrayTip, Mouse Jumper Pro, %msg%, 10, 2
        return
    }

    ; Best-effort check that the receiver is actually visible to Windows.
    ; Non-fatal either way -- this only ever produces a heads-up notification.
    tempOut := A_Temp . "\mjp_check_" . A_TickCount . ".txt"
    q := Chr(34)   ; built via Chr(34) rather than doubled-quote escaping, so the quote count can't drift
    cmd := q . HidApiTesterPath . q . " --vidpid " . ReceiverVidPid . " --list > " . q . tempOut . q . " 2>&1"
    ; cmd.exe's /c has a well-known quirk: when the command starts with a
    ; quoted token (the exe path here), it needs the *whole* command wrapped
    ; in one more, outer pair of quotes or the redirection silently never
    ; runs (verified directly: without the extra wrap, the temp file never
    ; got created at all, which is what made this check always "fail").
    RunWait, %ComSpec% /c "%cmd%", , Hide

    outText := ""
    if FileExist(tempOut) {
        FileRead, outText, %tempOut%
        FileDelete, %tempOut%
    }

    vidPidSlash := StrReplace(ReceiverVidPid, ":", "/")
    if !InStr(outText, vidPidSlash) && !InStr(outText, ReceiverVidPid) {
        WriteLog("WARNING: receiver " . ReceiverVidPid . " not found via hidapitester --list")
        msg := "Receiver " . ReceiverVidPid . " wasn't detected. Plug it in, or update ReceiverVidPid in the script."
        TrayTip, Mouse Jumper Pro, %msg%, 10, 2
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
    FileAppend, %timestamp% %msg%`n, %LogFile%
}

; ==============================================================================
; MONITOR BOUNDS (picked monitor, falling back to the primary one)
; ==============================================================================
GetMonitorBounds(ByRef OutLeft, ByRef OutTop, ByRef OutRight, ByRef OutBottom) {
    global MonitorIndex, MonitorCount

    idx := MonitorIndex
    if (idx < 1 || idx > MonitorCount)
        SysGet, idx, MonitorPrimary

    SysGet, MB, Monitor, %idx%
    OutLeft := MBLeft
    OutTop := MBTop
    OutRight := MBRight
    OutBottom := MBBottom
}

; ==============================================================================
; MONITORING AND SCREEN EDGE DETECTION
; ==============================================================================
CheckScreenEdge:
    if (SetupMode || Paused)
        return

    GetMonitorBounds(MLeft, MTop, MRight, MBottom)

    CoordMode, Mouse, Screen
    MouseGetPos, xpos, ypos

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
    SetTimer, CheckScreenEdge, Off

    PerformSwitch(MLeft, MTop, MRight, MBottom)

    SetTimer, HideOSD_Timer, -600
    Sleep, 400
    SetTimer, CheckScreenEdge, On
return

; ==============================================================================
; PERFORM THE ACTUAL SWITCH (shared by the edge trigger and "Switch Now")
; ==============================================================================
PerformSwitch(MLeft := "", MTop := "", MRight := "", MBottom := "") {
    global Position, TargetChannel

    if (MLeft = "")
        GetMonitorBounds(MLeft, MTop, MRight, MBottom)

    ; Park the cursor on the monitor edge the OSD appears at, so it lands
    ; right on top of the "Switched" confirmation.
    if (Position = "TOP" || Position = "BOTTOM") {
        CenterX := MLeft + Round((MRight - MLeft) / 2)
        if (Position = "BOTTOM")
            PosY := MTop + Round((MBottom - MTop) * 0.06)
        else
            PosY := MTop + Round((MBottom - MTop) * 0.88)
        MouseMove, CenterX, PosY + 20, 0
    } else {
        CenterY := MTop + Round((MBottom - MTop) / 2)
        if (Position = "RIGHT")
            PosX := MLeft + Round((MRight - MLeft) * 0.06)
        else
            PosX := MLeft + Round((MRight - MLeft) * 0.88)
        MouseMove, PosX + 20, CenterY, 0
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

    cmd := Format("""{}"" --vidpid {} --usagePage 0xFF00 --open --length 7 --send-output 0x10,0x01,0x0A,0x1e,0x{:02x},0x00,0x00", HidApiTesterPath, ReceiverVidPid, channel)
    Run, %cmd%, , Hide
}

; ==============================================================================
; ROUNDED OSD ELEMENT, EXPLICITLY POSITIONED ON THE CHOSEN MONITOR
; ==============================================================================
ShowOSD(Text, ProgressVal := -1, CenterOSD := false) {
    global                      ; Global function mode -- required because the Gui controls
                                 ; below are bound to variables (vOSDText, vOSDProgressRange),
                                 ; and AHK v1 requires a control's associated variable to be
                                 ; global or static, not function-local.

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

    ; Show off-screen first to measure the real size, then reposition it onto
    ; the chosen monitor explicitly -- the "xCenter"/"yCenter" keywords always
    ; resolve against the *primary* monitor's work area, regardless of which
    ; monitor MonitorIndex actually points at.
    Gui, OSD:Show, NoActivate x-2000 y-2000
    WinGetPos, , , WinW, WinH, ahk_id %hOSD%

    GetMonitorBounds(MLeft, MTop, MRight, MBottom)
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

    Gui, OSD:Show, NoActivate x%PosX% y%PosY%

    ; Round the corners via a WinAPI call
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
