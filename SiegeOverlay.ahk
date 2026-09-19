#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
; Siege Profile Manager - live display overlay (AutoHotkey v2)
; Display only: it never sends input. It reads the state that
; siege_profile_manager.lua publishes (no OCR, no screen reading).
;
;   F8  expand / collapse the hotkey cheat sheet
;   F9  show / hide the overlay
; ============================================================

; How the state arrives: G HUB's Lua has no file access, so
; siege_profile_manager.lua calls OutputDebugMessage("SPMSTATE#n|k=v|...").
; That is Windows debug output (OutputDebugString); DbgListener below
; receives it exactly like Sysinternals DebugView would.
; Close DebugView (or any other debug monitor) while this runs: only one
; program can receive debug output at a time.

; ---- weapon slot sync -------------------------------------------------------
; Pressing 1 / 2 in Siege selects primary / secondary. G HUB Lua cannot see
; number keys, so this script watches them and sets a lock key that the Lua CAN
; read: ScrollLock OFF = primary, ON = secondary. The keys still reach the game
; (the ~ prefix). Must match CONFIG.slotSync.lockKey in the Lua.
SLOT_LOCK := "ScrollLock"
; Only react while one of these programs is the active window:
SIEGE_EXES := ["RainbowSix.exe", "RainbowSix_Vulkan.exe", "RainbowSix_BE.exe"]
SLOT_SYNC_ANYWHERE := false     ; true = react in any window (for testing)

IsSiegeActive() {
    global SIEGE_EXES, SLOT_SYNC_ANYWHERE
    if SLOT_SYNC_ANYWHERE
        return true
    try exe := WinGetProcessName("A")
    catch
        return false
    for name in SIEGE_EXES {
        if (StrLower(exe) = StrLower(name))
            return true
    }
    return false
}

class DbgListener {
    static Ready := false
    static Shared := false      ; another debug monitor already owns the buffer

    static Init() {
        ; Debug-output protocol: shared 4 KB buffer (DWORD pid + text) + two events.
        this.hMap := DllCall("CreateFileMapping", "Ptr", -1, "Ptr", 0, "UInt", 0x04
            , "UInt", 0, "UInt", 4096, "Str", "DBWIN_BUFFER", "Ptr")
        if !this.hMap
            return
        this.Shared := (A_LastError = 183)                  ; ERROR_ALREADY_EXISTS
        this.view := DllCall("MapViewOfFile", "Ptr", this.hMap, "UInt", 0x4   ; FILE_MAP_READ
            , "UInt", 0, "UInt", 0, "UPtr", 0, "Ptr")
        this.evReady := DllCall("CreateEvent", "Ptr", 0, "Int", 0, "Int", 0
            , "Str", "DBWIN_BUFFER_READY", "Ptr")
        this.evData := DllCall("CreateEvent", "Ptr", 0, "Int", 0, "Int", 0
            , "Str", "DBWIN_DATA_READY", "Ptr")
        if !(this.view && this.evReady && this.evData)
            return
        DllCall("SetEvent", "Ptr", this.evReady)            ; tell the sender the buffer is free
        this.Ready := true
    }

    ; Returns every SPMSTATE line received since the last call.
    static Drain() {
        lines := []
        if !this.Ready
            return lines
        while (DllCall("WaitForSingleObject", "Ptr", this.evData, "UInt", 0) = 0) {
            text := StrGet(this.view + 4, 4092, "CP0")
            DllCall("SetEvent", "Ptr", this.evReady)
            pos := InStr(text, "SPMSTATE#")
            if pos
                lines.Push(Trim(SubStr(text, pos), "`r`n "))
        }
        return lines
    }
}

class OverlayState {
    ; Filled from the Lua export. Placeholders until the first update.
    static Linked := false
    static Source := ""
    static Seq := ""
    static Data := Map()

    static Get(key, default := "-") {
        return this.Data.Has(key) ? this.Data[key] : default
    }
}

class SiegeOverlay {
    static Width := 430
    static MarginTop := 24
    static MarginRight := 24
    static Alpha := 230
    static BaseH := 332            ; window height without the hotkey list (Layout() updates it)
    static Expanded := false
    static Visible := true
    static LastRaw := ""
    static Pastes := Map()          ; weapon -> paste-ready RECOIL_PROFILES line
    static HintText := "F8 keys   |   F9 hide   |   F10 copy tuned profiles"

    static Init() {
        ; click-through (E0x20) + never takes focus (E0x08000000)
        this.Gui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 +E0x08000000", "Siege Profile Manager")
        this.Gui.MarginX := 0
        this.Gui.MarginY := 0
        this.Gui.BackColor := "17191D"

        this.Gui.SetFont("s10 Bold cE8E8E8", "Segoe UI")
        this.Title := this.Gui.AddText("x16 y12 w250 h24 +0x200", "SIEGE PROFILE MANAGER")
        this.Status := this.Gui.AddText("x270 y12 w74 h24 Right +0x200", "--")

        this.Gui.SetFont("s12 Bold cFFFFFF", "Segoe UI")
        this.Head := this.Gui.AddText("x16 y42 w398 h26 +0x200 +0x4000", "")

        ; Equipped loadout: one weapon row + one attachment row per slot
        this.Gui.SetFont("s10 Bold cE8E8E8", "Segoe UI")
        this.PrimW := this.Gui.AddText("x16 y74 w398 h20 +0x200 +0x4000", "")
        this.Gui.SetFont("s9 Norm cA9ADB5", "Segoe UI")
        this.PrimA := this.Gui.AddText("x16 y94 w398 h18 +0x200 +0x4000", "")
        this.Gui.SetFont("s10 Bold cE8E8E8", "Segoe UI")
        this.SecW := this.Gui.AddText("x16 y118 w398 h20 +0x200 +0x4000", "")
        this.Gui.SetFont("s9 Norm cA9ADB5", "Segoe UI")
        this.SecA := this.Gui.AddText("x16 y138 w398 h18 +0x200 +0x4000", "")

        this.Gui.SetFont("s9 cE8E8E8", "Segoe UI")
        this.Profile := this.Gui.AddText("x16 y166 w398 h20 +0x200 +0x4000", "")
        this.Calib := this.Gui.AddText("x16 y186 w398 h20 +0x200 +0x4000", "")
        this.Recoil := this.Gui.AddText("x16 y206 w398 h20 +0x200 +0x4000", "")
        this.Spray := this.Gui.AddText("x16 y226 w398 h20 +0x200 +0x4000", "")

        ; "what do I do now" line: wraps to two lines
        this.Gui.SetFont("s9 Bold cFFD866", "Segoe UI")
        this.Next := this.Gui.AddText("x16 y252 w398 h36", "")

        ; Guided recoil tuning panel (only visible while tuning)
        this.Gui.SetFont("s9 Bold cF0B429", "Segoe UI")
        this.T1 := this.Gui.AddText("x16 y292 w398 h20 +0x200 +0x4000", "")
        this.Gui.SetFont("s9 Norm cE8E8E8", "Segoe UI")
        this.T2 := this.Gui.AddText("x16 y312 w398 h20 +0x200 +0x4000", "")
        this.Gui.SetFont("s9 cA9ADB5", "Segoe UI")
        this.T3 := this.Gui.AddText("x16 y332 w398 h20 +0x200 +0x4000", "")

        this.Gui.SetFont("s8 Norm cA9ADB5", "Segoe UI")
        this.Link := this.Gui.AddText("x16 y292 w398 h16 +0x200 +0x4000", "")
        this.Hint := this.Gui.AddText("x16 y308 w398 h16 +0x200", this.HintText)

        ; Cheat sheet: monospace so the columns line up, brighter than the state rows
        this.Gui.SetFont("s9 cFFFFFF", "Consolas")
        this.Hotkeys := this.Gui.AddText("x16 y336 w398 h420", this.HotkeyText())
        this.Hotkeys.Visible := false
        for c in [this.T1, this.T2, this.T3]
            c.Visible := false

        this.Show()
        WinSetTransparent(this.Alpha, "ahk_id " this.Gui.Hwnd)
        this.Render()

        DbgListener.Init()
        this.SetSlot("PRIMARY", false)      ; baseline: lock key OFF = primary
        this.Render()
        SetTimer(() => SiegeOverlay.Poll(), 50)
        SetTimer(() => SiegeOverlay.KeepOnTop(), 2000)   ; borderless games can steal Z-order
    }

    static HotkeyText() {
        lines := [
            "HOTKEYS",
            "RSHIFT + Click    Detect operator",
            "RCTRL + MB5/MB4   Next / prev operator",
            "RCTRL + LMB       Favorite on/off",
            "LCTRL + MB5/MB4   Next / prev favorite",
            "LCTRL + LMB       Attack / Defense",
            "",
            "LALT  + MB5       Next primary",
            "LALT  + MB4       Next secondary",
            "LALT  + LMB       Next grip",
            "LSHIFT + MB5      Next scope",
            "LSHIFT + MB4      Next barrel",
            "",
            "RALT  + MB5       System on/off",
            "RALT  + MB4       Debug on/off",
            "RALT  + LMB       Redraw (resend overlay)",
            "RSHIFT + MB4      Calibrate: start, set corner",
            "RSHIFT + MB5      Cancel / reset calibration",
            "",
            "LSHIFT + LMB      Recoil tune on/off",
            " tune: MB5/MB4 answer the question",
            " tune: LALT+MB5 next, LALT+MB4 back",
            " tune: LSHIFT+MB4 reset weapon",
            "",
            "1 / 2 (in Siege)  Primary / secondary slot",
            "",
            "F8  Expand / collapse this list",
            "F9  Show / hide overlay",
            "F10 Copy tuned profiles to clipboard"
        ]
        out := ""
        for line in lines
            out .= (A_Index > 1 ? "`n" : "") line
        return out
    }

    ; ---------------------------------------------------------
    ; State input
    ; ---------------------------------------------------------
    static Poll() {
        for line in DbgListener.Drain()
            this.Apply(line)
    }

    ; "SPMSTATE#12|v=1|enabled=1|..."  (the newest line wins)
    static Apply(line) {
        parts := StrSplit(line, "|")
        head := parts.RemoveAt(1)
        data := Map()
        data["seq"] := SubStr(head, InStr(head, "#") + 1)
        for p in parts {
            pos := InStr(p, "=")
            if pos > 1
                data[SubStr(p, 1, pos - 1)] := SubStr(p, pos + 1)
        }
        if !(data.Has("v") && data.Has("debug"))
            return                              ; cut-off or foreign line, ignore
        wasTuning := OverlayState.Get("tune", "0") = "1"
        if (data.Has("paste") && RegExMatch(data["paste"], '^\["(.+?)"\]', &m))
            this.Pastes[m[1]] := data["paste"]
        OverlayState.Data := data
        OverlayState.Seq := data["seq"]
        OverlayState.Linked := true
        OverlayState.Source := "DEBUG"
        this.Render()
        if (wasTuning && data.Get("tune", "0") = "0")
            this.CopyProfiles()                 ; tuning just finished
    }

    ; Called on the 1 / 2 keys: tells the Lua which slot is active (via the lock key)
    ; and updates the overlay immediately without waiting for the Lua.
    static SetSlot(slot, refresh := true) {
        global SLOT_LOCK
        try SetScrollLockState(slot = "SECONDARY" ? "On" : "Off")
        if (refresh && OverlayState.Linked) {
            if (OverlayState.Get("secondary") = "NONE" && slot = "SECONDARY")
                return                          ; operator has no secondary: Lua ignores it too
            OverlayState.Data["slot"] := slot
            this.Render()
        }
    }

    ; Puts every profile tuned this session on the clipboard (and in a text file
    ; next to this script) so it can be pasted into RECOIL_PROFILES.
    static CopyProfiles() {
        if (this.Pastes.Count = 0) {
            this.Toast("No tuned profiles yet - tune one first")
            return
        }
        text := "-- paste these into RECOIL_PROFILES in siege_profile_manager.lua`r`n"
        for weapon, line in this.Pastes
            text .= line "`r`n"
        A_Clipboard := text
        try {
            f := FileOpen(A_ScriptDir "\SiegeRecoilProfiles.txt", "w", "UTF-8")
            f.Write(text)
            f.Close()
        }
        this.Toast("Copied " this.Pastes.Count " tuned profile(s) - paste into RECOIL_PROFILES")
    }

    static Toast(msg) {
        this.Hint.Text := msg
        this.Tint(this.Hint, "3DDC84")
        SetTimer(() => SiegeOverlay.ResetHint(), -8000)
    }

    static ResetHint() {
        this.Hint.Text := this.HintText
        this.Tint(this.Hint, "A9ADB5")
    }

    ; ---------------------------------------------------------
    ; Drawing
    ; ---------------------------------------------------------
    static Tint(ctrl, color) {
        ctrl.SetFont("c" color)
    }

    static Render() {
        static GREEN := "3DDC84", RED := "FF5C5C", AMBER := "F0B429", GREY := "A9ADB5", WHITE := "E8E8E8"
        d := OverlayState

        if !d.Linked {
            this.Status.Text := "--"
            this.Tint(this.Status, AMBER)
            this.Head.Text := "WAITING FOR G HUB"
            this.PrimW.Text := "Press RALT + left click (redraw) once, or use"
            this.PrimA.Text := "any manager hotkey, so G HUB sends state."
            this.SecW.Text := ""
            this.SecA.Text := ""
            this.Profile.Text := ""
            this.Calib.Text := ""
            this.Recoil.Text := ""
            this.Spray.Text := ""
            this.Next.Text := ""
            this.Link.Text := !DbgListener.Ready ? "LINK: listener failed to start"
                : (DbgListener.Shared ? "LINK: another debug monitor is running (close DebugView)"
                : "LINK: listening for G HUB, no state yet")
            this.Tint(this.Link, AMBER)
            this.Layout()
            return
        }

        on := d.Get("enabled") = "1"
        this.Status.Text := on ? "ON" : "OFF"
        this.Tint(this.Status, on ? GREEN : RED)

        this.Head.Text := d.Get("side") "  •  " d.Get("operator")

        ; Equipped loadout for BOTH slots; the active slot is marked and brighter
        active := d.Get("slot")
        for spec in [["primary", this.PrimW, this.PrimA], ["secondary", this.SecW, this.SecA]] {
            slot := spec[1], wRow := spec[2], aRow := spec[3]
            isActive := (active = StrUpper(slot))
            weapon := d.Get(slot)
            label := StrUpper(SubStr(slot, 1, 1)) SubStr(slot, 2)
            wRow.Text := (isActive ? "► " : "    ") label ":  "
                . (weapon = "NONE" ? "none (this operator has no " slot ")" : weapon)
            this.Tint(wRow, isActive ? WHITE : GREY)
            if (weapon = "NONE") {
                aRow.Text := ""
            } else {
                aRow.Text := "        Sight " this.Att(d.Get(slot "_scope"))
                    . "   ·   Barrel " this.Att(d.Get(slot "_barrel"))
                    . "   ·   Grip " this.Att(d.Get(slot "_grip"))
            }
            this.Tint(aRow, isActive ? "C9CDD6" : "6F747D")
        }

        if (d.Get("tune") = "1") {
            ; guided recoil tuning panel
            this.T1.Text := "TUNING " d.Get("tune_step") "  " d.Get("tune_name") "  =  " d.Get("tune_val")
            this.T2.Text := d.Get("tune_ask")
            this.T3.Text := d.Get("tune_next") "     " d.Get("tune_reset")
        }

        profile := d.Get("profile")
        this.Profile.Text := "RECOIL PROF " profile
        this.Tint(this.Profile, profile = "TUNED" ? GREEN : (SubStr(profile, 1, 3) = "N/A" ? GREY : AMBER))

        cal := d.Get("calibration")
        this.Calib.Text := "GRID CAL    " cal
        this.Tint(this.Calib, SubStr(cal, 1, 10) = "CALIBRATED" ? GREEN
            : (SubStr(cal, 1, 6) = "ACTIVE" ? AMBER : GREY))

        recoil := d.Get("recoil")
        this.Recoil.Text := "RECOIL      " recoil
        spray := d.Get("spray", "none yet (hold ADS + fire)")
        this.Spray.Text := "LAST SPRAY  " spray
        this.Tint(this.Spray, SubStr(spray, 1, 4) = "none" ? GREY : GREEN)
        this.Next.Text := "NEXT ▸  " d.Get("next", "")
        this.Tint(this.Recoil, SubStr(recoil, 1, 5) = "READY" ? GREEN : GREY)

        this.Link.Text := "LINK: " d.Source "  #" d.Seq
            (d.Get("debug") = "1" ? "   DEBUG ON" : "")
        this.Tint(this.Link, GREY)
        this.Layout()
    }

    ; "-" = the weapon has no such slot, "NONE" = slot present but empty
    static Att(v) {
        return (v = "-") ? "n/a" : (v = "NONE" ? "none" : v)
    }

    ; Moves the bottom controls down while the tuning panel is showing and resizes the window.
    static Layout() {
        tuning := OverlayState.Linked && OverlayState.Get("tune") = "1"
        shift := tuning ? 66 : 0
        for c in [this.T1, this.T2, this.T3]
            c.Visible := tuning
        this.Link.Move(16, 292 + shift)
        this.Hint.Move(16, 308 + shift)
        this.Hotkeys.Move(16, 336 + shift)
        this.BaseH := 332 + shift
        if this.Visible
            this.Gui.Move(, , this.Width, this.Height())
    }

    static Height() {
        return this.Expanded ? this.BaseH + 440 : this.BaseH
    }

    ; ---------------------------------------------------------
    ; Window
    ; ---------------------------------------------------------
    static Show() {
        h := this.Height()
        this.Hotkeys.Visible := this.Expanded

        MonitorGet(MonitorGetPrimary(), &left, &top, &right, &bottom)
        x := right - this.Width - this.MarginRight
        y := top + this.MarginTop

        this.Gui.Show("NA x" x " y" y " w" this.Width " h" h)
        this.Visible := true
        WinSetTransparent(this.Alpha, "ahk_id " this.Gui.Hwnd)
    }

    static KeepOnTop() {
        if this.Visible
            WinSetAlwaysOnTop(true, "ahk_id " this.Gui.Hwnd)
    }

    static ToggleExpanded() {
        this.Expanded := !this.Expanded
        this.Show()     ; also reveals the overlay if it was hidden
    }

    static ToggleVisible() {
        if this.Visible {
            this.Gui.Hide()
            this.Visible := false
        } else {
            this.Show()
        }
    }
}

SiegeOverlay.Init()

F8::SiegeOverlay.ToggleExpanded()
F9::SiegeOverlay.ToggleVisible()
F10::SiegeOverlay.CopyProfiles()

; 1 / 2 still go to the game (~). Only while Siege is the active window.
#HotIf IsSiegeActive()
~1::SiegeOverlay.SetSlot("PRIMARY")
~2::SiegeOverlay.SetSlot("SECONDARY")
#HotIf
