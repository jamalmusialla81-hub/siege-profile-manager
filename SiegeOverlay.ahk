#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
DetectHiddenWindows true        ; our own hidden GUIs must stay addressable (WinSetTransparent)
CoordMode "Mouse", "Screen"

; ==============================================================================
; SIEGE PROFILE MANAGER  V2  -  companion / control centre (AutoHotkey v2)
;
;   Lua (G HUB) --OutputDebugMessage--> Windows debug channel (DBWIN) --> this script
;
; The Lua script stays the engine: it reads the mouse, detects operators and
; keeps the live loadout. This script receives its state (SPMSTATE snapshots,
; SPMEVENT changes, SPMBEAT liveness), stores everything persistently, and
; hands the saved configuration back to the Lua as a generated SPM_USER block
; (the G HUB Lua sandbox cannot read files, so that block is pasted once).
;
;   F8  compact HUD  <->  full control centre      F9  show / hide everything
;   F7  capture a calibration point (while calibrating)   F10 copy tuned profiles
; ==============================================================================

; ------------------------------------------------------------------------------
; 0. CONSTANTS + SMALL HELPERS
; ------------------------------------------------------------------------------
class App {
    static Name := "Siege Profile Manager"
    static Version := "2.0"
    static Protocol := 2            ; SPMSTATE/SPMEVENT/SPMBEAT protocol this build understands
    static CfgVersion := 2
    static Dir := A_AppData "\SiegeProfileManager"
    static CfgFile := App.Dir "\config.json"
    static BakFile := App.Dir "\config.json.bak"
    static BackupDir := App.Dir "\backups"
}

class Clr {   ; colour tokens (RGB hex, no #)
    static Bg := "0C0E13", Panel := "13161D", Panel2 := "1A1E27", Line := "232834", Sel := "18212C"
    static Text := "E9EDF3", Dim := "8D96A8", Mute := "596275"
    static Accent := "4CC9E8", Accent2 := "4CC9E8", Ink := "06131A"   ; one accent colour (Accent2 = Accent: gradients render as flat lines)
    static GreenDim := "2A9672"                                         ; the low point of the "live" pulse
    static Green := "4ADE9C", Amber := "F2B84B", Red := "F07178", Blue := "6CA8F0"   ; status colours
}

Clamp(v, lo, hi) => Min(Max(v, lo), hi)

; Comma list -> Array (empty items dropped).
SplitList(text, delim := ",") {
    out := []
    for part in StrSplit(text, delim)
        if (part != "")
            out.Push(part)
    return out
}

JoinList(arr, delim := ", ") {
    out := ""
    for v in arr
        out .= (A_Index > 1 ? delim : "") v
    return out
}

; Case-insensitive position of val in arr (0 = absent).
IndexOf(arr, val) {
    for i, v in arr
        if (StrLower(String(v)) = StrLower(String(val)))
            return i
    return 0
}

; djb2 over a string (32-bit). Used for change detection, not security.
Djb2(str) {
    h := 5381
    loop parse str
        h := Mod(h * 33 + Ord(A_LoopField), 4294967296)
    return Format("{:08X}", h)
}

; Sets ctrl.Text only when it changed (avoids flicker and needless redraws).
SetText(ctrl, text) {
    if (ctrl.Text != text)
        ctrl.Text := text
}

; ------------------------------------------------------------------------------
; 1. JSON  (AHK v2 has none built in). Map <-> object, Array <-> list.
; ------------------------------------------------------------------------------
class Json {
    static Stringify(v, indent := "") {
        t := Type(v)
        if (t = "Map") {
            if (v.Count = 0)
                return "{}"
            out := "{`n"
            first := true
            for k, val in v {
                out .= (first ? "" : ",`n") indent "  " Json.Quote(String(k)) ": " Json.Stringify(val, indent "  ")
                first := false
            }
            return out "`n" indent "}"
        }
        if (t = "Array") {
            if (v.Length = 0)
                return "[]"
            out := "[`n"
            for i, val in v
                out .= (i > 1 ? ",`n" : "") indent "  " Json.Stringify(val, indent "  ")
            return out "`n" indent "]"
        }
        if (t = "Integer" || t = "Float")
            return String(v)
        return Json.Quote(String(v))
    }

    static Quote(s) {
        s := StrReplace(s, "\", "\\")
        s := StrReplace(s, '"', '\"')
        s := StrReplace(s, "`n", "\n")
        s := StrReplace(s, "`r", "\r")
        s := StrReplace(s, "`t", "\t")
        return '"' s '"'
    }

    ; Throws Error on malformed input.
    static Parse(text) {
        p := Json.P(text, 1)
        pos := Json.Skip(text, p.pos)
        if (pos <= StrLen(text))
            throw Error("Unexpected data after JSON value at " pos)
        return p.val
    }

    static Skip(t, i) {
        while (i <= StrLen(t) && InStr(" `t`r`n", SubStr(t, i, 1)))
            i++
        return i
    }

    ; Returns { val, pos } where pos is the index after the value.
    static P(t, i) {
        i := Json.Skip(t, i)
        c := SubStr(t, i, 1)
        if (c = "{") {
            m := Map()
            i := Json.Skip(t, i + 1)
            if (SubStr(t, i, 1) = "}")
                return { val: m, pos: i + 1 }
            loop {
                i := Json.Skip(t, i)
                if (SubStr(t, i, 1) != '"')
                    throw Error("Expected key at " i)
                k := Json.Str(t, i)
                i := Json.Skip(t, k.pos)
                if (SubStr(t, i, 1) != ":")
                    throw Error("Expected ':' at " i)
                v := Json.P(t, i + 1)
                m[k.val] := v.val
                i := Json.Skip(t, v.pos)
                d := SubStr(t, i, 1)
                if (d = ",") {
                    i++
                    continue
                }
                if (d = "}")
                    return { val: m, pos: i + 1 }
                throw Error("Expected ',' or '}' at " i)
            }
        }
        if (c = "[") {
            a := []
            i := Json.Skip(t, i + 1)
            if (SubStr(t, i, 1) = "]")
                return { val: a, pos: i + 1 }
            loop {
                v := Json.P(t, i)
                a.Push(v.val)
                i := Json.Skip(t, v.pos)
                d := SubStr(t, i, 1)
                if (d = ",") {
                    i++
                    continue
                }
                if (d = "]")
                    return { val: a, pos: i + 1 }
                throw Error("Expected ',' or ']' at " i)
            }
        }
        if (c = '"') {
            s := Json.Str(t, i)
            return { val: s.val, pos: s.pos }
        }
        if (SubStr(t, i, 4) = "true")
            return { val: 1, pos: i + 4 }
        if (SubStr(t, i, 5) = "false")
            return { val: 0, pos: i + 5 }
        if (SubStr(t, i, 4) = "null")
            return { val: "", pos: i + 4 }
        if RegExMatch(t, "A)-?\d+(\.\d+)?([eE][+-]?\d+)?", &m, i)
            return { val: (InStr(m[0], ".") || InStr(m[0], "e") || InStr(m[0], "E")) ? Float(m[0]) : Integer(m[0]), pos: i + m.Len[0] }
        throw Error("Unexpected character at " i)
    }

    static Str(t, i) {
        i++
        out := ""
        loop {
            if (i > StrLen(t))
                throw Error("Unterminated string")
            c := SubStr(t, i, 1)
            if (c = '"')
                return { val: out, pos: i + 1 }
            if (c = "\") {
                n := SubStr(t, i + 1, 1)
                switch n {
                    case "n": out .= "`n"
                    case "r": out .= "`r"
                    case "t": out .= "`t"
                    case "b": out .= "`b"
                    case "f": out .= "`f"
                    case "u":
                        out .= Chr(Integer("0x" SubStr(t, i + 2, 4)))
                        i += 4
                    default: out .= n
                }
                i += 2
                continue
            }
            out .= c
            i++
        }
    }
}

; ------------------------------------------------------------------------------
; 2. DATABASE  (operators, weapons, attachments, 7x7 grid, grid presets)
;    GENERATED from siege_profile_manager.lua (OPERATORS / OPERATOR_GRID / WEAPON_LIST /
;    CONFIG.grid.presets). DBREV is the Lua's own checksum of those tables: if the Lua
;    reports a different dbrev the overlay warns that this copy is outdated.
; ------------------------------------------------------------------------------
class Db {
    static Rev := ""
    static Weapons := Map()     ; id -> Map(kind, scopes[], barrels[], grips[])
    static Ops := Map()         ; side -> Array of Map(name, primary[], secondary[], defP, defS, fav)
    static Grid := Map()        ; side -> Array(7) of Array(7) of names ("" = empty cell)
    static Presets := Map()     ; "WxH|side" -> Map(tlx, tly, brx, bry, padx, pady)
    static Sides := ["attackers", "defenders"]
    static Kinds := ["primary", "secondary"]
    static Fields := ["scope", "barrel", "grip"]
    static FieldKey := Map("scope", "scopes", "barrel", "barrels", "grip", "grips")

    static Init() {
        sets := Map()
        sec := ""
        side := ""
        for line in StrSplit(DbRaw(), "`n", "`r") {
            if (line = "")
                continue
            if RegExMatch(line, "^\[(\w+)\s*(\w*)\]$", &m) {
                sec := m[1], side := m[2]
                if (sec = "OP")
                    Db.Ops[side] := []
                else if (sec = "GRID")
                    Db.Grid[side] := []
                continue
            }
            if (sec = "" && SubStr(line, 1, 6) = "DBREV=") {
                Db.Rev := SubStr(line, 7)
                continue
            }
            f := StrSplit(line, "|")
            switch sec {
                case "SETS":
                    eq := InStr(line, "=")
                    sets[SubStr(line, 1, eq - 1)] := SplitList(SubStr(line, eq + 1))
                case "OP":
                    Db.Ops[side].Push(Map("name", f[1], "primary", SplitList(f[2]), "secondary", SplitList(f[3])
                        , "defP", f[4], "defS", f[5], "fav", f[6] = "1"))
                case "GRID":
                    row := []
                    for cell in StrSplit(line, ",")
                        row.Push(cell)
                    Db.Grid[side].Push(row)
                case "PRESETS":
                    Db.Presets[f[1] "|" f[2]] := Map("tlx", Float(f[3]), "tly", Float(f[4]), "brx", Float(f[5])
                        , "bry", Float(f[6]), "padx", Float(f[7]), "pady", Float(f[8]))
                case "W":
                    Db.Weapons[f[1]] := Map("kind", f[2], "set", [f[3], f[4], f[5]])
            }
        }
        ; second pass: resolve the shared attachment sets (they are defined after the weapons)
        for id, w in Db.Weapons {
            s := w["set"]
            w["scopes"] := sets.Has(s[1]) ? sets[s[1]] : []
            w["barrels"] := sets.Has(s[2]) ? sets[s[2]] : []
            w["grips"] := sets.Has(s[3]) ? sets[s[3]] : []
        }
    }

    ; -> Map(op, side) or "" (case-insensitive name).
    static Find(name) {
        for side in Db.Sides
            for op in Db.Ops[side]
                if (StrLower(op["name"]) = StrLower(name))
                    return Map("op", op, "side", side)
        return ""
    }

    static OpIndex(side, name) {
        for i, op in Db.Ops[side]
            if (StrLower(op["name"]) = StrLower(name))
                return i
        return 0
    }

    static Has(op, kind) => op[kind].Length > 0

    ; Attachment options the weapon can really equip (never anything else).
    static Options(weaponId, field) {
        if !Db.Weapons.Has(weaponId)
            return []
        return Db.Weapons[weaponId][Db.FieldKey[field]]
    }

    ; Every scope name used by any weapon (for the preferred-scope dropdown), "AUTO" first.
    static AllScopes() {
        out := ["AUTO"]
        for id, w in Db.Weapons
            for s in w["scopes"]
                if !IndexOf(out, s)
                    out.Push(s)
        return out
    }

    static SideLabel(side) => side = "attackers" ? "ATTACK" : "DEFENCE"
    static SideFromLua(text) => InStr(StrUpper(text), "DEF") ? "defenders" : "attackers"
}

; ------------------------------------------------------------------------------
; 3. LOADOUT LOGIC  (mirrors the Lua's ValidateSlot / PickDefaultAttachment)
;    A slot is Map(weapon, scope, barrel, grip). A loadout is Map(primary, secondary).
; ------------------------------------------------------------------------------
class LoadoutMgr {
    static BarrelChain := ["SUPPRESSOR", "COMPENSATOR", "FLASH HIDER", "MUZZLE BRAKE", "EXTENDED BARREL", "NONE"]
    static GripChain := ["HORIZONTAL", "VERTICAL", "ANGLED", "NONE"]

    ; The preference chain the Lua uses: the user's preferred value first, then the built-in order.
    static Chain(field) {
        pref := Cfg.Get("prefs." field, "")
        base := field = "barrel" ? LoadoutMgr.BarrelChain : field = "grip" ? LoadoutMgr.GripChain : []
        chain := []
        if (pref != "" && pref != "AUTO")
            chain.Push(pref)
        for v in base
            chain.Push(v)
        return chain
    }

    static Pick(options, explicit, field) {
        if (explicit != "" && IndexOf(options, explicit))
            return options[IndexOf(options, explicit)]
        for name in LoadoutMgr.Chain(field)
            if IndexOf(options, name)
                return options[IndexOf(options, name)]
        return options.Length ? options[1] : ""
    }

    ; Returns a valid copy of slot for this operator/kind; empty Map when the operator has no such weapon.
    static Fix(opName, kind, slot := "") {
        found := Db.Find(opName)
        out := Map()
        if (!IsObject(found) || !Db.Has(found["op"], kind))
            return out
        op := found["op"]
        w := IsObject(slot) ? slot.Get("weapon", "") : ""
        idx := IndexOf(op[kind], w)
        w := idx ? op[kind][idx] : op[kind][1]
        out["weapon"] := w
        for field in Db.Fields {
            opts := Db.Options(w, field)
            cur := IsObject(slot) ? (slot.Get("weapon", "") = w ? slot.Get(field, "") : "") : ""
            if (IndexOf(opts, cur))
                out[field] := opts[IndexOf(opts, cur)]
            else
                out[field] := LoadoutMgr.Pick(opts, "", field)
        }
        return out
    }

    static Default(opName) {
        found := Db.Find(opName)
        lo := Map()
        if !IsObject(found)
            return lo
        op := found["op"]
        for kind in Db.Kinds {
            base := Map()
            defW := kind = "primary" ? op["defP"] : op["defS"]
            if (defW != "")
                base["weapon"] := defW
            lo[kind] := LoadoutMgr.Fix(opName, kind, base)
        }
        return lo
    }

    ; The working (currently saved) loadout of an operator, always valid.
    static Working(opName) {
        saved := Cfg.Get("saved." opName, "")
        lo := Map()
        for kind in Db.Kinds
            lo[kind] := LoadoutMgr.Fix(opName, kind, (IsObject(saved) && saved.Has(kind)) ? saved[kind] : "")
        return lo
    }

    static Copy(slot) {
        c := Map()
        for k, v in slot
            c[k] := v
        return c
    }

    static CopyLoadout(lo) => Map("primary", LoadoutMgr.Copy(lo["primary"]), "secondary", LoadoutMgr.Copy(lo["secondary"]))

    ; Changes one field of a slot in the working loadout (UI-originated -> Lua is now out of date).
    static Set(opName, kind, field, value) {
        lo := LoadoutMgr.Working(opName)
        slot := lo[kind]
        if (field = "weapon")
            lo[kind] := LoadoutMgr.Fix(opName, kind, Map("weapon", value))
        else {
            slot[field] := value
            lo[kind] := LoadoutMgr.Fix(opName, kind, slot)
        }
        Cfg.SetSaved(opName, lo, false)
    }

    ; Named loadouts ----------------------------------------------------------
    static List(opName) {
        rec := Cfg.Get("loadouts." opName, "")
        return (IsObject(rec) && rec.Has("list")) ? rec["list"] : []
    }

    static Active(opName) {
        rec := Cfg.Get("loadouts." opName, "")
        return (IsObject(rec) && rec.Has("active")) ? rec["active"] : ""
    }

    static Find(opName, name) {
        for i, e in LoadoutMgr.List(opName)
            if (StrLower(e["name"]) = StrLower(name))
                return i
        return 0
    }

    static UniqueName(opName, base) {
        name := base, n := 1
        while LoadoutMgr.Find(opName, name)
            name := base " " (++n)
        return name
    }

    static Entry(name, lo, fav := 0) {
        e := Map("name", name, "fav", fav)
        e["primary"] := LoadoutMgr.Copy(lo["primary"])
        e["secondary"] := LoadoutMgr.Copy(lo["secondary"])
        return e
    }

    static Create(opName, name, fromLo := "") {
        name := Trim(name)
        if (name = "" || LoadoutMgr.Find(opName, name))
            return false
        lo := IsObject(fromLo) ? fromLo : LoadoutMgr.Working(opName)
        LoadoutMgr.Store(opName).Push(LoadoutMgr.Entry(name, lo))
        if (LoadoutMgr.Active(opName) = "")
            Cfg.Data["loadouts"][opName]["active"] := name
        Cfg.Dirty()
        return true
    }

    ; loadouts.<op>.list, created on demand
    static Store(opName) {
        L := Cfg.Data["loadouts"]
        if !L.Has(opName)
            L[opName] := Map("active", "", "list", [])
        return L[opName]["list"]
    }

    static Duplicate(opName, idx) {
        src := LoadoutMgr.List(opName)[idx]
        return LoadoutMgr.Create(opName, LoadoutMgr.UniqueName(opName, src["name"] " COPY"), src)
    }

    static Rename(opName, idx, newName) {
        newName := Trim(newName)
        e := LoadoutMgr.List(opName)[idx]
        if (newName = "" || (StrLower(newName) != StrLower(e["name"]) && LoadoutMgr.Find(opName, newName)))
            return false
        if (LoadoutMgr.Active(opName) = e["name"])
            Cfg.Data["loadouts"][opName]["active"] := newName
        e["name"] := newName
        Cfg.Dirty()
        return true
    }

    static Delete(opName, idx) {
        list := LoadoutMgr.List(opName)
        wasActive := (LoadoutMgr.Active(opName) = list[idx]["name"])
        list.RemoveAt(idx)
        if (wasActive)
            Cfg.Data["loadouts"][opName]["active"] := list.Length ? list[1]["name"] : ""
        Cfg.Dirty()
    }

    static ToggleFav(opName, idx) {
        e := LoadoutMgr.List(opName)[idx]
        e["fav"] := e["fav"] ? 0 : 1
        Cfg.Dirty()
    }

    ; Makes a named loadout the working loadout of its operator. Live in the Lua only after the
    ; next config block / RALT+RMB cycle, so this marks the config as pending.
    static Activate(opName, idx) {
        e := LoadoutMgr.List(opName)[idx]
        lo := Map("primary", LoadoutMgr.Fix(opName, "primary", e["primary"]), "secondary", LoadoutMgr.Fix(opName, "secondary", e["secondary"]))
        Cfg.Data["loadouts"][opName]["active"] := e["name"]
        Cfg.SetSaved(opName, lo, false)
    }

    static SlotText(slot) {
        if (slot.Count = 0)
            return "none"
        return slot["weapon"] "  (" slot["scope"] " / " slot["barrel"] " / " slot["grip"] ")"
    }
}

; ------------------------------------------------------------------------------
; 4. DIAGNOSTIC LOG (ring buffer, shown on the DIAGNOSTICS page)
; ------------------------------------------------------------------------------
class Diag {
    static Lines := []
    static LastError := ""
    static ErrCount := 0
    static LastToastMs := 0

    ; Records an exception in full (message, line, call stack) instead of showing a modal error box.
    ; The text appears under Diagnostics > LAST ERROR and in the copied report.
    static Err(e, where := "") {
        Diag.ErrCount++
        stack := "", line := "?"
        try stack := e.Stack
        try line := e.Line
        first := ""
        loop parse stack, "`n", "`r" {
            if (A_Index > 4)
                break
            first .= (A_Index > 1 ? " | " : "") Trim(A_LoopField)
        }
        Diag.LastError := (where != "" ? "[" where "] " : "") e.Message "  (line " line ")" (first != "" ? "  stack: " first : "")
        Diag.Log("ERROR " Diag.LastError)
        if (A_TickCount - Diag.LastToastMs > 5000) {              ; never spam
            Diag.LastToastMs := A_TickCount
            try Toast.Show("error", "⚠ INTERNAL ERROR", SubStr(e.Message, 1, 60), "line " line "  ·  see Diagnostics", "")
        }
    }

    static Log(msg) {
        Diag.Lines.Push(FormatTime(, "HH:mm:ss") "  " msg)
        while (Diag.Lines.Length > 120)
            Diag.Lines.RemoveAt(1)
    }
}

; ------------------------------------------------------------------------------
; 5. PERSISTENT CONFIGURATION  (versioned JSON in %AppData%\SiegeProfileManager)
;    - atomic writes (temp file + move), the previous good file is kept as config.json.bak
;    - debounced: many quick edits produce one write
;    - a damaged file never crashes the app: .bak is tried, then defaults, and the damaged
;      file is kept next to it for inspection
; ------------------------------------------------------------------------------
class Cfg {
    static Data := Map()
    static Status := "NEW"          ; NEW | VALID | RECOVERED | DAMAGED
    static StatusMsg := ""
    static SaveError := ""
    static Ver := 0                 ; bumped on every change (cache key for ContentHash)
    static HashVer := -1
    static HashCache := ""
    static Fn := ""

    static Defaults() {
        d := Map()
        d["version"] := App.CfgVersion
        d["game"] := Map("dpi", 1600, "sensH", 4, "sensV", 4, "fov", 84, "ads", 52
            , "resW", A_ScreenWidth, "resH", A_ScreenHeight, "coordSpace", "")
        d["prefs"] := Map("scope", "AUTO", "barrel", "SUPPRESSOR", "grip", "HORIZONTAL")
        d["state"] := Map("side", "attackers", "operator", "")
        d["favorites"] := []
        d["favInit"] := 0
        d["learned"] := Map()           ; key "WEAPON:BARREL:GRIP" -> fitted profile (goes to the Lua)
        d["learnData"] := Map()         ; key -> aggregated recordings (per-100 ms sums), kept on this PC only
        d["saved"] := Map()
        d["loadouts"] := Map()
        d["calibration"] := Map()
        d["luaKeybinds"] := Map()
        d["ui"] := Map("scale", 1.0, "mode", "hud", "hudSize", "Normal", "hudPos", "Top Right"
            , "hudX", 40, "hudY", 40, "hudScale", 1.0, "opacity", 235, "notifications", 1
            , "launch", "hud", "rememberPos", 1, "centerX", "", "centerY", "", "page", "HOME"
            , "sections", Cfg.DefaultSections())
        d["hotkeys"] := Map("mode", "F8", "visible", "F9", "capture", "F7", "profiles", "F10", "record", "F6")
        d["setup"] := Map("done", 0)
        d["coach"] := Map("mode", "", "on", 0, "hist", Map())
        d["sync"] := Map("baseline", "", "copiedRev", "")
        d["lua"] := Map("path", "")
        return d
    }

    static DefaultSections() => Map("operator", 1, "weapon", 1, "attachments", 1
        , "connection", 1, "calibration", 0, "debug", 0, "modules", 1)

    ; --- access ---------------------------------------------------------------
    static Get(path, def := "") {
        node := Cfg.Data
        for key in StrSplit(path, ".") {
            if (Type(node) != "Map" || !node.Has(key))
                return def
            node := node[key]
        }
        return node
    }

    static Set(path, val) {
        keys := StrSplit(path, ".")
        node := Cfg.Data
        loop keys.Length - 1 {
            k := keys[A_Index]
            if (!node.Has(k) || Type(node[k]) != "Map")
                node[k] := Map()
            node := node[k]
        }
        node[keys[keys.Length]] := val
        Cfg.Dirty()
    }

    static Num(path, def := 0) {
        v := Cfg.Get(path, def)
        return IsNumber(v) ? v + 0 : def
    }

    ; --- change tracking ------------------------------------------------------
    ; Standard weapon choices, written ONCE into the saved loadouts (a saved loadout beats the built-in default). After that the
    ; app remembers whatever you pick in game, as usual. Add more operators here to seed them the same way.
    static SeedStandard() {
        if (Cfg.Get("prefs.standardSeed", 0) >= 1)
            return
        for name, picks in Map("Mute", ["M590A1", "SMG-11"], "Warden", ["M590A1", "SMG-12"]) {
            lo := Map()
            lo["primary"] := LoadoutMgr.Fix(name, "primary", Map("weapon", picks[1]))
            lo["secondary"] := LoadoutMgr.Fix(name, "secondary", Map("weapon", picks[2]))
            Cfg.SetSaved(name, lo, false)
        }
        Cfg.Data["prefs"]["standardSeed"] := 1
        Cfg.Dirty()
    }

    static Dirty() {
        Cfg.Ver++
        if !IsObject(Cfg.Fn)
            Cfg.Fn := ObjBindMethod(Cfg, "SaveNow")
        SetTimer(Cfg.Fn, -800)
    }

    ; The part of the config the Lua consumes. Changes to it can make the Lua's copy outdated.
    static LuaPart() {
        m := Map()
        for k in ["game", "prefs", "state", "favorites", "saved", "loadouts", "calibration", "luaKeybinds", "learned"]
            m[k] := Cfg.Data[k]
        return m
    }

    static ContentHash() {
        if (Cfg.HashVer != Cfg.Ver) {
            Cfg.HashCache := Djb2(Json.Stringify(Cfg.LuaPart()))
            Cfg.HashVer := Cfg.Ver
        }
        return Cfg.HashCache
    }

    ; True when something in the config has not been handed to the Lua yet.
    static Pending() => Cfg.Get("sync.baseline", "") != Cfg.ContentHash()

    static Rebase() {
        Cfg.Data["sync"]["baseline"] := Cfg.ContentHash()
        Cfg.Dirty()
    }

    ; Runs a change that originated IN the Lua (so the Lua already has it). If the config was in
    ; sync before the change it stays in sync afterwards.
    static FromLua(fn) {
        was := !Cfg.Pending()
        if !fn.Call()               ; fn returns true when it actually changed something
            return
        Cfg.Dirty()
        if was
            Cfg.Rebase()
    }

    static SetSaved(opName, lo, fromLua := false) {
        cur := Cfg.Get("saved." opName, "")
        if (IsObject(cur) && Json.Stringify(cur) = Json.Stringify(lo))
            return false
        was := fromLua ? !Cfg.Pending() : false
        Cfg.Data["saved"][opName] := LoadoutMgr.CopyLoadout(lo)
        Cfg.Dirty()
        if (fromLua && was)
            Cfg.Rebase()
        return true
    }

    ; --- load / save ----------------------------------------------------------
    static Load() {
        try {
            DirCreate(App.Dir)
            DirCreate(App.BackupDir)
        }
        if !FileExist(App.CfgFile) {
            if FileExist(App.BakFile) && (Cfg.TryLoad(App.BakFile) = "") {
                Cfg.Status := "RECOVERED"
                Cfg.StatusMsg := "CONFIGURATION FILE MISSING - BACKUP RESTORED"
                return
            }
            Cfg.Data := Cfg.Defaults()
            Cfg.Status := "NEW"
            return
        }
        err := Cfg.TryLoad(App.CfgFile)
        if (err = "") {
            Cfg.Status := "VALID"
            return
        }
        Diag.Log("config load failed: " err)
        kept := App.Dir "\config.damaged-" A_Now ".json"
        try FileCopy(App.CfgFile, kept, 1)
        if (Cfg.TryLoad(App.BakFile) = "") {
            Cfg.Status := "RECOVERED"
            Cfg.StatusMsg := "CONFIGURATION FILE DAMAGED - BACKUP RESTORED"
        } else {
            Cfg.Data := Cfg.Defaults()
            Cfg.Status := "DAMAGED"
            Cfg.StatusMsg := "CONFIGURATION FILE DAMAGED - DEFAULTS LOADED (damaged copy kept in " App.Dir ")"
        }
    }

    ; Returns "" on success or an error message. On failure Cfg.Data is left untouched.
    static TryLoad(path) {
        old := Cfg.Data
        try {
            data := Json.Parse(FileRead(path, "UTF-8"))
            msg := Cfg.Check(data)
            if (msg != "")
                return msg
            Cfg.Apply(Cfg.Migrate(data))
            return ""
        } catch as e {
            Cfg.Data := old
            return e.Message
        }
    }

    static Check(data) {
        if (Type(data) != "Map")
            return "not a configuration object"
        if (!data.Has("version") || !IsNumber(data["version"]))
            return "missing version"
        if (data["version"] > App.CfgVersion)
            return "created by a newer version (config v" data["version"] ", this build understands v" App.CfgVersion ")"
        return ""
    }

    ; Future format changes: add a step per version. Old files are upgraded in memory and rewritten on save.
    static Migrate(data) {
        ver := data["version"]
        while (ver < App.CfgVersion) {
            ; if (ver = 1) { ...convert v1 -> v2 fields... }
            ver++
        }
        data["version"] := App.CfgVersion
        return data
    }

    ; Builds a clean, complete config from possibly incomplete data. Unknown keys inside the
    ; settings sections are kept (forward compatibility); everything the app relies on is
    ; coerced to a valid value.
    static Apply(data) {
        old := Cfg.Data
        try {
            Cfg.Normalize(data)
        } catch as e {
            Cfg.Data := old
            throw e
        }
        Cfg.Ver++
    }

    static Normalize(data) {
        d := Cfg.Defaults()
        out := Map()
        out["version"] := App.CfgVersion
        for sec in ["game", "prefs", "state", "ui", "hotkeys", "setup", "sync", "lua", "coach"] {
            m := d[sec]
            src := (data.Has(sec) && Type(data[sec]) = "Map") ? data[sec] : Map()
            for k, v in src
                m[k] := v
            out[sec] := m
        }
        out["favInit"] := (data.Has("favInit") && data["favInit"]) ? 1 : 0
        g := out["game"]
        Cfg.Coerce(g, "dpi", 50, 32000, 1600), Cfg.Coerce(g, "sensH", 0.1, 100, 4), Cfg.Coerce(g, "sensV", 0.1, 100, 4)
        Cfg.Coerce(g, "fov", 40, 140, 84), Cfg.Coerce(g, "ads", 1, 200, 52)
        Cfg.Coerce(g, "resW", 640, 16384, A_ScreenWidth), Cfg.Coerce(g, "resH", 480, 16384, A_ScreenHeight)
        u := out["ui"]
        Cfg.Coerce(u, "scale", 0.6, 2.5, 1.0), Cfg.Coerce(u, "hudScale", 0.5, 2.0, 1.0)
        Cfg.Coerce(u, "opacity", 60, 255, 235), Cfg.Coerce(u, "hudX", -10000, 20000, 40), Cfg.Coerce(u, "hudY", -10000, 20000, 40)
        u["notifications"] := u["notifications"] ? 1 : 0
        u["rememberPos"] := u["rememberPos"] ? 1 : 0
        if !IsObject(u["sections"]) || Type(u["sections"]) != "Map"
            u["sections"] := Cfg.DefaultSections()
        for k, v in Cfg.DefaultSections()
            if !u["sections"].Has(k)
                u["sections"][k] := v
        if !IndexOf(["hud", "center"], u["mode"])
            u["mode"] := "hud"
        if !IndexOf(["Compact", "Normal", "Large"], u["hudSize"])
            u["hudSize"] := "Normal"
        if !IndexOf(["Top Left", "Top Right", "Bottom Left", "Bottom Right", "Custom"], u["hudPos"])
            u["hudPos"] := "Top Right"
        if !IndexOf(["hud", "center", "hidden"], u["launch"])
            u["launch"] := "hud"
        for k, v in d["hotkeys"]
            if (Type(out["hotkeys"][k]) != "String" || out["hotkeys"][k] = "")
                out["hotkeys"][k] := v
        out["state"]["side"] := IndexOf(Db.Sides, out["state"]["side"]) ? out["state"]["side"] : "attackers"
        out["setup"]["done"] := out["setup"]["done"] ? 1 : 0
        cm := out["coach"]
        if !IndexOf(["", "phys", "direct", "subtract"], cm["mode"])
            cm["mode"] := ""
        cm["on"] := cm["on"] ? 1 : 0
        if (Type(cm["hist"]) != "Map")
            cm["hist"] := Map()

        Cfg.Data := out          ; prefs are needed by LoadoutMgr.Fix below
        out["favorites"] := []
        if (data.Has("favorites") && Type(data["favorites"]) = "Array")
            for n in data["favorites"] {
                f := Db.Find(String(n))
                if (IsObject(f) && !IndexOf(out["favorites"], f["op"]["name"]))
                    out["favorites"].Push(f["op"]["name"])
            }
        out["saved"] := Map()
        if (data.Has("saved") && Type(data["saved"]) = "Map")
            for n, rec in data["saved"] {
                f := Db.Find(String(n))
                if (IsObject(f) && Type(rec) = "Map") {
                    lo := Map()
                    for kind in Db.Kinds
                        lo[kind] := LoadoutMgr.Fix(f["op"]["name"], kind, rec.Has(kind) && Type(rec[kind]) = "Map" ? rec[kind] : "")
                    out["saved"][f["op"]["name"]] := lo
                }
            }
        out["loadouts"] := Map()
        if (data.Has("loadouts") && Type(data["loadouts"]) = "Map")
            for n, rec in data["loadouts"] {
                f := Db.Find(String(n))
                if (!IsObject(f) || Type(rec) != "Map" || !rec.Has("list") || Type(rec["list"]) != "Array")
                    continue
                opName := f["op"]["name"]
                list := []
                for e in rec["list"] {
                    if (Type(e) != "Map" || !e.Has("name") || Trim(String(e["name"])) = "" || IndexOf(list.Length ? Cfg.Names(list) : [], e["name"]))
                        continue
                    lo := Map()
                    for kind in Db.Kinds
                        lo[kind] := LoadoutMgr.Fix(opName, kind, e.Has(kind) && Type(e[kind]) = "Map" ? e[kind] : "")
                    list.Push(LoadoutMgr.Entry(Trim(String(e["name"])), lo, e.Has("fav") && e["fav"] ? 1 : 0))
                }
                if (list.Length) {
                    act := rec.Has("active") ? String(rec["active"]) : ""
                    out["loadouts"][opName] := Map("active", IndexOf(Cfg.Names(list), act) ? act : list[1]["name"], "list", list)
                }
            }
        out["calibration"] := Map()
        if (data.Has("calibration") && Type(data["calibration"]) = "Map")
            for side in Db.Sides {
                c := data["calibration"].Has(side) ? data["calibration"][side] : ""
                if (Type(c) = "Map" && Cfg.IsGeo(c))
                    out["calibration"][side] := Map("tlx", c["tlx"] + 0, "tly", c["tly"] + 0, "brx", c["brx"] + 0
                        , "bry", c["bry"] + 0, "res", c.Get("res", ""), "src", c.Get("src", ""))
            }
        out["learned"] := Map()
        if (data.Has("learned") && Type(data["learned"]) = "Map")
            for key, pr in data["learned"]
                if (Type(pr) = "Map" && RegExMatch(String(key), "^[^:]+:[^:]+:[^:]+$") && Cfg.NumFields(pr, ["r", "y1", "y2", "tym1", "tym2", "side"])) {
                    m2 := Map()
                    for f in ["r", "y1", "y2", "tym1", "tym2", "side", "strength", "late", "n"]
                        m2[f] := (pr.Has(f) && IsNumber(pr[f])) ? pr[f] + 0 : (f = "strength" || f = "late" ? 1 : 0)
                    m2["t"] := pr.Has("t") ? String(pr["t"]) : ""
                    out["learned"][String(key)] := m2
                }
        out["learnData"] := Map()
        if (data.Has("learnData") && Type(data["learnData"]) = "Map")
            for key, r in data["learnData"]
                if (Type(r) = "Map" && r.Has("y") && r.Has("x") && r.Has("c") && Type(r["y"]) = "Array" && Type(r["x"]) = "Array" && Type(r["c"]) = "Array"
                    && r["y"].Length = r["x"].Length && r["y"].Length = r["c"].Length && r.Has("n") && IsNumber(r["n"]))
                    out["learnData"][String(key)] := r
        out["luaKeybinds"] := Map()
        if (data.Has("luaKeybinds") && Type(data["luaKeybinds"]) = "Map")
            for act, b in data["luaKeybinds"]
                if (Type(b) = "Map" && b.Has("mod") && b.Has("button") && IndexOf(Hk.Mods, b["mod"])
                    && IsInteger(b["button"]) && b["button"] >= 1 && b["button"] <= 5)
                    out["luaKeybinds"][act] := Map("mod", StrLower(b["mod"]), "button", Integer(b["button"]))
    }

    static NumFields(m, keys) {
        for k in keys
            if (!m.Has(k) || !IsNumber(m[k]))
                return false
        return true
    }

    static Names(list) {
        out := []
        for e in list
            out.Push(e["name"])
        return out
    }

    static IsGeo(c) {
        for k in ["tlx", "tly", "brx", "bry"]
            if (!c.Has(k) || !IsNumber(c[k]))
                return false
        return c["brx"] > c["tlx"] && c["bry"] > c["tly"]
    }

    static Coerce(m, key, lo, hi, def) {
        v := m.Has(key) ? m[key] : def
        m[key] := Clamp(IsNumber(v) ? v + 0 : def, lo, hi)
    }

    static SaveNow() {
        try {
            DirCreate(App.Dir)
            tmp := App.Dir "\config.tmp"
            f := FileOpen(tmp, "w", "UTF-8-RAW")
            f.Write(Json.Stringify(Cfg.Data))
            f.Close()
            if FileExist(App.CfgFile)
                FileCopy(App.CfgFile, App.BakFile, 1)
            FileMove(tmp, App.CfgFile, 1)
            Cfg.SaveError := ""
        } catch as e {
            Cfg.SaveError := e.Message
            Diag.Log("config save failed: " e.Message)
        }
        try LuaBlock.AutoSave()                ; keep the Lua file on disk in step with the config
    }

    ; --- export / import / backups -------------------------------------------
    static Backup() {
        Cfg.SaveNow()
        if !FileExist(App.CfgFile)
            return ""
        path := App.BackupDir "\config-" A_Now ".json"
        try {
            DirCreate(App.BackupDir)
            FileCopy(App.CfgFile, path, 1)
            list := ""
            loop files, App.BackupDir "\config-*.json"
                list .= A_LoopFileFullPath "`n"
            files := StrSplit(Sort(Trim(list, "`n")), "`n")     ; names carry a timestamp: sorted = oldest first
            while (files.Length > 15) {          ; keep the newest 15
                FileDelete(files[1])
                files.RemoveAt(1)
            }
            return path
        } catch as e {
            Diag.Log("backup failed: " e.Message)
            return ""
        }
    }

    static Export(path) {
        try {
            Cfg.SaveNow()
            f := FileOpen(path, "w", "UTF-8-RAW")
            f.Write(Json.Stringify(Cfg.Data))
            f.Close()
            return ""
        } catch as e {
            return e.Message
        }
    }

    ; Validates the file first; the current config is only replaced when everything checks out.
    static Import(path) {
        try {
            data := Json.Parse(FileRead(path, "UTF-8"))
        } catch as e {
            return "not a valid configuration file (" e.Message ")"
        }
        msg := Cfg.Check(data)
        if (msg != "")
            return msg
        Cfg.Backup()
        try {
            Cfg.Apply(Cfg.Migrate(data))
        } catch as e {
            return e.Message
        }
        Cfg.Dirty()
        return ""
    }

    static Reset() {
        Cfg.Backup()
        Cfg.Data := Cfg.Defaults()
        Cfg.Ver++
        Cfg.Dirty()
    }
}

; ------------------------------------------------------------------------------
; 6. LUA CONFIG BLOCK  (AHK -> Lua). The Lua reads SPM_USER once at start-up.
; ------------------------------------------------------------------------------
class LuaBlock {
    static Q(s) => '"' StrReplace(StrReplace(String(s), "\", "\\"), '"', '\"') '"'
    static N(v) => (v = Round(v)) ? String(Round(v)) : Format("{:.5f}", v)

    static Slot(slot) {
        if (slot.Count = 0)
            return "{}"
        return "{ weapon = " LuaBlock.Q(slot["weapon"]) ", scope = " LuaBlock.Q(slot["scope"])
            . ", barrel = " LuaBlock.Q(slot["barrel"]) ", grip = " LuaBlock.Q(slot["grip"]) " }"
    }

    static List(arr) {
        out := ""
        for v in arr
            out .= (A_Index > 1 ? ", " : "") LuaBlock.Q(v)
        return "{ " out " }"
    }

    static Aspect(w, h) {
        r := w / h
        for name, val in Map("32:9", 32 / 9, "21:9", 21 / 9, "16:9", 16 / 9, "16:10", 16 / 10, "4:3", 4 / 3)
            if (Abs(r - val) < 0.08)
                return name
        return w ":" h
    }

    ; Returns the complete text to paste into the Lua (markers included).
    static Build(rev) {
        g := Cfg.Data["game"]
        t := "-- >>> SPM_USER BEGIN (generated by SiegeOverlay.ahk; paste a new block over everything between the markers) >>>`n"
        t .= "local SPM_USER = {`n"
        t .= "    rev = " LuaBlock.Q(rev) ",`n"
        t .= "    dpi = " LuaBlock.N(g["dpi"]) ", fov = " LuaBlock.N(g["fov"]) ", ads = " LuaBlock.N(g["ads"]) ",`n"
        t .= "    sens = { h = " LuaBlock.N(g["sensH"]) ", v = " LuaBlock.N(g["sensV"]) " },`n"
        t .= "    resolution = { w = " LuaBlock.N(g["resW"]) ", h = " LuaBlock.N(g["resH"]) " },`n"
        t .= "    aspect = " LuaBlock.Q(LuaBlock.Aspect(g["resW"], g["resH"])) ",`n"
        pref := Cfg.Data["prefs"]
        t .= "    preferred = {`n"
        t .= "        scope = " (pref["scope"] = "AUTO" ? "{}" : LuaBlock.List([pref["scope"]])) ",`n"
        t .= "        barrel = " LuaBlock.List(LoadoutMgr.Chain("barrel")) ",`n"
        t .= "        grip = " LuaBlock.List(LoadoutMgr.Chain("grip")) ",`n"
        t .= "    },`n"
        st := Cfg.Data["state"]
        t .= "    side = " LuaBlock.Q(st["side"]) ",`n"
        if (st["operator"] != "")
            t .= "    operator = " LuaBlock.Q(st["operator"]) ",`n"
        t .= "    favorites = " LuaBlock.List(Cfg.Data["favorites"]) ",`n"
        t .= "    saved = {`n"
        for n, lo in Cfg.Data["saved"]
            t .= "        [" LuaBlock.Q(n) "] = { primary = " LuaBlock.Slot(lo["primary"]) ", secondary = " LuaBlock.Slot(lo["secondary"]) " },`n"
        t .= "    },`n"
        t .= "    loadouts = {`n"
        for n, rec in Cfg.Data["loadouts"] {
            t .= "        [" LuaBlock.Q(n) "] = { active = " LuaBlock.Q(rec["active"]) ", list = {`n"
            for e in rec["list"]
                t .= "            { name = " LuaBlock.Q(e["name"]) ", primary = " LuaBlock.Slot(e["primary"])
                    . ", secondary = " LuaBlock.Slot(e["secondary"]) " },`n"
            t .= "        } },`n"
        }
        t .= "    },`n"
        t .= "    recoil = {`n"
        for key, pr in Cfg.Data["learned"]
            t .= "        [" LuaBlock.Q(key) "] = { r = " LuaBlock.N(pr["r"]) ", y1 = " LuaBlock.N(pr["y1"]) ", y2 = " LuaBlock.N(pr["y2"])
                . ", tym1 = " LuaBlock.N(pr["tym1"]) ", tym2 = " LuaBlock.N(pr["tym2"]) ", side = " LuaBlock.N(pr["side"])
                . ", strength = " LuaBlock.N(pr["strength"]) ", late = " LuaBlock.N(pr["late"]) " },`n"
        t .= "    },`n"
        t .= "    calibration = {`n"
        for side, c in Cfg.Data["calibration"] {
            if Calib.Exportable(c)
                t .= "        " side " = { tlx = " LuaBlock.N(c["tlx"]) ", tly = " LuaBlock.N(c["tly"]) ", brx = " LuaBlock.N(c["brx"]) ", bry = " LuaBlock.N(c["bry"]) " },`n"
            else
                t .= "        -- " side " grid held back: it was captured in this app and the coordinate space is not verified yet`n"
        }
        t .= "    },`n"
        t .= "    keybinds = {`n"
        for act, b in Cfg.Data["luaKeybinds"]
            t .= "        " act " = { mod = " LuaBlock.Q(b["mod"]) ", button = " b["button"] " },`n"
        t .= "    },`n"
        t .= "}`n"
        t .= "-- <<< SPM_USER END <<<`n"
        return t
    }

    ; Where the user's siege_profile_manager.lua lives: remembered path, else next to this script,
    ; else ask once (the choice is remembered in the config).
    static FindLua() {
        p := Cfg.Get("lua.path", "")
        if (p != "" && FileExist(p))
            return p
        p := A_ScriptDir "\siege_profile_manager.lua"
        if FileExist(p) {
            Cfg.Set("lua.path", p)
            return p
        }
        p := FileSelect(1, A_ScriptDir, "Select your siege_profile_manager.lua (V2)", "Lua (*.lua)")
        if (p != "")
            Cfg.Set("lua.path", p)
        return p
    }

    ; The user's ENTIRE Lua script with the SPM_USER block replaced by one built from the current
    ; configuration. Everything outside the markers is copied byte for byte (line endings kept).
    ; Returns the script text, or "" with a reason in err.
    static FullScript(rev, &err) {
        err := ""
        path := LuaBlock.FindLua()
        if (path = "") {
            err := "Lua script not found (no file chosen)"
            return ""
        }
        try text := FileRead(path, "UTF-8")
        catch as e {
            err := "cannot read the Lua script: " e.Message
            return ""
        }
        beginMark := "-- >>> SPM_USER BEGIN"
        endMark := "-- <<< SPM_USER END <<<"
        b := InStr(text, beginMark)
        e2 := b ? InStr(text, endMark, false, b) : 0
        if (!b || !e2) {
            err := "that Lua file has no SPM_USER markers - use the V2 siege_profile_manager.lua"
            return ""
        }
        eol := InStr(text, "`r`n") ? "`r`n" : "`n"
        block := StrReplace(RTrim(LuaBlock.Build(rev), "`n"), "`n", eol)
        return SubStr(text, 1, b - 1) block SubStr(text, e2 + StrLen(endMark))
    }

    ; Every config save also rewrites the SPM_USER block inside the Lua file on disk (only when the block really
    ; changed), so a script you paste later always carries your latest calibration, loadouts and learned profiles.
    ; Everything outside the markers is left byte for byte. G HUB still needs the new script pasted once.
    static LastBody := ""
    static AutoSave() {
        p := Cfg.Get("lua.path", "")
        if (p = "" || !FileExist(p))
            return
        body := LuaBlock.Build("0")
        if (body = LuaBlock.LastBody)
            return
        text := LuaBlock.FullScript(A_Now, &err)
        if (text = "")
            return
        f := FileOpen(p, "w", "UTF-8-RAW")
        f.Write(text)
        f.Close()
        LuaBlock.LastBody := body
        Diag.Log("Lua file on disk updated with the current config")
    }

    ; Puts the complete script (with the user's config merged in) on the clipboard and marks the
    ; config as handed over. If the Lua file cannot be found/used, falls back to the block alone.
    ; Returns Map(rev, full, err).
    static Copy() {
        rev := A_Now
        text := LuaBlock.FullScript(rev, &err)
        full := (text != "")
        if !full
            text := LuaBlock.Build(rev)
        A_Clipboard := text
        try {
            f := FileOpen(App.Dir (full ? "\siege_profile_manager.merged.lua" : "\spm_user_block.lua"), "w", "UTF-8-RAW")
            f.Write(text)
            f.Close()
        }
        Cfg.Data["sync"]["copiedRev"] := rev
        Cfg.Rebase()
        return Map("rev", rev, "full", full, "err", err)
    }

    ; Toast shown after a copy (shared by the Home/Settings buttons and the wizard).
    static Announce(r) {
        if r["full"]
            Toast.Show("ok", "✓ FULL SCRIPT COPIED", "Your whole Lua script + your config", "G HUB: select all, paste, save", "")
        else
            Toast.Show("warn", "⚠ ONLY THE CONFIG BLOCK COPIED", r["err"], "Paste it over the SPM_USER markers", "")
    }
}

; ------------------------------------------------------------------------------
; 7. DBWIN LISTENER  (Windows debug-output receiver; same mechanism as Sysinternals DebugView)
;    The G HUB Lua calls OutputDebugMessage -> OutputDebugString. Windows publishes every debug
;    string through a shared 4 KB section "DBWIN_BUFFER" (a DWORD process id followed by the text)
;    and two events: DBWIN_BUFFER_READY (receiver -> sender: buffer is free) and DBWIN_DATA_READY
;    (sender -> receiver: text is there). Only ONE receiver can own it, so DebugView or any other
;    debug monitor must be closed while this runs.
; ------------------------------------------------------------------------------
class DbgListener {
    static Ready := false
    static Shared := false          ; another debug monitor already owns the buffer

    static Init() {
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

    ; Returns every SPMSTATE / SPMEVENT / SPMBEAT line received since the last call. After a
    ; message the sender needs a moment to write the next one, so we wait a few ms for bursts
    ; (state + event + beat per action) instead of making G HUB wait for the next poll.
    static Drain() {
        lines := []
        if !this.Ready
            return lines
        wait := 0
        while (DllCall("WaitForSingleObject", "Ptr", this.evData, "UInt", wait) = 0) {
            text := StrGet(this.view + 4, 4092, "CP0")
            DllCall("SetEvent", "Ptr", this.evReady)
            wait := 4
            pos := RegExMatch(text, "SPM(STATE|EVENT|BEAT)#")
            if pos
                lines.Push(Trim(SubStr(text, pos), "`r`n "))
        }
        return lines
    }
}

; ------------------------------------------------------------------------------
; 8. PROTOCOL 2 PARSER
;    KIND#seq|protocol=2|session=<id>|k=v|...|end=1
;    Anything malformed, truncated (no end=1), from another protocol version, or without a
;    session is rejected with a reason. Unknown keys are kept and ignored by the consumers.
; ------------------------------------------------------------------------------
class Proto {
    static Parse(line, &err) {
        err := ""
        parts := StrSplit(line, "|")
        head := parts.RemoveAt(1)
        pos := InStr(head, "#")
        if !pos {
            err := "no sequence marker"
            return ""
        }
        kind := SubStr(head, 1, pos - 1)
        seq := SubStr(head, pos + 1)
        if !(kind = "SPMSTATE" || kind = "SPMEVENT" || kind = "SPMBEAT") {
            err := "unknown packet kind " kind
            return ""
        }
        if !IsInteger(seq) {
            err := "bad sequence number"
            return ""
        }
        d := Map("_kind", kind, "_seq", Integer(seq))
        for p in parts {
            eq := InStr(p, "=")
            if (eq > 1)
                d[SubStr(p, 1, eq - 1)] := SubStr(p, eq + 1)
        }
        if !d.Has("end") {
            err := "truncated packet #" seq
            return ""
        }
        if !d.Has("protocol") {
            err := "protocol 1 (old Lua script) - update siege_profile_manager.lua"
            d["_legacy"] := 1
            return d
        }
        if (d["protocol"] != App.Protocol) {
            err := "unsupported protocol " d["protocol"]
            return d
        }
        if (!d.Has("session") || d["session"] = "") {
            err := "packet without session"
            return ""
        }
        if (kind = "SPMSTATE") {
            for k in ["enabled", "side", "operator", "slot", "primary", "secondary"]
                if !d.Has(k) {
                    err := "state packet missing '" k "'"
                    return ""
                }
        }
        if (kind = "SPMEVENT" && !d.Has("type")) {
            err := "event packet without type"
            return ""
        }
        return d
    }
}

; ------------------------------------------------------------------------------
; 9. LIVE STATE + LINK HEALTH
;    The Lua has no timer: it only runs (and sends) when a mouse event arrives, and every state
;    change happens inside such an event and is sent immediately. So silence does NOT mean the
;    data is stale - it only becomes suspect when G HUB itself is gone. Health is therefore:
;      WAITING    nothing received yet
;      CONNECTED  packet seen recently                          (green)
;      IDLE       no packet for a while, G HUB still running    (green, "idle Ns")
;      LOST       G HUB process gone, or extreme silence        (red; state shown as last known)
;      MISMATCH   packets from another protocol version         (amber)
; ------------------------------------------------------------------------------
class Live {
    static Data := Map()            ; latest valid SPMSTATE (empty until the first one)
    static Session := ""
    static Seq := 0
    static LastMs := 0              ; A_TickCount of the last valid packet
    static LastStateMs := 0
    static Count := 0
    static Dups := 0
    static Bad := 0
    static Status := "WAITING"
    static StatusWhy := ""
    static Protocol := 0
    static Sessions := 0
    static Restarts := 0
    static GHubOk := true
    static GHubCheckedMs := 0
    static IdleSec := 12
    static LostSec := 600
    static Recent := []             ; [{t, text}] newest last
    ; Firing bursts as reported by the Lua (burst_start / burst_end events). Informational only.
    static Burst := Map("active", 0, "t", 0, "recoil", 0, "rapid", 0, "weapon", "", "last", "", "lastT", 0)
    static DbWarned := false

    static Poll() {
        for line in DbgListener.Drain() {
            try Live.Ingest(line)
            catch as e
                Diag.Err(e, "packet")         ; one bad packet must never stop the others
        }
    }

    static Ingest(line) {
        pkt := Proto.Parse(line, &err)
        if (err != "") {
            Live.Bad++
            Diag.Log("rejected packet: " err)
            if IsObject(pkt) {                  ; a packet from another protocol version
                Live.Protocol := pkt.Has("protocol") ? pkt["protocol"] : 1
                Live.SetStatus("MISMATCH", err)
            }
            return
        }
        Live.Protocol := pkt["protocol"]
        sess := pkt["session"]
        if (sess != Live.Session) {
            if (Live.Session != "") {
                Live.Restarts++
                Diag.Log("Lua session changed " Live.Session " -> " sess " (G HUB / script restarted)")
                Note.Add("info", "G HUB RESTARTED", "New Lua session detected", "State refreshed")
            }
            Live.Session := sess
            Live.Sessions++
            Live.Seq := 0
            Live.Data := Map()          ; never show the previous session's state
            Live.DbWarned := false
        }
        seq := pkt["_seq"]
        if (seq <= Live.Seq) {
            Live.Dups++
            return                      ; duplicate or out-of-order (old) packet
        }
        Live.Seq := seq
        Live.LastMs := A_TickCount
        Live.Count++
        kind := pkt["_kind"]
        if (kind = "SPMSTATE")
            Live.ApplyState(pkt)
        else if (kind = "SPMEVENT")
            Live.ApplyEvent(pkt)
        Live.Touch()
    }

    ; A valid packet arrived: leave LOST/WAITING/MISMATCH.
    static Touch() {
        if (Live.Status != "CONNECTED")
            Live.SetStatus("CONNECTED", "")
    }

    static SetStatus(status, why) {
        old := Live.Status
        Live.StatusWhy := why
        if (status = old)
            return
        Live.Status := status
        Diag.Log("link " old " -> " status (why != "" ? " (" why ")" : ""))
        if (status = "LOST")
            Note.Add("error", "G HUB SIGNAL LOST", why, "Showing last known state")
        else if (status = "CONNECTED" && old = "LOST")
            Note.Add("ok", "CONNECTION RESTORED", "G HUB link is back", "")
        else if (status = "MISMATCH")
            Note.Add("warn", "PROTOCOL VERSION MISMATCH", why, "")
        View.Changed()
    }

    static GHubRunning() {
        if (A_TickCount - Live.GHubCheckedMs < 3000)
            return Live.GHubOk
        Live.GHubCheckedMs := A_TickCount
        Live.GHubOk := ProcessExist("lghub_agent.exe") || ProcessExist("lghub.exe") || ProcessExist("lghub_system_tray.exe")
        return Live.GHubOk
    }

    ; 1 Hz health check.
    static Tick() {
        if (Live.Status = "MISMATCH" || Live.Count = 0)
            return
        age := (A_TickCount - Live.LastMs) / 1000
        if !Live.GHubRunning()
            Live.SetStatus("LOST", "G HUB is not running")
        else if (age > Live.LostSec)
            Live.SetStatus("LOST", "no data for " Round(age / 60) " min")
        else if (age > Live.IdleSec) {
            if (Live.Status != "IDLE")
                Live.SetStatus("IDLE", "")
        } else if (Live.Status != "CONNECTED")
            Live.SetStatus("CONNECTED", "")
        if (Live.Status = "IDLE")
            View.Changed()                ; keeps the "idle Ns" text current
    }

    static Fresh() => (Live.Status = "CONNECTED" || Live.Status = "IDLE") && Live.Data.Count > 0
    static Get(key, def := "") => Live.Data.Has(key) ? Live.Data[key] : def
    static AgeMs() => Live.LastMs ? A_TickCount - Live.LastMs : -1

    ; Real (proper-case) operator name from the state's upper-case one.
    static OpName() {
        f := Db.Find(Live.Get("operator", ""))
        return IsObject(f) ? f["op"]["name"] : Live.Get("operator", "")
    }
    static Side() => Db.SideFromLua(Live.Get("side", "ATTACKER"))
    static Slot() => StrLower(Live.Get("slot", "PRIMARY"))
    static Att(kind, field) {
        v := Live.Get(kind "_" field, "-")
        return v = "-" ? "" : v
    }

    static ApplyState(pkt) {
        Live.Data := pkt
        Live.LastStateMs := A_TickCount
        if (pkt.Has("dbrev") && pkt["dbrev"] != Db.Rev && !Live.DbWarned) {
            Live.DbWarned := true
            Diag.Log("database mismatch: Lua " pkt["dbrev"] " / companion " Db.Rev)
            Note.Add("warn", "DATABASE MISMATCH", "Lua weapon/operator data differs", "Update SiegeOverlay.ahk")
        }
        Sync.FromState(pkt)
        Profiles.Note(pkt)
        Note.Flush()
        View.Changed()
    }

    static ApplyEvent(pkt) {
        evt := pkt["type"]
        if (evt = "burst_start" || evt = "burst_end") {     ; module activity: no toast, no log spam
            Sync.FromEvent(evt, pkt)
            View.Changed()
            return
        }
        Diag.Log("event " evt)
        Sync.FromEvent(evt, pkt)
        Note.Queue.Push(pkt)
        SetTimer(() => Note.Flush(), -300)     ; fallback if no snapshot follows
    }

    static Recent_Add(text) {
        Live.Recent.Push(Map("t", FormatTime(, "HH:mm:ss"), "text", text))
        while (Live.Recent.Length > 14)
            Live.Recent.RemoveAt(1)
    }
}

; ------------------------------------------------------------------------------
; 10. SYNC  (Lua state -> persistent config)
;     The config is the master for settings; changes made in the game (which the Lua reports as
;     events and snapshots) are recorded into it, so nothing done in-game is ever lost.
; ------------------------------------------------------------------------------
class Sync {
    static FromState(d) {
        f := Db.Find(d["operator"])
        if !IsObject(f)
            return
        opName := f["op"]["name"]
        side := f["side"]
        ; the operator the game is on + the loadout it reports for BOTH slots
        lo := Map()
        for kind in Db.Kinds {
            slot := Map()
            w := d.Get(kind, "NONE")
            if (w != "NONE" && w != "-") {
                slot["weapon"] := w
                for field in Db.Fields
                    slot[field] := Live.Att(kind, field)
            }
            lo[kind] := LoadoutMgr.Fix(opName, kind, slot)
        }
        Cfg.FromLua(Sync.Record.Bind(Sync, side, opName, lo))
        ; first run: adopt the Lua's game settings ONCE as the starting values of the setup wizard
        if (!Cfg.Get("setup.done", 0) && !Cfg.Get("setup.adopted", 0)) {
            Cfg.Data["setup"]["adopted"] := 1
            g := Cfg.Data["game"]
            for k, key in Map("dpi", "dpi", "sensH", "sens_h", "sensV", "sens_v", "fov", "fov", "ads", "ads")
                if (d.Has(key) && IsNumber(d[key]))
                    g[k] := d[key] + 0
            if (d.Has("res") && RegExMatch(d["res"], "^(\d+)x(\d+)$", &m)) {
                g["resW"] := Integer(m[1]), g["resH"] := Integer(m[2])
            }
        }
        ; favourites: adopt the Lua's list once (first snapshot ever); afterwards only via events
        if !Cfg.Data["favInit"] && d.Has("favorites") {
            Cfg.FromLua(Sync.AdoptFavorites.Bind(Sync, d["favorites"]))
        }
        for side3 in Db.Sides {
            luaText := d.Get("cal_" side3, "-")
            Cfg.FromLua(Calib.SetSrc.Bind(Calib, side3, luaText))
        }
        ; grid overrides the Lua already has (e.g. calibrated in game before this script existed)
        for side2 in Db.Sides {
            key := "cal_" side2
            if (d.Has(key) && d[key] != "-" && !Cfg.Data["calibration"].Has(side2))
                Cfg.FromLua(Sync.AdoptCal.Bind(Sync, side2, d[key]))
        }
    }

    ; Returns true when something changed (Cfg.FromLua only marks the config dirty then).
    static Record(side, opName, lo) {
        st := Cfg.Data["state"]
        changed := (st["side"] != side || st["operator"] != opName)
        st["side"] := side
        st["operator"] := opName
        if Cfg.SetSaved(opName, lo, false)
            changed := true
        return changed
    }

    static AdoptFavorites(text) {
        Cfg.Data["favorites"] := []
        for n in SplitList(text) {
            f := Db.Find(n)
            if (IsObject(f) && !IndexOf(Cfg.Data["favorites"], f["op"]["name"]))
                Cfg.Data["favorites"].Push(f["op"]["name"])
        }
        Cfg.Data["favInit"] := 1
        return true
    }

    static AdoptCal(side, text) {
        p := StrSplit(text, ",")
        if (p.Length = 4 && IsNumber(p[1]) && IsNumber(p[2]) && IsNumber(p[3]) && IsNumber(p[4]))
            Cfg.Data["calibration"][side] := Map("tlx", p[1] + 0, "tly", p[2] + 0, "brx", p[3] + 0, "bry", p[4] + 0
                , "res", Cfg.Data["game"]["resW"] "x" Cfg.Data["game"]["resH"], "src", "lua")
        else
            return false
        return true
    }

    static FromEvent(evt, e) {
        switch evt {
            case "favourite_changed":
                name := e.Get("operator", "")
                on := e.Get("on", "0") = "1"
                Cfg.FromLua(Sync.SetFav.Bind(Sync, name, on))
                Live.Recent_Add((on ? "★ Favourited " : "Unfavourited ") name)
            case "operator_changed":
                Live.Recent_Add("Operator → " e.Get("operator", "?"))
                if (e.Get("source", "") = "detect")
                    Calib.LastLua := e.Get("operator", "")
            case "weapon_changed":
                Live.Recent_Add(StrUpper(e.Get("slot", "")) " weapon → " e.Get("weapon", "?"))
            case "attachment_changed":
                Live.Recent_Add(StrUpper(e.Get("field", "")) " → " e.Get("value", "?"))
            case "slot_changed":
                Live.Recent_Add("Slot → " StrUpper(e.Get("slot", "")))
            case "side_changed":
                Live.Recent_Add("Side → " Db.SideLabel(Db.SideFromLua(e.Get("side", ""))))
            case "loadout_changed":
                Live.Recent_Add("Loadout → " e.Get("name", "?"))
            case "system_enabled", "system_disabled":
                Live.Recent_Add(evt = "system_enabled" ? "System enabled" : "System disabled")
            case "calibration_point":
                Calib.OnLuaPoint(e.Get("side", ""), Integer(e.Get("step", 1)), Float(e.Get("x", 0)), Float(e.Get("y", 0)))
            case "calibration_started":
                Calib.OnLuaStarted(e.Get("side", ""))
            case "calibration_complete":
                Calib.OnLuaComplete(e.Get("side", ""), Float(e.Get("tlx", 0)), Float(e.Get("tly", 0))
                    , Float(e.Get("brx", 0)), Float(e.Get("bry", 0)))
                Live.Recent_Add("Calibrated " Db.SideLabel(e.Get("side", "")))
            case "calibration_failed":
                Calib.OnLuaFailed(e.Get("side", ""), e.Get("reason", ""))
            case "calibration_reset":
                Calib.OnLuaReset(e.Get("side", ""))
            case "detect_result":
                Calib.OnLuaDetect(e)
            case "burst_start":
                Coach.OnLuaStart()
                ScreenCoach.OnStart()
                SightTrace.OnStart()
                if IsObject(Recorder.Cur) {
                    Recorder.Cur["macro"] := 1               ; the macro is moving the mouse during this burst
                    Recorder.Cur["recoil"] := e.Get("recoil", "0") = "1" ? 1 : 0
                }
                b := Live.Burst
                b["active"] := 1, b["t"] := A_TickCount, b["weapon"] := e.Get("weapon", "")
                b["recoil"] := e.Get("recoil", "0") = "1" ? 1 : 0
                b["rapid"] := e.Get("rapid", "0") = "1" ? 1 : 0
            case "burst_end":
                b := Live.Burst
                b["active"] := 0, b["lastT"] := A_TickCount
                b["last"] := Round(e.Get("ms", 0) / 1000, 1) " s, " e.Get("ticks", 0) " ticks, " e.Get("clicks", 0) " clicks"
                Coach.OnLuaEnd(e)
                SightTrace.OnEnd(e)
                ScreenCoach.OnEnd(e)
        }
    }

    static SetFav(name, on) {
        f := Db.Find(name)
        if !IsObject(f)
            return false
        real := f["op"]["name"]
        favs := Cfg.Data["favorites"]
        i := IndexOf(favs, real)
        if (on && !i)
            favs.Push(real)
        else if (!on && i)
            favs.RemoveAt(i)
        else
            return false
        return true
    }

    ; Human-readable state of the Lua's copy of the configuration.
    ;   returns [code, text]   code: OK | PENDING | OLD | NONE | UNKNOWN
    static LuaConfig() {
        if !Live.Data.Count
            return ["UNKNOWN", "waiting for the Lua"]
        rev := Live.Get("cfgrev", "none")
        copied := Cfg.Get("sync.copiedRev", "")
        if (rev = "none")
            return ["NONE", "Lua uses its built-in defaults (your config has not been pasted yet)"]
        if (rev != copied)
            return ["OLD", "Lua has an older config block (rev " rev ") - copy + paste the full script again"]
        if Cfg.Pending()
            return ["PENDING", "changes not yet in the Lua - copy + paste the full script"]
        return ["OK", "Lua config in sync (rev " rev ")"]
    }
}

; ------------------------------------------------------------------------------
; 11. NOTIFICATION QUEUE  (turns Lua events / link changes into toast cards)
;     Events are held until the next snapshot so the card shows the NEW loadout.
; ------------------------------------------------------------------------------
class Note {
    static Queue := []      ; alias used by Live (raw event packets); see Live.Queue

    static Add(kind, title, l1 := "", l2 := "", l3 := "") {
        Toast.Show(kind, title, l1, l2, l3)
    }

    static Flush() {
        q := Note.Queue
        Note.Queue := []
        for e in q
            Note.FromEvent(e)
    }

    static Att() {
        b := Live.Att(Live.Slot(), "barrel"), g := Live.Att(Live.Slot(), "grip")
        return (b != "" ? b : "-") " • " (g != "" ? g : "-")
    }

    static FromEvent(e) {
        evt := e["type"]
        op := StrUpper(e.Get("operator", Live.OpName()))
        wpn := Live.Get("weapon", "-")
        switch evt {
            case "operator_changed":
                det := e.Get("source", "") = "detect"
                Toast.Show("ok", det ? "✓ OPERATOR DETECTED" : "OPERATOR CHANGED", StrUpper(Live.OpName()), wpn, Note.Att())
            case "weapon_changed":
                Toast.Show("info", "WEAPON CHANGED", e.Get("weapon", wpn), StrUpper(e.Get("slot", "")), Note.Att())
            case "attachment_changed":
                Toast.Show("info", "ATTACHMENT CHANGED", StrUpper(e.Get("field", "")) " → " e.Get("value", ""), wpn, Note.Att())
            case "slot_changed":
                Toast.Show("info", "ACTIVE SLOT", StrUpper(e.Get("slot", "")), wpn, Note.Att())
            case "side_changed":
                Toast.Show("info", "SIDE CHANGED", Db.SideLabel(Db.SideFromLua(e.Get("side", ""))), StrUpper(Live.OpName()), "")
            case "loadout_changed":
                Toast.Show("ok", "LOADOUT CHANGED", e.Get("name", ""), e.Get("index", "") " / " e.Get("count", ""), Live.Get("weapon", ""))
            case "favourite_changed":
                on := e.Get("on", "0") = "1"
                Toast.Show("ok", on ? "★ FAVOURITE ADDED" : "FAVOURITE REMOVED", op, "", "")
            case "calibration_started":
                Toast.Show("info", "CALIBRATION STARTED", Db.SideLabel(e.Get("side", "")) " GRID", "Step 1/2: TOP LEFT", "")
            case "calibration_point":
                Toast.Show("info", "CALIBRATION POINT " e.Get("step", "") "/2", Db.SideLabel(e.Get("side", "")) " GRID", "", "")
            case "calibration_complete":
                Toast.Show("ok", "✓ CALIBRATION COMPLETE", Db.SideLabel(e.Get("side", "")) " GRID", "Saved to configuration", "")
            case "calibration_failed":
                Toast.Show("warn", "⚠ CALIBRATION", e.Get("reason", "failed"), "", "")
            case "calibration_reset":
                Toast.Show("info", "CALIBRATION RESET", Db.SideLabel(e.Get("side", "")) " GRID uses the preset", "", "")
            case "system_enabled":
                Toast.Show("ok", "SYSTEM ENABLED", "", "", "")
            case "system_disabled":
                Toast.Show("warn", "SYSTEM DISABLED", "Macros are off", "", "")
            case "warning":
                msg := RegExReplace(e.Get("msg", ""), "^[^A-Za-z0-9]+", "")
                Toast.Show("warn", "⚠ WARNING", SubStr(msg, 1, 60), SubStr(msg, 61, 60), "")
        }
    }
}

; ------------------------------------------------------------------------------
; 12. UI TOOLKIT  (dark theme helpers). All windows use -DPIScale and scale themselves:
;     Ui.S(px) = px * user UI scale * Windows DPI factor, so 100% / 125% / 150% displays and the
;     UI-scale setting all behave the same way. Font sizes only take the UI scale (Windows applies
;     its own DPI to point sizes).
; ------------------------------------------------------------------------------
class Ui {
    static Scale := 1.0
    static Recalc() {
        user := Cfg.Num("ui.scale", 1.0)
        dpi := A_ScreenDPI / 96
        ; small screens: shrink so the 980x660 control centre always fits the work area
        MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
        fit := Min(1, (r - l - 40) / (980 * user * dpi), (b - t - 60) / (660 * user * dpi))
        Ui.Scale := user * dpi * fit
        Ui.Cache := Map()
    }
    static S(v) => Round(v * Ui.Scale)
    static Pt(v) => Max(7, Round(v * Cfg.Num("ui.scale", 1.0)))

    ; Text with a solid background (so it never leaves repaint artefacts on a card).
    static Txt(g, x, y, w, h, text, size := 9, style := "Norm", color := "F5F7FA", bg := "0C0E13", opts := "", face := "Segoe UI") {
        g.SetFont("s" Ui.Pt(size) " " style " c" color, face)
        return g.AddText("x" Ui.S(x) " y" Ui.S(y) " w" Ui.S(w) " h" Ui.S(h) " +0x200 +0x4000 Background" bg " " opts, text)
    }

    static Mono(g, x, y, w, h, text, size := 9, color := "F5F7FA", bg := "0C0E13") {
        g.SetFont("s" Ui.Pt(size) " Norm c" color, "Consolas")
        return g.AddText("x" Ui.S(x) " y" Ui.S(y) " w" Ui.S(w) " h" Ui.S(h) " +0x4000 Background" bg, text)
    }

    ; "RRGGBB" mixed with "RRGGBB" (t = 0..1)
    static Mix(c1, c2, t) {
        r1 := Integer("0x" SubStr(c1, 1, 2)), g1 := Integer("0x" SubStr(c1, 3, 2)), b1 := Integer("0x" SubStr(c1, 5, 2))
        r2 := Integer("0x" SubStr(c2, 1, 2)), g2 := Integer("0x" SubStr(c2, 3, 2)), b2 := Integer("0x" SubStr(c2, 5, 2))
        return Format("{:02X}{:02X}{:02X}", Round(r1 + (r2 - r1) * t), Round(g1 + (g2 - g1) * t), Round(b1 + (b2 - b1) * t))
    }

    ; A horizontal gradient bar made of thin solid strips (AHK has no gradient control). Returns the strips.
    static Gradient(g, x, y, w, h, c1, c2, steps := 40) {
        out := []
        loop steps {
            x0 := Ui.S(x + (A_Index - 1) * w / steps)
            x1 := Ui.S(x + A_Index * w / steps)
            col := Ui.Mix(c1, c2, steps > 1 ? (A_Index - 1) / (steps - 1) : 0)
            out.Push(g.AddText("x" x0 " y" Ui.S(y) " w" (x1 - x0 + 1) " h" Ui.S(h) " Background" col, ""))
        }
        return out
    }

    ; "RRGGBB" -> the BGR integer Windows wants
    static Rgb(hex) => (Integer("0x" SubStr(hex, 5, 2)) << 16) | (Integer("0x" SubStr(hex, 3, 2)) << 8) | Integer("0x" SubStr(hex, 1, 2))

    ; Windows 11 window chrome: rounded corners, coloured border / title bar. Silently ignored on older Windows.
    static Chrome(g, caption := "", border := "", text := "") {
        try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g.Hwnd, "Int", 33, "Int*", 2, "Int", 4)                 ; DWMWCP_ROUND
        if (border != "")
            try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g.Hwnd, "Int", 34, "UInt*", Ui.Rgb(border), "Int", 4)   ; border colour
        if (caption != "")
            try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g.Hwnd, "Int", 35, "UInt*", Ui.Rgb(caption), "Int", 4)  ; title bar colour
        if (text != "")
            try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g.Hwnd, "Int", 36, "UInt*", Ui.Rgb(text), "Int", 4)     ; title text colour
    }

    static Rect(g, x, y, w, h, color) {
        return g.AddText("x" Ui.S(x) " y" Ui.S(y) " w" Ui.S(w) " h" Ui.S(h) " Background" color, "")
    }

    ; Clickable flat button. kind: n normal, p primary (green), d danger.
    static Btn(g, x, y, w, h, text, cb, kind := "n") {
        bg := kind = "p" ? Clr.Accent : kind = "d" ? "33191D" : Clr.Panel2
        fg := kind = "p" ? Clr.Ink : kind = "d" ? Clr.Red : Clr.Text
        g.SetFont("s" Ui.Pt(9) " Bold c" fg, "Segoe UI")
        t := g.AddText("x" Ui.S(x) " y" Ui.S(y) " w" Ui.S(w) " h" Ui.S(h) " +0x200 +0x100 Center Background" bg, text)
        t.OnEvent("Click", (*) => cb.Call())
        return t
    }

    ; Changes a text control's colours after creation (background may not repaint on every Windows
    ; build, so the text colour always carries the meaning as well).
    static Cache := Map()
    static Paint(ctrl, fg, bg := "") {
        key := fg "|" bg
        if (Ui.Cache.Has(ctrl.Hwnd) && Ui.Cache[ctrl.Hwnd] = key)
            return                              ; unchanged: skip (avoids flicker)
        Ui.Cache[ctrl.Hwnd] := key
        try ctrl.SetFont("c" fg)
        if (bg != "") {
            try ctrl.Opt("+Background" bg)
        }
        try ctrl.Redraw()
    }

    static DarkTheme(ctrl, kind := "Explorer") {
        try DllCall("uxtheme\SetWindowTheme", "Ptr", ctrl.Hwnd, "Str", "DarkMode_" kind, "Ptr", 0)
    }

    static DarkTitle(g) {
        try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g.Hwnd, "Int", 20, "Int*", 1, "Int", 4)
    }

    static Cue(edit, text) {
        try SendMessage(0x1501, 1, StrPtr(text), edit)
    }

    static Edit(g, x, y, w, h, text := "", opts := "") {
        g.SetFont("s" Ui.Pt(10) " Norm c" Clr.Text, "Segoe UI")
        e := g.AddEdit("x" Ui.S(x) " y" Ui.S(y) " w" Ui.S(w) " h" Ui.S(h) " Background" Clr.Panel2 " " opts, text)
        Ui.DarkTheme(e, "CFD")
        return e
    }

    static Drop(g, x, y, w, items, opts := "") {
        g.SetFont("s" Ui.Pt(9) " Norm c" Clr.Text, "Segoe UI")
        d := g.AddDropDownList("x" Ui.S(x) " y" Ui.S(y) " w" Ui.S(w) " r12 Background" Clr.Panel2 " " opts, items)
        Ui.DarkTheme(d, "CFD")
        return d
    }

    static List(g, x, y, w, h, cols, opts := "") {
        g.SetFont("s" Ui.Pt(9) " Norm c" Clr.Text, "Segoe UI")
        lv := g.AddListView("x" Ui.S(x) " y" Ui.S(y) " w" Ui.S(w) " h" Ui.S(h) " -Hdr -Multi +LV0x10000 Background" Clr.Panel " c" Clr.Text " " opts, cols)
        Ui.DarkTheme(lv, "Explorer")
        return lv
    }

    ; Selects the row of a ListView whose first hidden key matches (helper for refreshes).
    static Clear(lv) {
        lv.Delete()
    }
}

; Segmented selector (ATTACK | DEFENCE etc.).
class Seg {
    __New(g, x, y, w, h, items, cb) {
        this.Items := items
        this.Cb := cb
        this.Btns := []
        this.Sel := 1
        n := items.Length
        cw := w // n
        for i, label in items {
            t := Ui.Txt(g, x + (i - 1) * cw, y, cw - 2, h, label, 9, "Bold", Clr.Dim, Clr.Panel2, "+0x100 Center")
            t.OnEvent("Click", this.Pick.Bind(this, i))
            this.Btns.Push(t)
        }
        this.Paint()
    }
    Pick(i, *) {
        this.Set(i)
        this.Cb.Call(this.Items[i])
    }
    Set(i) {
        this.Sel := i
        this.Paint()
    }
    SetByName(name) {
        i := IndexOf(this.Items, name)
        if i
            this.Set(i)
    }
    Paint() {
        for i, t in this.Btns
            Ui.Paint(t, i = this.Sel ? Clr.Accent : Clr.Dim, i = this.Sel ? Clr.Sel : Clr.Panel2)
    }
    Show(v) {
        for t in this.Btns
            t.Visible := v
    }
}

; Clickable checkbox drawn as text ("☑ label" / "☐ label").
class Toggle {
    __New(g, x, y, w, label, on, cb, bg := "0C0E13") {
        this.Label := label
        this.On := on ? 1 : 0
        this.Cb := cb
        this.Ctl := Ui.Txt(g, x, y, w, 24, "", 10, "Norm", Clr.Text, bg, "+0x100")
        this.Ctl.OnEvent("Click", this.Flip.Bind(this))
        this.Paint()
    }
    Flip(*) {
        this.On := this.On ? 0 : 1
        this.Paint()
        this.Cb.Call(this.On)
    }
    Set(on) {
        this.On := on ? 1 : 0
        this.Paint()
    }
    Paint() {
        this.Ctl.Text := (this.On ? "☑  " : "☐  ") this.Label
        Ui.Paint(this.Ctl, this.On ? Clr.Accent : Clr.Dim)
    }
}

; ------------------------------------------------------------------------------
; 13. TOAST NOTIFICATIONS  (click-through card next to the HUD, auto-hides)
; ------------------------------------------------------------------------------
class Toast {
    static Gui := ""
    static Ctl := Map()
    static Last := ""
    static LastMs := 0
    static Fn := ""
    static W := 300

    static Build() {
        if IsObject(Toast.Gui)
            try Toast.Gui.Destroy()
        g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 +E0x08000000 -DPIScale", "SPM Toast")
        g.MarginX := 0, g.MarginY := 0
        g.BackColor := Clr.Panel
        c := Map()
        c["bar"] := Ui.Rect(g, 0, 0, 4, 100, Clr.Green)
        c["title"] := Ui.Txt(g, 16, 10, Toast.W - 28, 20, "", 9, "Bold", Clr.Green, Clr.Panel)
        c["l1"] := Ui.Txt(g, 16, 32, Toast.W - 28, 28, "", 15, "Bold", Clr.Text, Clr.Panel)
        c["l2"] := Ui.Txt(g, 16, 62, Toast.W - 28, 20, "", 10, "Norm", Clr.Text, Clr.Panel)
        c["l3"] := Ui.Txt(g, 16, 82, Toast.W - 28, 20, "", 9, "Norm", Clr.Dim, Clr.Panel)
        for e in [Ui.Rect(g, 0, 0, Toast.W, 1, Clr.Line), Ui.Rect(g, 0, 0, 1, 120, Clr.Line)]
            c[A_Index "e"] := e
        Ui.Gradient(g, 0, 0, Toast.W, 3, Clr.Accent, Clr.Accent2, 24)
        Toast.Gui := g
        Toast.Ctl := c
        g.Show("Hide w" Ui.S(Toast.W) " h" Ui.S(110))
        Ui.Chrome(g)
    }

    ; kind: ok | info | warn | error
    static Show(kind, title, l1 := "", l2 := "", l3 := "") {
        if (!Cfg.Get("ui.notifications", 1) || View.Hidden || !IsObject(Toast.Gui))
            return
        key := kind "|" title "|" l1 "|" l2 "|" l3
        if (key = Toast.Last && A_TickCount - Toast.LastMs < 1500)
            return                              ; identical toast just shown: do not spam
        Toast.Last := key, Toast.LastMs := A_TickCount
        col := kind = "ok" ? Clr.Accent : kind = "warn" ? Clr.Amber : kind = "error" ? Clr.Red : Clr.Blue
        c := Toast.Ctl
        SetText(c["title"], title)
        Ui.Paint(c["title"], col)
        SetText(c["l1"], l1)
        SetText(c["l2"], l2)
        SetText(c["l3"], l3)
        Ui.Paint(c["bar"], col, col)
        lines := (l3 != "" ? 3 : l2 != "" ? 2 : l1 != "" ? 1 : 0)
        h := 12 + 22 + (lines >= 1 ? 30 : 0) + (lines >= 2 ? 22 : 0) + (lines >= 3 ? 20 : 0) + 10
        c["bar"].Move(0, 0, Ui.S(4), Ui.S(h))
        c["1e"].Move(0, 0, Ui.S(Toast.W), 1)
        c["2e"].Move(0, 0, 1, Ui.S(h))
        pos := Toast.Position(Ui.S(Toast.W), Ui.S(h))
        Toast.Gui.Show("NA x" pos[1] " y" pos[2] " w" Ui.S(Toast.W) " h" Ui.S(h))
        Toast.Alpha := 40                                       ; quick fade-in
        WinSetTransparent(Toast.Alpha, "ahk_id " Toast.Gui.Hwnd)
        if !IsObject(Toast.FadeFn)
            Toast.FadeFn := ObjBindMethod(Toast, "Fade")
        SetTimer(Toast.FadeFn, 16)
        if !IsObject(Toast.Fn)
            Toast.Fn := ObjBindMethod(Toast, "Hide")
        SetTimer(Toast.Fn, -(kind = "warn" || kind = "error" ? 4200 : 2600))
    }

    static Alpha := 245
    static FadeFn := ""
    static Fade() {
        Toast.Alpha += 50
        if (Toast.Alpha >= 245) {
            Toast.Alpha := 245
            SetTimer(Toast.FadeFn, 0)
        }
        try WinSetTransparent(Toast.Alpha, "ahk_id " Toast.Gui.Hwnd)
    }

    static Hide() {
        if IsObject(Toast.Gui)
            try Toast.Gui.Hide()
    }

    ; Below the HUD when it sits at the top of the screen, above it when at the bottom.
    static Position(w, h) {
        r := Hud.Rect()
        MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &rr, &b)
        gap := Ui.S(8)
        top := InStr(Cfg.Get("ui.hudPos", "Top Right"), "Top") || (Cfg.Get("ui.hudPos") = "Custom" && r[2] < (t + b) / 2)
        y := top ? r[2] + r[4] + gap : r[2] - h - gap
        right := InStr(Cfg.Get("ui.hudPos", "Top Right"), "Right") || (Cfg.Get("ui.hudPos") = "Custom" && r[1] > (l + rr) / 2)
        x := right ? r[1] + r[3] - w : r[1]
        return [Clamp(x, l, rr - w), Clamp(y, t, b - h)]
    }
}

; ------------------------------------------------------------------------------
; 14. COMPACT HUD  (small, click-through, never takes focus)
; ------------------------------------------------------------------------------
class Hud {
    static Gui := ""
    static Ctl := Map()
    static Shown := false
    static W := 250
    static X := 0
    static Y := 0
    static PW := 0
    static PH := 0

    static SizeFactor() {
        s := Cfg.Get("ui.hudSize", "Normal")
        return s = "Compact" ? 0.86 : s = "Large" ? 1.28 : 1.0
    }

    ; HUD-only scale on top of the UI scale (size preset x scale slider)
    static Sc() => Hud.SizeFactor() * Cfg.Num("ui.hudScale", 1.0)

    static Build() {
        if IsObject(Hud.Gui)
            try Hud.Gui.Destroy()
        sc := Hud.Sc()
        g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 +E0x08000000 -DPIScale", "Siege Profile Manager HUD")
        g.MarginX := 0, g.MarginY := 0
        g.BackColor := Clr.Panel
        c := Map()
        pw := Round(Hud.W * sc)                       ; design width in Ui units
        c["bar"] := Ui.Rect(g, 0, 0, 4, 10, Clr.Green)
        for n in ["bt", "bb", "bl", "br"]
            c[n] := Ui.Rect(g, 0, 0, 10, 1, Clr.Line)
        f := (v) => v * sc
        c["title"] := Ui.Txt(g, 16, 10, pw - 50, f(16), "SIEGE PROFILE MANAGER", f(7.5), "Bold", Clr.Mute, Clr.Panel)
        c["dot"] := Ui.Txt(g, pw - 30, 8, 20, f(18), "●", f(10), "Norm", Clr.Green, Clr.Panel, "Right")
        c["op"] := Ui.Txt(g, 16, 30, pw - 28, f(28), "", f(15), "Bold", Clr.Text, Clr.Panel, "", "Segoe UI Black")
        c["weapon"] := Ui.Txt(g, 16, 60, pw - 28, f(20), "", f(10.5), "Bold", Clr.Text, Clr.Panel)
        c["scope"] := Ui.Txt(g, 16, 82, pw - 28, f(18), "", f(9), "Norm", Clr.Dim, Clr.Panel)
        c["att"] := Ui.Txt(g, 16, 100, pw - 28, f(18), "", f(9), "Norm", Clr.Dim, Clr.Panel)
        c["cal"] := Ui.Txt(g, 16, 120, pw - 28, f(18), "", f(8.5), "Norm", Clr.Mute, Clr.Panel)
        c["dbg"] := Ui.Txt(g, 16, 138, pw - 28, f(18), "", f(8), "Norm", Clr.Mute, Clr.Panel)
        c["status"] := Ui.Txt(g, 16, 160, pw - 28, f(22), "", f(9.5), "Bold", Clr.Green, Clr.Panel)
        ; recoil tuning panel (only while the Lua's tune mode is on)
        c["t1"] := Ui.Txt(g, 16, 160, pw - 28, f(20), "", f(9.5), "Bold", Clr.Amber, Clr.Panel)
        c["t2"] := Ui.Txt(g, 16, 160, pw - 28, f(40), "", f(9.5), "Bold", Clr.Text, Clr.Panel)
        c["t3"] := Ui.Txt(g, 16, 160, pw - 28, f(36), "", f(8.5), "Norm", Clr.Dim, Clr.Panel)
        c["rec"] := Ui.Txt(g, 16, 160, pw - 28, f(20), "", f(9.5), "Bold", Clr.Red, Clr.Panel)
        cw := Round((pw - 28) / 4)
        loop 4                                    ; module status dots (recoil / jitter / rapid / slot sync)
            c["m" A_Index] := Ui.Txt(g, 16 + (A_Index - 1) * cw, 160, cw, f(16), "", f(8), "Bold", Clr.Mute, Clr.Panel)
        c["t2"].Opt("-0x200 -0x4000")            ; several lines: no vertical centring / ellipsis
        c["t3"].Opt("-0x200 -0x4000")
        Ui.Gradient(g, 0, 0, pw, 3, Clr.Accent, Clr.Accent2, 28)
        Hud.Gui := g
        Hud.Ctl := c
        Hud.PW := pw
        g.Show("Hide w" Ui.S(pw) " h" Ui.S(100))
        Ui.Chrome(g)
        WinSetTransparent(Cfg.Num("ui.opacity", 235), "ahk_id " g.Hwnd)
    }

    ; Four small status dots: green = enabled, cyan = firing right now, amber = unavailable, grey = off / unknown.
    static PlaceMods(y, sc) {
        c := Hud.Ctl
        cw := Round((Hud.PW - 28) / 4)
        b := Live.Burst
        for i, d in [["RCL", "m_recoil", "recoil"], ["JIT", "m_jitter", ""], ["RPD", "m_rapid", "rapid"], ["SLT", "m_slotsync", ""]] {
            ms := (Live.Fresh() && Live.Data.Has(d[2])) ? Live.Data[d[2]] : ""
            if (ms = "ENABLED" && d[3] != "" && b["active"] && b[d[3]] = 1)
                ms := "ACTIVE"
            ctl := c["m" i]
            SetText(ctl, "● " d[1])
            Ui.Paint(ctl, ms = "ENABLED" ? Clr.Green : ms = "ACTIVE" ? Clr.Accent : ms = "UNAVAILABLE" ? Clr.Amber : Clr.Mute)
            ctl.Move(Ui.S(16 + (i - 1) * cw), Ui.S(y), Ui.S(cw), Ui.S(16 * sc))
            ctl.Visible := true
        }
    }

    ; [x, y, w, h] in screen pixels (used by the toast to sit next to the HUD).
    static Rect() => [Hud.X, Hud.Y, Hud.PW ? Ui.S(Hud.PW) : Ui.S(250), Hud.PH ? Hud.PH : Ui.S(160)]

    static Render() {
        if !IsObject(Hud.Gui)
            return
        c := Hud.Ctl
        sc := Hud.Sc()
        sec := Cfg.Get("ui.sections")
        st := Live.Status
        hasData := Live.Data.Count > 0
        stale := hasData && !Live.Fresh()
        dim := stale
        txt := dim ? Clr.Mute : Clr.Text, sub := dim ? Clr.Mute : Clr.Dim

        ; header dot / accent = connection health
        col := (st = "CONNECTED" || st = "IDLE") ? Clr.Green : st = "LOST" ? Clr.Red : Clr.Amber
        Ui.Paint(c["dot"], col)
        Ui.Paint(c["bar"], col, col)

        ; --- rows -----------------------------------------------------------------
        rows := []                                      ; [ctrl, text, color, designHeight]
        if !hasData {
            rows.Push([c["op"], "WAITING FOR G HUB", Clr.Amber, 28])
            rows.Push([c["weapon"], "Press RALT + left click once", Clr.Dim, 20])
        } else {
            if sec["operator"] {
                fav := Cfg.Get("favorites").Length && IndexOf(Cfg.Get("favorites"), Live.OpName()) ? "★ " : ""
                rows.Push([c["op"], fav StrUpper(Live.OpName()), txt, 28])
            }
            slot := Live.Slot()
            w := Live.Get("weapon", "-")
            if sec["weapon"]
                rows.Push([c["weapon"], w " • " StrUpper(slot), txt, 20])
            if sec["attachments"] {
                sc1 := Live.Get("scope", "-"), b := Live.Get("barrel", "-"), gp := Live.Get("grip", "-")
                rows.Push([c["scope"], sc1 = "-" ? "no sight" : sc1, sub, 18])
                rows.Push([c["att"], (b = "-" ? "no barrel" : b) " • " (gp = "-" ? "no grip" : gp), sub, 18])
            }
        }
        if (sec["calibration"] && hasData)
            rows.Push([c["cal"], "GRID  ATK " Calib.Short("attackers") "   DEF " Calib.Short("defenders"), sub, 18])
        if (sec["debug"] && hasData)
            rows.Push([c["dbg"], "#" Live.Seq "  " SubStr(Live.Session, 1, 6) "  " Live.AgeMs() " ms", sub, 18])

        ; --- recoil tuning panel: which button does what, without looking away ------
        if (hasData && Live.Get("tune", "0") = "1") {
            rows.Push([c["t1"], "TUNING " Live.Get("tune_step", "") "   " Live.Get("tune_name", "") " = " Live.Get("tune_val", ""), Clr.Amber, 20])
            rows.Push([c["t2"], StrReplace(Live.Get("tune_ask", ""), "    ", "`n"), Clr.Text, 40])
            rows.Push([c["t3"], Live.Get("tune_next", "") "`n" Live.Get("tune_reset", ""), sub, 36])
        }

        if Recorder.On {
            key := Recorder.Key()
            r := Coach.Result
            rows.Push([c["rec"], "● COACH  " (key != "" ? StrSplit(key, ":")[1] : "-") (IsObject(r) ? "  ·  " Round(r["acc"]) "%" : ""), Clr.Accent, 20])
        }

        ; --- status line ----------------------------------------------------------
        statusText := "", statusCol := Clr.Green
        if (sec["connection"] || !hasData || st != "CONNECTED" && st != "IDLE") {
            if (st = "WAITING")
                statusText := "● WAITING", statusCol := Clr.Amber
            else if (st = "MISMATCH")
                statusText := "● PROTOCOL MISMATCH", statusCol := Clr.Amber
            else if (st = "LOST")
                statusText := "● SIGNAL LOST", statusCol := Clr.Red
            else if (Live.Get("enabled") = "0")
                statusText := "● SYSTEM OFF", statusCol := Clr.Red
            else if (Live.Get("cal_active", "-") != "-")
                statusText := "● CALIBRATING", statusCol := Clr.Amber
            else {
                statusText := SubStr(Live.Get("recoil", ""), 1, 5) = "READY" ? "● READY" : "● IDLE"
                statusCol := statusText = "● READY" ? Clr.Green : Clr.Dim
                if (st = "IDLE")
                    statusText .= "  ·  idle " Round(Live.AgeMs() / 1000) "s"
            }
        }
        if (sec.Has("modules") && sec["modules"] && hasData)
            rows.Push(["MODS", "", "", 18])
        if (statusText != "")
            rows.Push([c["status"], statusText, statusCol, 22])

        ; --- layout ---------------------------------------------------------------
        for n in ["op", "weapon", "scope", "att", "cal", "dbg", "status", "t1", "t2", "t3", "rec", "m1", "m2", "m3", "m4"]
            c[n].Visible := false
        y := 30
        pw := Hud.PW
        for r in rows {
            if (Type(r[1]) = "String") {                    ; the module-dots row
                Hud.PlaceMods(y, sc)
                y += 18 * sc + 2
                continue
            }
            ctl := r[1]
            SetText(ctl, r[2])
            Ui.Paint(ctl, r[3])
            ctl.Move(Ui.S(16), Ui.S(y), Ui.S(pw - 28), Ui.S(r[4] * sc))
            ctl.Visible := true
            y += r[4] * sc + (ctl == c["status"] ? 0 : 2)
        }
        showHeader := true
        c["dot"].Visible := (sec["connection"] || !hasData || (st != "CONNECTED" && st != "IDLE"))
        c["title"].Visible := showHeader
        h := Ui.S(y + 12)
        w := Ui.S(pw)
        c["bar"].Move(0, 0, Ui.S(4), h)
        c["bt"].Move(0, 0, w, 1), c["bb"].Move(0, h - 1, w, 1)
        c["bl"].Move(0, 0, 1, h), c["br"].Move(w - 1, 0, 1, h)
        Hud.PH := h
        pos := Hud.Anchor(w, h)
        Hud.X := pos[1], Hud.Y := pos[2]
        if Hud.Shown
            Hud.Gui.Show("NA x" pos[1] " y" pos[2] " w" w " h" h)
        Hud.Gui.Opt("+AlwaysOnTop")
        WinSetTransparent(Cfg.Num("ui.opacity", 235), "ahk_id " Hud.Gui.Hwnd)
    }

    static Anchor(w, h) {
        MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
        m := Ui.S(20)
        switch Cfg.Get("ui.hudPos", "Top Right") {
            case "Top Left":     return [l + m, t + m]
            case "Bottom Left":  return [l + m, b - h - m]
            case "Bottom Right": return [r - w - m, b - h - m]
            case "Custom":       return [Clamp(Cfg.Num("ui.hudX", 40), l, r - w), Clamp(Cfg.Num("ui.hudY", 40), t, b - h)]
        }
        return [r - w - m, t + m]
    }

    static Show() {
        if !IsObject(Hud.Gui)
            return
        Hud.Shown := true
        Hud.Render()
        pos := Hud.Anchor(Ui.S(Hud.PW), Hud.PH)
        Hud.Gui.Show("NA x" pos[1] " y" pos[2] " w" Ui.S(Hud.PW) " h" Hud.PH)
    }

    static Hide() {
        Hud.Shown := false
        if IsObject(Hud.Gui)
            try Hud.Gui.Hide()
    }

    ; Borderless games can push other windows above us: re-assert the Z-order (cheap).
    static KeepOnTop() {
        if (Hud.Shown && IsObject(Hud.Gui))
            try WinSetAlwaysOnTop(true, "ahk_id " Hud.Gui.Hwnd)
    }
}

; ------------------------------------------------------------------------------
; 15. CONTROL CENTRE  (full window: HOME / OPERATORS / LOADOUTS / CALIBRATION / HUD /
;                      SETTINGS / HOTKEYS / DIAGNOSTICS)
; ------------------------------------------------------------------------------
class Center {
    static Gui := ""
    static Ctl := Map()             ; named controls
    static Pages := Map()           ; page -> [controls]
    static Nav := Map()
    static NavBar := Map()
    static Glyph := Map("HOME", "◆", "OPERATORS", "◈", "LOADOUTS", "▤", "CALIBRATION", "⌖", "RECOIL", "◉"
        , "HUD", "▣", "SETTINGS", "⚙", "HOTKEYS", "⌨", "DIAGNOSTICS", "≣")
    static Chips := []
    static ChipDefs := [["RECOIL", "m_recoil"], ["RAPID FIRE", "m_rapid"], ["JITTER", "m_jitter"]
        , ["SLOT SYNC", "m_slotsync"], ["DETECT", "m_detect"], ["SYSTEM", "m_system"]]
    static Names := ["HOME", "OPERATORS", "LOADOUTS", "CALIBRATION", "RECOIL", "HUD", "SETTINGS", "HOTKEYS", "DIAGNOSTICS"]
    static Cur := "HOME"
    static Guard := false           ; true while the code (not the user) changes a control
    static W := 980
    static H := 660
    ; browsing state (shared by OPERATORS and LOADOUTS)
    static Op := ""
    static OpSide := "attackers"
    static Slot := "primary"
    static Search := ""
    static FavOnly := false
    static OpRows := []
    static LoRows := []
    static LoThis := false
    static LoSearch := ""
    static Segs := Map()
    static Toggles := Map()
    static Visible := false
    static HkRows := []

    static Reg(page, ctrl) {
        if !Center.Pages.Has(page)
            Center.Pages[page] := []
        Center.Pages[page].Push(ctrl)
        return ctrl
    }

    static Card(add, g, x, y, w, h, title) {
        add(Ui.Rect(g, x, y, w, h, Clr.Panel))
        add(Ui.Txt(g, x + 14, y + 8, w - 28, 20, title, 8, "Bold", Clr.Mute, Clr.Panel))
    }

    static Build() {
        if IsObject(Center.Gui)
            try Center.Gui.Destroy()
        g := Gui("-DPIScale", App.Name)
        g.MarginX := 0, g.MarginY := 0
        g.BackColor := Clr.Bg
        Center.Gui := g
        Center.Ctl := Map(), Center.Pages := Map(), Center.Nav := Map(), Center.NavBar := Map(), Center.Segs := Map(), Center.Toggles := Map()
        Center.Chips := []
        Center.Cur := Cfg.Get("ui.page", "HOME")
        if !IndexOf(Center.Names, Center.Cur)
            Center.Cur := "HOME"
        Center.OpSide := Cfg.Get("state.side", "attackers")
        if (Center.Op = "")
            Center.Op := Cfg.Get("state.operator", "")

        ; --- header ---------------------------------------------------------------
        Ui.Rect(g, 0, 0, Center.W, 60, Clr.Panel)
        Ui.Txt(g, 20, 10, 380, 24, "Siege Profile Manager", 13, "Bold", Clr.Text, Clr.Panel, "", "Segoe UI Semibold")
        Ui.Txt(g, 20, 34, 380, 16, "Control centre  ·  v" App.Version, 8, "Norm", Clr.Mute, Clr.Panel)
        Center.Ctl["pill"] := Ui.Txt(g, 470, 18, 300, 26, "", 10, "Bold", Clr.Green, Clr.Panel, "Right")
        Ui.Btn(g, 790, 14, 170, 32, "Compact HUD", () => View.SetMode("hud"))
        Ui.Rect(g, 0, 60, Center.W, 1, Clr.Line)
        ; --- sidebar --------------------------------------------------------------
        Ui.Rect(g, 0, 61, 176, Center.H - 61, Clr.Panel)
        Ui.Rect(g, 175, 61, 1, Center.H - 61, Clr.Line)
        y := 76
        for name in Center.Names {
            Center.NavBar[name] := Ui.Rect(g, 0, y, 4, 38, Clr.Panel)
            t := Ui.Txt(g, 4, y, 171, 38, "     " StrTitle(name), 10, "Norm", Clr.Dim, Clr.Panel, "+0x100")
            t.OnEvent("Click", Center.OpenPage.Bind(Center, name))
            Center.Nav[name] := t
            y += 42
        }
        Ui.Txt(g, 20, Center.H - 96, 150, 16, "Lua config", 8, "Bold", Clr.Mute, Clr.Panel)
        Center.Ctl["sync"] := Ui.Txt(g, 20, Center.H - 78, 148, 62, "", 8, "Norm", Clr.Dim, Clr.Panel, "")
        Center.Ctl["sync"].Opt("-0x200 -0x4000")

        Center.BuildHome(g)
        Center.BuildOperators(g)
        Center.BuildLoadouts(g)
        Center.BuildCalibration(g)
        Center.BuildRecoil(g)
        Center.BuildHud(g)
        Center.BuildSettings(g)
        Center.BuildHotkeys(g)
        Center.BuildDiagnostics(g)

        g.OnEvent("Close", (*) => View.SetMode("hud"))
        g.Show("Hide w" Ui.S(Center.W) " h" Ui.S(Center.H))
        Ui.DarkTitle(g)
        Ui.Chrome(g, Clr.Panel, Clr.Accent, Clr.Text)          ; Windows 11: rounded, cyan border, dark title bar
        Center.OpenPage(Center.Cur)
    }

    static OpenPage(name, *) {
        Center.Cur := name
        for pname, list in Center.Pages
            for c in list
                c.Visible := (pname = name)
        for n, t in Center.Nav {
            Ui.Paint(t, n = name ? Clr.Accent : Clr.Dim, n = name ? Clr.Sel : Clr.Panel)
            Ui.Paint(Center.NavBar[n], Clr.Accent, n = name ? Clr.Accent : Clr.Panel)
        }
        Cfg.Set("ui.page", name)
        Center.RefreshPage()
    }

    static Show() {
        if !IsObject(Center.Gui)
            return
        Center.Visible := true
        opts := ""
        x := Cfg.Get("ui.centerX", ""), y := Cfg.Get("ui.centerY", "")
        if (Cfg.Get("ui.rememberPos", 1) && IsNumber(x) && IsNumber(y)) {
            MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
            opts := " x" Clamp(x, l, Max(l, r - Ui.S(Center.W))) " y" Clamp(y, t, Max(t, b - Ui.S(Center.H)))
        }
        Center.Refresh()
        Center.Gui.Show("w" Ui.S(Center.W) " h" Ui.S(Center.H) opts)
    }

    static Hide() {
        if !IsObject(Center.Gui)
            return
        if (Center.Visible && Cfg.Get("ui.rememberPos", 1)) {
            try {
                Center.Gui.GetPos(&x, &y)
                if (x > -30000)             ; minimised windows report -32000
                    Cfg.Set("ui.centerX", x), Cfg.Set("ui.centerY", y)
            }
        }
        Center.Visible := false
        try Center.Gui.Hide()
    }

    static Refresh() {
        if (!Center.Visible || !IsObject(Center.Gui))
            return
        c := Center.Ctl
        ; header pill = link health
        st := Live.Status
        pill := st = "CONNECTED" ? "● CONNECTED" : st = "IDLE" ? "● CONNECTED · idle " Round(Live.AgeMs() / 1000) "s"
            : st = "LOST" ? "● SIGNAL LOST" : st = "MISMATCH" ? "● PROTOCOL MISMATCH" : "● WAITING FOR G HUB"
        SetText(c["pill"], pill)
        Ui.Paint(c["pill"], (st = "CONNECTED" || st = "IDLE") ? Clr.Green : st = "LOST" ? Clr.Red : Clr.Amber)
        ; sidebar: state of the Lua's copy of the config
        lc := Sync.LuaConfig()
        short := lc[1] = "OK" ? "● IN SYNC" : lc[1] = "PENDING" ? "● CHANGES PENDING" : lc[1] = "OLD" ? "● BLOCK OUTDATED"
            : lc[1] = "NONE" ? "● NO BLOCK PASTED" : "● WAITING"
        SetText(c["sync"], short "`n" (lc[1] = "OK" ? "" : "Copy the full script (Settings)"))
        Ui.Paint(c["sync"], lc[1] = "OK" ? Clr.Green : lc[1] = "UNKNOWN" ? Clr.Dim : Clr.Amber)
        Center.RefreshPage()
    }

    static RefreshPage() {
        if (!Center.Visible || !IsObject(Center.Gui))
            return
        switch Center.Cur {
            case "HOME": Center.RefreshHome()
            case "OPERATORS": Center.RefreshOps()
            case "LOADOUTS": Center.RefreshLoadouts()
            case "CALIBRATION": Center.RefreshCalib()
            case "RECOIL": Center.RefreshRec()
            case "HUD": Center.RefreshHud()
            case "SETTINGS": Center.RefreshSettings()
            case "HOTKEYS": Center.RefreshHotkeys()
            case "DIAGNOSTICS": Center.RefreshDiag()
        }
    }

    ; ==========================================================================
    ; HOME
    ; ==========================================================================
    static BuildHome(g) {
        add := Center.Reg.Bind(Center, "HOME")
        c := Center.Ctl
        ; ---- hero: the operator and loadout you are on ----
        add(Ui.Rect(g, 196, 76, 764, 116, Clr.Panel))
        c["h_side"] := add(Ui.Txt(g, 218, 92, 400, 18, "", 9, "Bold", Clr.Accent, Clr.Panel))
        c["h_op"] := add(Ui.Txt(g, 216, 110, 420, 44, "", 28, "Bold", Clr.Text, Clr.Panel, "", "Segoe UI Black"))
        c["h_lo"] := add(Ui.Txt(g, 218, 158, 420, 22, "", 9, "Norm", Clr.Dim, Clr.Panel))
        add(Ui.Rect(g, 650, 92, 1, 88, Clr.Line))
        c["h_p1"] := add(Ui.Txt(g, 668, 88, 284, 26, "", 12, "Bold", Clr.Text, Clr.Panel))
        c["h_p2"] := add(Ui.Txt(g, 668, 114, 284, 20, "", 8, "Norm", Clr.Dim, Clr.Panel))
        c["h_s1"] := add(Ui.Txt(g, 668, 140, 284, 26, "", 12, "Bold", Clr.Text, Clr.Panel))
        c["h_s2"] := add(Ui.Txt(g, 668, 166, 284, 20, "", 8, "Norm", Clr.Dim, Clr.Panel))
        ; ---- live module chips (states straight from the Lua) ----
        for i, ch in Center.ChipDefs
            Center.Chips.Push(add(Ui.Txt(g, 196 + (i - 1) * 128, 204, 122, 28, "", 8, "Bold", Clr.Dim, Clr.Bg, "")))
        ; ---- link + calibration ----
        Center.Card(add, g, 196, 246, 374, 106, "G HUB LINK")
        c["h_conn"] := add(Ui.Txt(g, 210, 272, 346, 26, "", 13, "Bold", Clr.Green, Clr.Panel))
        c["h_c1"] := add(Ui.Txt(g, 210, 300, 346, 16, "", 9, "Norm", Clr.Dim, Clr.Panel))
        c["h_c2"] := add(Ui.Txt(g, 210, 316, 346, 16, "", 9, "Norm", Clr.Dim, Clr.Panel))
        c["h_c3"] := add(Ui.Txt(g, 210, 332, 346, 16, "", 9, "Norm", Clr.Dim, Clr.Panel))
        Center.Card(add, g, 586, 246, 374, 106, "OPERATOR GRID")
        c["h_cal1"] := add(Ui.Txt(g, 600, 272, 346, 22, "", 10, "Bold", Clr.Text, Clr.Panel))
        c["h_cal2"] := add(Ui.Txt(g, 600, 296, 346, 22, "", 10, "Bold", Clr.Text, Clr.Panel))
        c["h_cal3"] := add(Ui.Txt(g, 600, 324, 346, 18, "", 9, "Norm", Clr.Dim, Clr.Panel))
        ; ---- recent changes + setup checklist ----
        Center.Card(add, g, 196, 366, 374, 258, "RECENT CHANGES")
        c["h_recent"] := add(Ui.List(g, 208, 394, 350, 220, ["When", "What"]))
        c["h_recent"].ModifyCol(1, Ui.S(70)), c["h_recent"].ModifyCol(2, Ui.S(266))
        Center.Card(add, g, 586, 366, 374, 258, "SETUP CHECKLIST")
        acts := [["LINK", "DIAGNOSE", () => Center.OpenPage("DIAGNOSTICS")], ["CONFIG", "COPY SCRIPT", () => Center.CopyBlock()]
            , ["GRID", "FIX", () => Center.FixGrid()], ["RECOIL", "RECORD", () => Center.OpenPage("RECOIL")]]
        for i, a in acts {
            c["k_" a[1]] := add(Ui.Txt(g, 600, 394 + (i - 1) * 50, 226, 40, "", 10, "Bold", Clr.Dim, Clr.Panel2))
            c["kb_" a[1]] := add(Ui.Btn(g, 832, 394 + (i - 1) * 50, 114, 40, a[2], a[3], i = 2 ? "p" : "n"))
        }
        c["h_sync"] := add(Ui.Txt(g, 600, 598, 346, 18, "", 8, "Norm", Clr.Mute, Clr.Panel))
    }

    static RefreshHome() {
        c := Center.Ctl
        st := Live.Status
        ok := (st = "CONNECTED" || st = "IDLE")
        has := Live.Data.Count > 0
        ; module chips: green ENABLED, cyan ACTIVE, amber UNAVAILABLE, grey DISABLED / unknown
        for i, ch in Center.ChipDefs {
            ms := Live.Data.Has(ch[2]) ? Live.Data[ch[2]] : ""
            bb := Live.Burst
            if (ms = "ENABLED" && bb["active"] && ((i = 1 && bb["recoil"]) || (i = 2 && bb["rapid"])))
                ms := "ACTIVE"
            SetText(Center.Chips[i], "● " StrTitle(ch[1]))
            Ui.Paint(Center.Chips[i], ms = "ENABLED" ? Clr.Green : ms = "ACTIVE" ? Clr.Accent : ms = "UNAVAILABLE" ? Clr.Amber : ms = "DISABLED" ? Clr.Red : Clr.Mute)
        }
        ; hero
        fav := has && IndexOf(Cfg.Get("favorites"), Live.OpName()) ? "★  " : ""
        SetText(c["h_side"], has ? StrTitle(Db.SideLabel(Live.Side())) " side" : "Waiting for G HUB")
        SetText(c["h_op"], has ? fav StrUpper(Live.OpName()) : "—")
        SetText(c["h_lo"], has ? "Loadout " Live.Get("loadout", "-") "   ·   System " (Live.Get("enabled") = "1" ? "ON" : "OFF") : "Press RALT + left click once")
        active := Live.Slot()
        for kind, ids in Map("primary", ["h_p1", "h_p2"], "secondary", ["h_s1", "h_s2"]) {
            w := Live.Get(kind, "-")
            isA := (active = kind)
            SetText(c[ids[1]], has ? (isA ? "►  " : "    ") StrTitle(kind) "   " w : "")
            Ui.Paint(c[ids[1]], isA ? Clr.Text : Clr.Dim)
            if (has && w != "NONE" && w != "-")
                SetText(c[ids[2]], "      " Center.A(Live.Att(kind, "scope")) "  ·  " Center.A(Live.Att(kind, "barrel")) "  ·  " Center.A(Live.Att(kind, "grip")))
            else
                SetText(c[ids[2]], "")
        }
        ; link + grid
        SetText(c["h_conn"], st = "CONNECTED" ? "● CONNECTED" : st = "IDLE" ? "● CONNECTED (idle)" : st = "LOST" ? "● SIGNAL LOST"
            : st = "MISMATCH" ? "● PROTOCOL MISMATCH" : "● WAITING")
        Ui.Paint(c["h_conn"], ok ? Clr.Green : st = "LOST" ? Clr.Red : Clr.Amber)
        age := Live.AgeMs()
        SetText(c["h_c1"], "Last packet   " (age >= 0 ? Round(age / 1000, 1) " s ago" : "never"))
        SetText(c["h_c2"], "Session   " (Live.Session != "" ? SubStr(Live.Session, 1, 8) : "-") "   #" Live.Seq)
        SetText(c["h_c3"], Live.StatusWhy != "" ? Live.StatusWhy : "Protocol v" (Live.Protocol ? Live.Protocol : "-"))
        for side, n in Map("attackers", "h_cal1", "defenders", "h_cal2") {
            SetText(c[n], Db.SideLabel(side) "   " Calib.Long(side))
            Ui.Paint(c[n], Calib.Color(side))
        }
        SetText(c["h_cal3"], Cfg.Get("game.resW") "×" Cfg.Get("game.resH") "  ·  " Calib.Mode())
        lv := c["h_recent"]
        lv.Delete()
        loop Live.Recent.Length {
            e := Live.Recent[Live.Recent.Length - A_Index + 1]
            lv.Add("", e["t"], e["text"])
        }
        lc := Sync.LuaConfig()
        ; --- setup checklist -------------------------------------------------------------
        Center.Row("LINK", ok ? 1 : st = "LOST" ? -1 : 0, ok ? "G HUB linked" : st = "LOST" ? "G HUB signal lost" : "Waiting for G HUB")
        Center.Row("CONFIG", lc[1] = "OK" ? 1 : lc[1] = "UNKNOWN" ? 0 : -1
            , lc[1] = "OK" ? "Config is in the game" : lc[1] = "PENDING" ? "New changes not pasted" : lc[1] = "OLD" ? "Game has an older config" : lc[1] = "NONE" ? "Config not pasted yet" : "Waiting for G HUB")
        ll := Calib.LuaLast
        Center.Row("GRID", !ll.Count ? 0 : ll["agree"] ? 1 : -1
            , !ll.Count ? "Grid untested: RSHIFT+click a tile" : ll["agree"] ? "Operator grid verified" : "Grid mismatch (tap FIX)")
        pk := Live.Get("recoil_profile", "")
        Center.Row("RECOIL", pk = "" ? 0 : (pk = "LEARNED" ? 1 : 0), pk = "" ? "Recoil: no data yet" : "Recoil profile: " pk)
        SetText(c["h_sync"], lc[2])
    }

    ; One checklist row: state 1 = good (green), 0 = pending (grey), -1 = needs attention (amber/red)
    static Row(id, state, text) {
        c := Center.Ctl
        SetText(c["k_" id], (state = 1 ? "  ✓  " : state = -1 ? "  ⚠  " : "  …  ") text)
        Ui.Paint(c["k_" id], state = 1 ? Clr.Green : state = -1 ? Clr.Amber : Clr.Dim)
    }

    ; "FIX" for the grid: forget grids saved here so the Lua falls back to its own presets, then hand over the script.
    static FixGrid() {
        ll := Calib.LuaLast
        if (ll.Count && !ll["agree"]) {
            Calib.ResetBoth()
            Center.CopyBlock()
        } else
            Center.StartTest()
    }

    static A(v) => v = "" ? "n/a" : v = "NONE" ? "none" : v

    static CopyBlock() {
        Center.Gui.Opt("+OwnDialogs")
        LuaBlock.Announce(LuaBlock.Copy())
        View.Changed()
    }

    static CopyReport() {
        A_Clipboard := Diagnostics.Report()
        Toast.Show("ok", "✓ REPORT COPIED", "Diagnostic report is on the clipboard", "", "")
    }

    static StartTest() {
        Calib.Testing := true
        Center.OpenPage("CALIBRATION")
    }

    ; ==========================================================================
    ; OPERATORS
    ; ==========================================================================
    static BuildOperators(g) {
        add := Center.Reg.Bind(Center, "OPERATORS")
        c := Center.Ctl
        Center.Segs["o_side"] := Seg(g, 196, 76, 200, 32, ["ATTACK", "DEFENCE"], (v) => Center.SetOpSide(v))
        for t in Center.Segs["o_side"].Btns
            add(t)
        Center.Toggles["o_fav"] := Toggle(g, 410, 80, 170, "★ Favourites only", false, (v) => (Center.FavOnly := v, Center.RefreshOps()))
        add(Center.Toggles["o_fav"].Ctl)
        c["o_search"] := add(Ui.Edit(g, 196, 116, 376, 28))
        Ui.Cue(c["o_search"], "Search operators or weapons (e.g. zof, m762)")
        c["o_search"].OnEvent("Change", (ctrl, *) => (Center.Search := ctrl.Text, Center.RefreshOps()))
        add(Ui.Txt(g, 202, 150, 100, 16, "OPERATOR", 8, "Bold", Clr.Mute))
        add(Ui.Txt(g, 326, 150, 100, 16, "PRIMARY", 8, "Bold", Clr.Mute))
        add(Ui.Txt(g, 456, 150, 100, 16, "SECONDARY", 8, "Bold", Clr.Mute))
        c["o_list"] := add(Ui.List(g, 196, 168, 376, 454, ["Operator", "Primary", "Secondary"]))
        c["o_list"].ModifyCol(1, Ui.S(118)), c["o_list"].ModifyCol(2, Ui.S(130)), c["o_list"].ModifyCol(3, Ui.S(110))
        c["o_list"].OnEvent("ItemSelect", (ctrl, row, sel) => (sel ? Center.OnOpPick(row) : 0))

        add(Ui.Rect(g, 592, 76, 368, 546, Clr.Panel))
        c["o_name"] := add(Ui.Txt(g, 608, 88, 240, 34, "", 16, "Bold", Clr.Text, Clr.Panel))
        c["o_star"] := add(Ui.Btn(g, 856, 90, 88, 30, "☆ FAV", () => Center.ToggleOpFav()))
        c["o_meta"] := add(Ui.Txt(g, 608, 124, 336, 18, "", 9, "Norm", Clr.Dim, Clr.Panel))
        Center.Segs["o_slot"] := Seg(g, 608, 150, 336, 30, ["PRIMARY", "SECONDARY"], (v) => (Center.Slot := StrLower(v), Center.RefreshOpDetail()))
        for t in Center.Segs["o_slot"].Btns
            add(t)
        y := 198
        for f in ["weapon", "scope", "barrel", "grip"] {
            add(Ui.Txt(g, 608, y, 70, 24, StrUpper(f), 8, "Bold", Clr.Mute, Clr.Panel))
            d := add(Ui.Drop(g, 684, y - 2, 260, []))
            c["o_" f] := d
            d.OnEvent("Change", Center.OnAtt.Bind(Center, f))
            y += 38
        }
        c["o_note"] := add(Ui.Txt(g, 608, 352, 336, 34, "", 8, "Norm", Clr.Mute, Clr.Panel))
        c["o_note"].Opt("-0x200 -0x4000")
        add(Ui.Txt(g, 608, 398, 70, 24, "LOADOUT", 8, "Bold", Clr.Mute, Clr.Panel))
        c["o_lo"] := add(Ui.Drop(g, 684, 396, 190, []))
        add(Ui.Btn(g, 880, 394, 64, 28, "APPLY", () => Center.ApplyNamed()))
        add(Ui.Btn(g, 608, 436, 336, 30, "SAVE CURRENT AS NEW LOADOUT…", () => Center.SaveAsLoadout()))
        add(Ui.Btn(g, 608, 474, 336, 30, "SET AS STARTING OPERATOR", () => Center.SetStarting()))
        c["o_sync"] := add(Ui.Txt(g, 608, 516, 336, 40, "", 9, "Norm", Clr.Dim, Clr.Panel))
        c["o_sync"].Opt("-0x200 -0x4000")
    }

    ; Slider on the dark background; falls back to the plain look if this Windows build rejects the colour option.
    static Slider(g, x, y, w, range, val) {
        opts := "x" Ui.S(x) " y" Ui.S(y) " w" Ui.S(w) " h" Ui.S(28) " Range" range " ToolTip"
        try return g.AddSlider(opts " Background" Clr.Bg, val)
        return g.AddSlider(opts, val)
    }

    static SetOpSide(v) {
        Center.OpSide := (v = "ATTACK") ? "attackers" : "defenders"
        Center.Op := ""
        Center.RefreshOps()
    }

    static OpMatches(op, q) {
        name := op["name"]
        if InStr(StrLower(name), q)
            return true
        for kind in Db.Kinds
            for w in op[kind]
                if InStr(StrLower(w), q)
                    return true
        for e in LoadoutMgr.List(name) {
            if InStr(StrLower(e["name"]), q)
                return true
            for kind in Db.Kinds
                if (e[kind].Count && InStr(StrLower(e[kind]["weapon"]), q))
                    return true
        }
        return false
    }

    static RefreshOps() {
        c := Center.Ctl
        lv := c["o_list"]
        Center.Guard := true
        Center.Segs["o_side"].Set(Center.OpSide = "attackers" ? 1 : 2)
        Center.Toggles["o_fav"].Set(Center.FavOnly)
        q := StrLower(Trim(Center.Search))
        lv.Opt("-Redraw")
        lv.Delete()
        Center.OpRows := []
        favs := Cfg.Get("favorites")
        selRow := 0
        for op in Db.Ops[Center.OpSide] {
            name := op["name"]
            isFav := IndexOf(favs, name) > 0
            if (Center.FavOnly && !isFav)
                continue
            if (q != "" && !Center.OpMatches(op, q))
                continue
            Center.OpRows.Push(name)
            row := lv.Add("", (isFav ? "★ " : "   ") name, JoinList(op["primary"]), JoinList(op["secondary"]))
            if (name = Center.Op)
                selRow := row
        }
        if (!selRow && Center.OpRows.Length) {
            Center.Op := Center.OpRows[1]
            selRow := 1
        } else if (!Center.OpRows.Length)
            Center.Op := ""
        if selRow
            lv.Modify(selRow, "Select Focus Vis")
        lv.Opt("+Redraw")
        Center.Guard := false
        Center.RefreshOpDetail()
    }

    static OnOpPick(row) {
        if (Center.Guard || row < 1 || row > Center.OpRows.Length)
            return
        Center.Op := Center.OpRows[row]
        Center.RefreshOpDetail()
    }

    static FillDrop(d, items, current) {
        d.Delete()
        if items.Length
            d.Add(items)
        idx := IndexOf(items, current)
        if idx
            d.Choose(idx)
        d.Enabled := items.Length > 0
    }

    static RefreshOpDetail() {
        c := Center.Ctl
        f := Db.Find(Center.Op)
        Center.Guard := true
        if !IsObject(f) {
            SetText(c["o_name"], "No operator")
            SetText(c["o_meta"], "")
            for k in ["weapon", "scope", "barrel", "grip"]
                Center.FillDrop(c["o_" k], [], "")
            Center.FillDrop(c["o_lo"], [], "")
            SetText(c["o_note"], "")
            SetText(c["o_sync"], "")
            Center.Guard := false
            return
        }
        op := f["op"]
        name := op["name"]
        isFav := IndexOf(Cfg.Get("favorites"), name) > 0
        SetText(c["o_name"], (isFav ? "★ " : "") StrUpper(name))
        SetText(c["o_star"], isFav ? "★ FAV" : "☆ FAV")
        Ui.Paint(c["o_star"], isFav ? Clr.Amber : Clr.Text)
        SetText(c["o_meta"], Db.SideLabel(f["side"]) "  ·  " op["primary"].Length " primary, " op["secondary"].Length " secondary weapons")
        Center.Segs["o_slot"].Set(Center.Slot = "primary" ? 1 : 2)
        lo := LoadoutMgr.Working(name)
        slot := lo[Center.Slot]
        has := slot.Count > 0
        Center.FillDrop(c["o_weapon"], op[Center.Slot], has ? slot["weapon"] : "")
        for field in Db.Fields
            Center.FillDrop(c["o_" field], has ? Db.Options(slot["weapon"], field) : [], has ? slot[field] : "")
        SetText(c["o_note"], has ? "Only attachments that " slot["weapon"] " can equip are listed." : name " has no " Center.Slot " weapon.")
        names := Cfg.Names(LoadoutMgr.List(name))
        Center.FillDrop(c["o_lo"], names, LoadoutMgr.Active(name))
        ; how does this compare with what the game is doing right now?
        msg := ""
        if (Live.Fresh() && StrLower(Live.OpName()) = StrLower(name)) {
            same := true
            for kind in Db.Kinds {
                w := Live.Get(kind, "NONE")
                if (lo[kind].Count ? (lo[kind]["weapon"] != w || lo[kind]["scope"] != (Live.Att(kind, "scope") = "" ? lo[kind]["scope"] : Live.Att(kind, "scope"))
                    || lo[kind]["barrel"] != Live.Att(kind, "barrel") || lo[kind]["grip"] != Live.Att(kind, "grip")) : w != "NONE")
                    same := false
            }
            msg := same ? "● Matches the loadout the game is using." : "● Differs from the game: use the in-game hotkeys, RALT+RMB, or paste the full script (Settings)."
            Ui.Paint(c["o_sync"], same ? Clr.Green : Clr.Amber)
        } else {
            msg := "Changes are saved here and reach the game through the copied Lua script (Settings)."
            Ui.Paint(c["o_sync"], Clr.Dim)
        }
        SetText(c["o_sync"], msg)
        Center.Guard := false
    }

    static OnAtt(field, ctrl, *) {
        if (Center.Guard || Center.Op = "" || ctrl.Text = "")
            return
        LoadoutMgr.Set(Center.Op, Center.Slot, field, ctrl.Text)
        Center.RefreshOpDetail()
        View.Changed()
    }

    static ToggleOpFav() {
        f := Db.Find(Center.Op)
        if !IsObject(f)
            return
        name := f["op"]["name"]
        favs := Cfg.Data["favorites"]
        i := IndexOf(favs, name)
        if i
            favs.RemoveAt(i)
        else
            favs.Push(name)
        Cfg.Dirty()
        Toast.Show("ok", i ? "FAVOURITE REMOVED" : "★ FAVOURITE ADDED", StrUpper(name), "", "")
        Center.RefreshOps()
        View.Changed()
    }

    static SetStarting() {
        f := Db.Find(Center.Op)
        if !IsObject(f)
            return
        Cfg.Set("state.side", f["side"])
        Cfg.Set("state.operator", f["op"]["name"])
        Toast.Show("ok", "STARTING OPERATOR", StrUpper(f["op"]["name"]), "Applies when the copied script is loaded", "")
        View.Changed()
    }

    static SaveAsLoadout() {
        if (Center.Op = "")
            return
        ib := InputBox("Name for the new " Center.Op " loadout:", "New loadout", "w300 h120", LoadoutMgr.UniqueName(Center.Op, "MAIN"))
        if (ib.Result != "OK")
            return
        if LoadoutMgr.Create(Center.Op, StrUpper(ib.Value)) {
            Toast.Show("ok", "LOADOUT CREATED", StrUpper(Trim(ib.Value)), Center.Op, "")
            Center.RefreshOpDetail()
        } else
            Toast.Show("warn", "⚠ NAME NOT AVAILABLE", "Empty or already used", "", "")
    }

    static ApplyNamed() {
        c := Center.Ctl
        if (Center.Op = "" || c["o_lo"].Text = "")
            return
        idx := LoadoutMgr.Find(Center.Op, c["o_lo"].Text)
        if !idx
            return
        LoadoutMgr.Activate(Center.Op, idx)
        Toast.Show("ok", "LOADOUT CHANGED", c["o_lo"].Text, Center.Op, "Saved as the working loadout")
        Center.RefreshOpDetail()
        View.Changed()
    }

    ; ==========================================================================
    ; LOADOUTS
    ; ==========================================================================
    static BuildLoadouts(g) {
        add := Center.Reg.Bind(Center, "LOADOUTS")
        c := Center.Ctl
        c["l_search"] := add(Ui.Edit(g, 196, 76, 380, 28))
        Ui.Cue(c["l_search"], "Search loadouts (name, operator, weapon)")
        c["l_search"].OnEvent("Change", (ctrl, *) => (Center.LoSearch := ctrl.Text, Center.RefreshLoadouts()))
        Center.Toggles["l_this"] := Toggle(g, 596, 80, 220, "Selected operator only", false, (v) => (Center.LoThis := v, Center.RefreshLoadouts()))
        add(Center.Toggles["l_this"].Ctl)
        for h in [[202, "OPERATOR"], [322, "LOADOUT"], [472, "PRIMARY"], [662, "SECONDARY"], [852, "★"], [892, "ACTIVE"]]
            add(Ui.Txt(g, h[1], 114, 120, 16, h[2], 8, "Bold", Clr.Mute))
        c["l_list"] := add(Ui.List(g, 196, 132, 764, 292, ["Operator", "Loadout", "Primary", "Secondary", "Fav", "Active"]))
        for i, w in [120, 150, 190, 190, 40, 70]
            c["l_list"].ModifyCol(i, Ui.S(w))
        c["l_list"].OnEvent("ItemSelect", (ctrl, row, sel) => (sel && !Center.Guard ? Center.RefreshLoDetail() : 0))
        add(Ui.Btn(g, 196, 436, 118, 32, "NEW", () => Center.LoNew(), "p"))
        add(Ui.Btn(g, 322, 436, 118, 32, "DUPLICATE", () => Center.LoAct("dup")))
        add(Ui.Btn(g, 448, 436, 118, 32, "RENAME", () => Center.LoAct("ren")))
        add(Ui.Btn(g, 574, 436, 118, 32, "DELETE", () => Center.LoAct("del"), "d"))
        add(Ui.Btn(g, 700, 436, 118, 32, "★ FAVOURITE", () => Center.LoAct("fav")))
        add(Ui.Btn(g, 826, 436, 134, 32, "SET ACTIVE", () => Center.LoAct("act")))
        add(Ui.Btn(g, 196, 476, 190, 30, "IMPORT LOADOUTS…", () => Center.LoImport()))
        add(Ui.Btn(g, 394, 476, 190, 30, "EXPORT ALL…", () => Center.LoExport()))
        Center.Card(add, g, 196, 518, 764, 106, "SELECTED LOADOUT")
        c["l_d1"] := add(Ui.Txt(g, 210, 544, 736, 22, "", 11, "Bold", Clr.Text, Clr.Panel))
        c["l_d2"] := add(Ui.Txt(g, 210, 568, 736, 20, "", 9, "Norm", Clr.Dim, Clr.Panel))
        c["l_d3"] := add(Ui.Txt(g, 210, 590, 736, 20, "", 9, "Norm", Clr.Dim, Clr.Panel))
    }

    static RefreshLoadouts() {
        c := Center.Ctl
        lv := c["l_list"]
        Center.Guard := true
        Center.Toggles["l_this"].Set(Center.LoThis)
        q := StrLower(Trim(Center.LoSearch))
        lv.Opt("-Redraw")
        lv.Delete()
        Center.LoRows := []
        for side in Db.Sides
            for op in Db.Ops[side] {
                name := op["name"]
                if (Center.LoThis && Center.Op != "" && name != Center.Op)
                    continue
                for i, e in LoadoutMgr.List(name) {
                    if (q != "") {
                        hay := StrLower(name " " e["name"] " " LoadoutMgr.SlotText(e["primary"]) " " LoadoutMgr.SlotText(e["secondary"]))
                        if !InStr(hay, q)
                            continue
                    }
                    Center.LoRows.Push(Map("op", name, "idx", i))
                    lv.Add("", name, e["name"], Center.Short(e["primary"]), Center.Short(e["secondary"])
                        , e["fav"] ? "★" : "", LoadoutMgr.Active(name) = e["name"] ? "●" : "")
                }
            }
        lv.Opt("+Redraw")
        Center.Guard := false
        Center.RefreshLoDetail()
    }

    static Short(slot) => slot.Count ? slot["weapon"] : "none"

    static LoSel() {
        row := Center.Ctl["l_list"].GetNext()
        if (row < 1 || row > Center.LoRows.Length)
            return ""
        return Center.LoRows[row]
    }

    static RefreshLoDetail() {
        c := Center.Ctl
        s := Center.LoSel()
        if !IsObject(s) {
            SetText(c["l_d1"], "Nothing selected")
            SetText(c["l_d2"], "")
            SetText(c["l_d3"], "")
            return
        }
        e := LoadoutMgr.List(s["op"])[s["idx"]]
        SetText(c["l_d1"], StrUpper(s["op"]) "  ·  " e["name"] (LoadoutMgr.Active(s["op"]) = e["name"] ? "   ● active" : "") (e["fav"] ? "   ★" : ""))
        SetText(c["l_d2"], "PRIMARY    " LoadoutMgr.SlotText(e["primary"]))
        SetText(c["l_d3"], "SECONDARY  " LoadoutMgr.SlotText(e["secondary"]))
    }

    static LoNew() {
        op := Center.Op
        s := Center.LoSel()
        if IsObject(s)
            op := s["op"]
        if (op = "")
            op := Live.OpName()
        if (op = "" || !IsObject(Db.Find(op))) {
            Toast.Show("warn", "⚠ NO OPERATOR", "Pick an operator first", "", "")
            return
        }
        ib := InputBox("Name for the new " op " loadout (uses its current working loadout):", "New loadout", "w320 h120", LoadoutMgr.UniqueName(op, "MAIN"))
        if (ib.Result != "OK")
            return
        if LoadoutMgr.Create(op, StrUpper(ib.Value)) {
            Toast.Show("ok", "LOADOUT CREATED", StrUpper(Trim(ib.Value)), op, "")
            Center.RefreshLoadouts()
        } else
            Toast.Show("warn", "⚠ NAME NOT AVAILABLE", "Empty or already used", "", "")
    }

    static LoAct(what) {
        s := Center.LoSel()
        if !IsObject(s) {
            Toast.Show("warn", "⚠ NOTHING SELECTED", "Select a loadout first", "", "")
            return
        }
        op := s["op"], idx := s["idx"]
        e := LoadoutMgr.List(op)[idx]
        switch what {
            case "dup":
                LoadoutMgr.Duplicate(op, idx)
                Toast.Show("ok", "LOADOUT DUPLICATED", e["name"], op, "")
            case "ren":
                ib := InputBox("New name:", "Rename loadout", "w300 h120", e["name"])
                if (ib.Result != "OK")
                    return
                if LoadoutMgr.Rename(op, idx, StrUpper(ib.Value))
                    Toast.Show("ok", "LOADOUT RENAMED", StrUpper(Trim(ib.Value)), op, "")
                else
                    Toast.Show("warn", "⚠ NAME NOT AVAILABLE", "Empty or already used", "", "")
            case "del":
                if (MsgBox("Delete loadout " e["name"] " (" op ")?", "Delete loadout", "YesNo Icon?") != "Yes")
                    return
                LoadoutMgr.Delete(op, idx)
                Toast.Show("info", "LOADOUT DELETED", e["name"], op, "")
            case "fav":
                LoadoutMgr.ToggleFav(op, idx)
            case "act":
                LoadoutMgr.Activate(op, idx)
                Toast.Show("ok", "LOADOUT CHANGED", e["name"], op, "Saved as the working loadout")
        }
        Center.RefreshLoadouts()
        View.Changed()
    }

    static LoExport() {
        all := []
        for op, rec in Cfg.Data["loadouts"]
            for e in rec["list"]
                all.Push(Map("operator", op, "name", e["name"], "fav", e["fav"], "primary", e["primary"], "secondary", e["secondary"]))
        if !all.Length {
            Toast.Show("warn", "⚠ NOTHING TO EXPORT", "No named loadouts yet", "", "")
            return
        }
        path := FileSelect("S16", A_Desktop "\spm-loadouts.json", "Export loadouts", "JSON (*.json)")
        if (path = "")
            return
        try {
            f := FileOpen(path, "w", "UTF-8-RAW")
            f.Write(Json.Stringify(Map("kind", "spm-loadouts", "version", 1, "loadouts", all)))
            f.Close()
            Toast.Show("ok", "✓ LOADOUTS EXPORTED", all.Length " loadout(s)", "", "")
        } catch as e {
            Toast.Show("error", "⚠ EXPORT FAILED", e.Message, "", "")
        }
    }

    static LoImport() {
        path := FileSelect(1, A_Desktop, "Import loadouts", "JSON (*.json)")
        if (path = "")
            return
        try {
            data := Json.Parse(FileRead(path, "UTF-8"))
            if (Type(data) != "Map" || !data.Has("loadouts") || Type(data["loadouts"]) != "Array")
                throw Error("not a loadout export")
        } catch as e {
            Toast.Show("error", "⚠ IMPORT FAILED", e.Message, "Nothing was changed", "")
            return
        }
        ok := 0, bad := 0
        for e in data["loadouts"] {
            if (Type(e) != "Map" || !e.Has("operator") || !e.Has("name") || !IsObject(Db.Find(String(e["operator"])))) {
                bad++
                continue
            }
            op := Db.Find(String(e["operator"]))["op"]["name"]
            lo := Map()
            for kind in Db.Kinds
                lo[kind] := LoadoutMgr.Fix(op, kind, e.Has(kind) && Type(e[kind]) = "Map" ? e[kind] : "")
            if LoadoutMgr.Create(op, LoadoutMgr.UniqueName(op, StrUpper(Trim(String(e["name"])))), lo)
                ok++
            else
                bad++
        }
        Toast.Show(bad ? "warn" : "ok", "LOADOUTS IMPORTED", ok " added", bad ? bad " skipped (invalid)" : "", "")
        Center.RefreshLoadouts()
        View.Changed()
    }

    ; ==========================================================================
    ; HUD
    ; ==========================================================================
    static BuildHud(g) {
        add := Center.Reg.Bind(Center, "HUD")
        c := Center.Ctl
        add(Ui.Txt(g, 196, 76, 300, 20, "SIZE", 8, "Bold", Clr.Mute))
        Center.Segs["h_size"] := Seg(g, 196, 98, 330, 32, ["Compact", "Normal", "Large"], (v) => Center.HudSet("ui.hudSize", v))
        for t in Center.Segs["h_size"].Btns
            add(t)
        add(Ui.Txt(g, 196, 146, 300, 20, "POSITION", 8, "Bold", Clr.Mute))
        Center.Segs["h_pos"] := Seg(g, 196, 168, 560, 32, ["Top Left", "Top Right", "Bottom Left", "Bottom Right", "Custom"], (v) => Center.HudSet("ui.hudPos", v))
        for t in Center.Segs["h_pos"].Btns
            add(t)
        add(Ui.Txt(g, 196, 214, 60, 24, "X", 9, "Bold", Clr.Dim))
        c["h_x"] := add(Ui.Edit(g, 216, 212, 80, 26))
        add(Ui.Txt(g, 310, 214, 60, 24, "Y", 9, "Bold", Clr.Dim))
        c["h_y"] := add(Ui.Edit(g, 330, 212, 80, 26))
        add(Ui.Btn(g, 424, 210, 130, 30, "APPLY POSITION", () => Center.HudCustom()))
        add(Ui.Txt(g, 196, 258, 300, 20, "OPACITY", 8, "Bold", Clr.Mute))
        c["h_op"] := add(Center.Slider(g, 196, 280, 330, "60-255", 235))
        c["h_op"].OnEvent("Change", (ctrl, *) => (Cfg.Set("ui.opacity", ctrl.Value), View.Changed()))
        add(Ui.Txt(g, 566, 258, 300, 20, "HUD SCALE", 8, "Bold", Clr.Mute))
        c["h_sc"] := add(Center.Slider(g, 566, 280, 330, "50-200", 100))
        c["h_sc"].OnEvent("Change", (ctrl, *) => (Cfg.Set("ui.hudScale", ctrl.Value / 100), View.RebuildSoon()))
        add(Ui.Txt(g, 196, 330, 300, 20, "SHOW ON THE HUD", 8, "Bold", Clr.Mute))
        for i, pair in [["operator", "Operator"], ["weapon", "Weapon"], ["attachments", "Attachments"]
            , ["connection", "Connection status"], ["calibration", "Calibration"], ["debug", "Debug information"], ["modules", "Module status dots"]] {
            tg := Toggle(g, 196 + Mod(i - 1, 2) * 260, 354 + ((i - 1) // 2) * 30, 250, pair[2], false, Center.SecSet.Bind(Center, pair[1]))
            Center.Toggles["s_" pair[1]] := tg
            add(tg.Ctl)
        }
        Center.Toggles["h_notif"] := Toggle(g, 196, 484, 300, "Show notifications", true, (v) => (Cfg.Set("ui.notifications", v), View.Changed()))
        add(Center.Toggles["h_notif"].Ctl)
        add(Ui.Btn(g, 196, 526, 200, 32, "TEST NOTIFICATION", () => Toast.Show("ok", "✓ OPERATOR DETECTED", "ZOFIA", "M762", "SUPPRESSOR • HORIZONTAL"), "p"))
        add(Ui.Btn(g, 406, 526, 200, 32, "RESET HUD SETTINGS", () => Center.HudReset()))
        add(Ui.Txt(g, 196, 574, 700, 40, "The compact HUD is click-through and never takes focus. Custom position: enter screen pixels and press APPLY.", 9, "Norm", Clr.Mute))
    }

    static HudSet(path, v) {
        if Center.Guard
            return
        Cfg.Set(path, v)
        View.RebuildSoon()
    }

    static SecSet(key, v) {
        if Center.Guard
            return
        Cfg.Data["ui"]["sections"][key] := v ? 1 : 0
        Cfg.Dirty()
        View.Changed()
    }

    static HudCustom() {
        c := Center.Ctl
        if (IsInteger(c["h_x"].Text) && IsInteger(c["h_y"].Text)) {
            Cfg.Set("ui.hudX", Integer(c["h_x"].Text))
            Cfg.Set("ui.hudY", Integer(c["h_y"].Text))
            Cfg.Set("ui.hudPos", "Custom")
            Center.Segs["h_pos"].SetByName("Custom")
            View.Changed()
        } else
            Toast.Show("warn", "⚠ INVALID POSITION", "Enter whole numbers", "", "")
    }

    static HudReset() {
        for k, v in Map("ui.hudSize", "Normal", "ui.hudPos", "Top Right", "ui.hudScale", 1.0, "ui.opacity", 235)
            Cfg.Set(k, v)
        Cfg.Data["ui"]["sections"] := Cfg.DefaultSections()
        Cfg.Dirty()
        View.RebuildSoon()
    }

    static RefreshHud() {
        c := Center.Ctl
        Center.Guard := true
        Center.Segs["h_size"].SetByName(Cfg.Get("ui.hudSize", "Normal"))
        Center.Segs["h_pos"].SetByName(Cfg.Get("ui.hudPos", "Top Right"))
        c["h_op"].Value := Cfg.Num("ui.opacity", 235)
        c["h_sc"].Value := Round(Cfg.Num("ui.hudScale", 1.0) * 100)
        if (c["h_x"].Text = "")
            c["h_x"].Text := Cfg.Num("ui.hudX", 40), c["h_y"].Text := Cfg.Num("ui.hudY", 40)
        for key in ["operator", "weapon", "attachments", "connection", "calibration", "debug", "modules"]
            Center.Toggles["s_" key].Set(Cfg.Get("ui.sections")[key])
        Center.Toggles["h_notif"].Set(Cfg.Get("ui.notifications", 1))
        Center.Guard := false
    }

    ; ==========================================================================
    ; CALIBRATION  (wizard around the existing Lua calibration + test detection)
    ; ==========================================================================
    static Cells := []

    static BuildCalibration(g) {
        add := Center.Reg.Bind(Center, "CALIBRATION")
        c := Center.Ctl
        Center.Segs["c_side"] := Seg(g, 196, 76, 300, 32, ["ATTACKERS", "DEFENDERS"], (v) => (Calib.Side := (v = "ATTACKERS" ? "attackers" : "defenders"), Center.RefreshCalib()))
        for t in Center.Segs["c_side"].Btns
            add(t)
        c["c_status"] := add(Ui.Txt(g, 510, 78, 234, 28, "", 10, "Bold", Clr.Amber, Clr.Bg, "Right"))
        Center.Cells := []
        loop 7 {
            r := A_Index
            loop 7 {
                cl := add(Ui.Txt(g, 196 + (A_Index - 1) * 76, 118 + (r - 1) * 44, 72, 40, "", 7, "Bold", Clr.Dim, Clr.Panel2, "Center"))
                Center.Cells.Push(cl)
            }
        }
        c["c_step"] := add(Ui.Txt(g, 744, 118, 216, 22, "", 10, "Bold", Clr.Text))
        c["c_step2"] := add(Ui.Txt(g, 744, 142, 216, 40, "", 9, "Norm", Clr.Dim))
        c["c_step2"].Opt("-0x200 -0x4000")
        c["c_pts"] := add(Ui.Mono(g, 744, 186, 216, 52, "", 8, Clr.Dim, Clr.Bg))
        add(Ui.Btn(g, 744, 248, 104, 32, "AUTO-DETECT", () => AutoCal.Run(Calib.Side), "p"))
        add(Ui.Btn(g, 856, 248, 104, 32, "MANUAL", () => Calib.Start(Calib.Side)))
        add(Ui.Btn(g, 744, 286, 216, 30, "CANCEL", () => Calib.Cancel()))
        add(Ui.Btn(g, 744, 322, 104, 30, "RESET THIS", () => Calib.ResetSide(Calib.Side), "d"))
        add(Ui.Btn(g, 856, 322, 104, 30, "RESET BOTH", () => Calib.ResetBoth(), "d"))
        c["c_test"] := add(Ui.Btn(g, 744, 360, 216, 32, "TEST DETECTION: OFF", () => Calib.SetTesting(!Calib.Testing)))
        c["c_hint"] := add(Ui.Txt(g, 744, 400, 216, 34, "", 8, "Norm", Clr.Mute))
        c["c_hint"].Opt("-0x200 -0x4000")
        Center.Card(add, g, 196, 438, 764, 186, "TEST DETECTION")
        c["t1"] := add(Ui.Mono(g, 212, 466, 340, 20, "", 10, Clr.Text, Clr.Panel))
        c["t2"] := add(Ui.Mono(g, 212, 490, 340, 20, "", 10, Clr.Text, Clr.Panel))
        add(Ui.Txt(g, 212, 522, 200, 16, "DETECTED", 8, "Bold", Clr.Mute, Clr.Panel))
        c["t4"] := add(Ui.Txt(g, 212, 540, 340, 40, "", 20, "Bold", Clr.Text, Clr.Panel))
        c["t5"] := add(Ui.Txt(g, 212, 588, 340, 24, "", 10, "Bold", Clr.Green, Clr.Panel))
        add(Ui.Txt(g, 580, 466, 360, 18, "WHAT THE LUA DETECTED LAST", 8, "Bold", Clr.Mute, Clr.Panel))
        c["t6"] := add(Ui.Txt(g, 580, 488, 360, 30, "", 14, "Bold", Clr.Text, Clr.Panel))
        c["t7"] := add(Ui.Txt(g, 580, 524, 360, 40, "", 9, "Norm", Clr.Dim, Clr.Panel))
        c["t7"].Opt("-0x200 -0x4000")
    }

    static RefreshCalib() {
        c := Center.Ctl
        side := Calib.Side
        Center.Segs["c_side"].Set(side = "attackers" ? 1 : 2)
        st := Calib.Status(side)
        SetText(c["c_status"], "● " st)
        Ui.Paint(c["c_status"], Calib.Color(side))
        SetText(c["c_step"], Calib.Active ? "STEP " Calib.Step "/2: " (Calib.Step = 1 ? "TOP LEFT" : "BOTTOM RIGHT") : "NOT CALIBRATING")
        SetText(c["c_step2"], Calib.Active
            ? (Calib.Step = 1 ? "Hover the OUTER top-left corner of the first operator tile, then press " Cfg.Get("hotkeys.capture") "."
                : "Hover the OUTER bottom-right corner of the last tile (row 7, column 7), then press " Cfg.Get("hotkeys.capture") ".")
            : (Calib.Err != "" ? "⚠ " Calib.Err : "Open the operator selector in Siege and press AUTO-DETECT (it also runs by itself). MANUAL = capture the two corners."))
        pts := ""
        for i, p in Calib.Pts
            pts .= (i = 1 ? "TOP LEFT      " : "BOTTOM RIGHT  ") Format("{:.4f}, {:.4f}", p[1], p[2]) "`n"
        geo := Calib.Geometry(side)
        if (pts = "")
            pts := (Calib.HasCal(side) ? "TOP LEFT      " Format("{:.4f}, {:.4f}", geo["tlx"], geo["tly"]) "`nBOTTOM RIGHT  " Format("{:.4f}, {:.4f}", geo["brx"], geo["bry"])
                : "using preset " Calib.PresetName())
        SetText(c["c_pts"], pts)
        SetText(c["c_test"], "TEST DETECTION: " (Calib.Testing ? "ON" : "OFF"))
        SetText(c["c_hint"], "Capture with " Cfg.Get("hotkeys.capture") " or RSHIFT+MB4 in game. Grid order comes from the Lua and is never changed.")
        ; grid preview
        grid := Db.Grid[side]
        Center.Guard := true
        i := 0
        for r, row in grid
            for col, name in row {
                i++
                if (i <= Center.Cells.Length) {
                    cl := Center.Cells[i]
                    SetText(cl, name = "" ? "·" : SubStr(name, 1, 9))
                    Ui.Paint(cl, name = "" ? Clr.Mute : Clr.Dim, Clr.Panel2)
                }
            }
        Center.Guard := false
        Center.RefreshCalibLive()
        ; what the Lua last detected
        ld := Calib.LastLua
        SetText(c["t6"], ld != "" ? StrUpper(ld) : "-")
        ll := Calib.LuaLast
        if !ll.Count
            SetText(c["t7"], "Click a tile in Siege with RSHIFT + left click. Both readings must agree.`nCoordinate space: " Calib.SpaceText())
        else {
            ahk := ll["ahkName"] != "" ? StrUpper(ll["ahkName"]) : (ll["ahkRow"] ? "an empty tile" : "outside the grid")
            SetText(c["t7"], (ll["agree"] ? "✓ This app's grid agrees (row " ll["row"] ", col " ll["col"] ")"
                : "✗ DISAGREE: the Lua says row " ll["row"] " col " ll["col"] ", this app's grid says " ahk "`nUse RESET BOTH, then copy the Lua script.")
                . "`nCoordinate space: " Calib.SpaceText())
            Ui.Paint(c["t7"], ll["agree"] ? Clr.Green : Clr.Amber)
        }
    }

    ; Fast part of the page (mouse position, detection, highlighted cell) - runs from the test timer.
    static RefreshCalibLive() {
        c := Center.Ctl
        if !c.Has("t1")
            return
        d := Calib.Live
        if (!Calib.Testing || !d.Count) {
            SetText(c["t1"], "MOUSE   X -      Y -")
            SetText(c["t2"], "ROW -   COLUMN -")
            SetText(c["t4"], "-")
            SetText(c["t5"], Calib.Testing ? "move the cursor over the operator grid" : "TEST DETECTION IS OFF")
            Ui.Paint(c["t5"], Clr.Dim)
            Center.Paint(0)
            return
        }
        SetText(c["t1"], Format("MOUSE   X {}   Y {}   ({:.3f}, {:.3f})", d["x"], d["y"], d["nx"], d["ny"]))
        SetText(c["t2"], d["row"] ? "ROW " d["row"] "   COLUMN " d["col"] : "ROW -   COLUMN -")
        SetText(c["t4"], d["name"] != "" ? StrUpper(d["name"]) : "-")
        ok := d["name"] != ""
        SetText(c["t5"], ok ? "✓ GRID MATCH" : d["reason"] = "empty" ? "EMPTY TILE" : d["reason"] = "gap" ? "IN THE GAP BETWEEN TILES" : "OUTSIDE THE OPERATOR GRID")
        Ui.Paint(c["t5"], ok ? Clr.Green : Clr.Amber)
        Center.Paint(d["row"] ? (d["row"] - 1) * 7 + d["col"] : 0)
    }

    static Lit := 0
    static Paint(idx) {
        if (idx = Center.Lit)
            return
        if (Center.Lit >= 1 && Center.Lit <= Center.Cells.Length)
            Ui.Paint(Center.Cells[Center.Lit], Clr.Dim, Clr.Panel2)
        Center.Lit := idx
        if (idx >= 1 && idx <= Center.Cells.Length)
            Ui.Paint(Center.Cells[idx], Clr.Accent, Clr.Sel)
    }


    ; ==========================================================================
    ; RECOIL  (the coach: the system checks its own compensation and improves it)
    ; ==========================================================================
    static BuildRecoil(g) {
        add := Center.Reg.Bind(Center, "RECOIL")
        c := Center.Ctl
        c["r_toggle"] := add(Ui.Btn(g, 196, 76, 230, 46, "● COACH: OFF", () => Recorder.Toggle(), "p"))
        add(Ui.Btn(g, 436, 76, 200, 46, "HANDS-OFF TEST", () => Coach.StartTest()))
        c["r_mode"] := add(Ui.Txt(g, 650, 76, 310, 46, "", 9, "Norm", Clr.Dim))
        c["r_mode"].Opt("-0x200 -0x4000")
        Center.Card(add, g, 196, 136, 374, 136, "SYSTEM CHECK")
        c["r_k1"] := add(Ui.Txt(g, 210, 162, 346, 20, "", 9, "Bold", Clr.Text, Clr.Panel))
        c["r_k2"] := add(Ui.Txt(g, 210, 184, 346, 20, "", 9, "Norm", Clr.Dim, Clr.Panel))
        c["r_k3"] := add(Ui.Txt(g, 210, 206, 346, 20, "", 9, "Norm", Clr.Dim, Clr.Panel))
        c["r_k4"] := add(Ui.Txt(g, 210, 228, 346, 38, "", 8, "Norm", Clr.Mute, Clr.Panel))
        c["r_k4"].Opt("-0x200 -0x4000")
        Center.Card(add, g, 586, 136, 374, 136, "ACCURACY")
        c["r_acc"] := add(Ui.Txt(g, 600, 160, 150, 54, "", 30, "Bold", Clr.Accent, Clr.Panel, "", "Segoe UI Black"))
        c["r_a2"] := add(Ui.Txt(g, 760, 166, 190, 44, "", 8, "Norm", Clr.Dim, Clr.Panel))
        c["r_a2"].Opt("-0x200 -0x4000")
        c["r_spark"] := add(Ui.Mono(g, 600, 222, 346, 22, "", 13, Clr.Accent, Clr.Panel))
        c["r_a3"] := add(Ui.Txt(g, 600, 246, 346, 18, "", 8, "Norm", Clr.Mute, Clr.Panel))
        Center.Card(add, g, 196, 286, 764, 148, "WHAT THE COACH SEES IN YOUR LAST BURST")
        for i, n in ["r_p1", "r_p2", "r_p3", "r_p4"]
            c[n] := add(Ui.Txt(g, 210, 312 + (i - 1) * 26, 736, 24, "", 10, "Bold", Clr.Dim, Clr.Panel))
        c["r_prop"] := add(Ui.Txt(g, 210, 414, 736, 18, "", 8, "Norm", Clr.Mute, Clr.Panel))
        add(Ui.Btn(g, 196, 446, 210, 34, "COPY LUA SCRIPT", () => Center.CopyBlock(), "p"))
        add(Ui.Btn(g, 414, 446, 210, 34, "FORGET THIS WEAPON", () => Center.CoachForget(), "d"))
        add(Ui.Txt(g, 196, 490, 400, 16, "PROFILES THE COACH HAS BUILT", 8, "Bold", Clr.Mute))
        c["r_list"] := add(Ui.List(g, 196, 508, 764, 116, ["Loadout", "Bursts", "Accuracy", "r", "y1", "y2", "Updated"]))
        for i, w in [300, 70, 90, 70, 70, 70, 94]
            c["r_list"].ModifyCol(i, Ui.S(w))
    }

    static RefreshRec() {
        c := Center.Ctl
        on := Recorder.On
        SetText(c["r_toggle"], on ? "■ COACH: ON  (F6)" : "● COACH: OFF  (F6)")
        mode := Coach.Mode()
        SetText(c["r_mode"], Coach.Msg)
        key := Recorder.Key()
        parts := key != "" ? StrSplit(key, ":") : []
        ; --- system check ---
        SetText(c["r_k1"], "Mouse link:   " (mode = "" ? "⚠ not tested yet - press HANDS-OFF TEST" : mode = "phys" ? "✓ macro on a separate device"
            : mode = "subtract" ? "✓ macro shares your mouse channel (handled)" : "✓ macro invisible to Raw Input"))
        Ui.Paint(c["r_k1"], mode = "" ? Clr.Amber : Clr.Green)
        pk := Live.Get("recoil_profile", "")
        SetText(c["r_k2"], "Weapon:   " (key != "" ? parts[1] "  ·  " parts[2] "  ·  " parts[3] : "-") "      Profile: " (pk != "" ? pk : "-"))
        r := Coach.Result
        SetText(c["r_k3"], IsObject(r) ? "Last burst:   " Round(r["dur"] / 1000, 1) " s   ·   macro pulled " Round(r["py"]) " counts" : "Last burst:   none scored yet")
        SetText(c["r_k4"], on ? "Skipped so far: " Coach.Skipped "   ·   Bursts scored: " (Coach.Seen - Coach.Skipped)
            : "Turn the coach on and just play. Every spray with the macro is scored against how much you had to correct.")
        ; --- accuracy ---
        hist := key != "" ? Coach.History(key, 30) : []
        if (hist.Length) {
            last10 := 0, cnt := 0
            loop Min(10, hist.Length) {
                last10 += hist[hist.Length - A_Index + 1], cnt++
            }
            best := 0
            for v in hist
                best := Max(best, v)
            bars := "▁▂▃▄▅▆▇█", line := ""
            for v in hist
                line .= SubStr(bars, Clamp(Round(v / 100 * 7) + 1, 1, 8), 1)
            SetText(c["r_acc"], Round(hist[hist.Length]) "%")
            SetText(c["r_a2"], "last 10 avg " Round(last10 / cnt) "%`nbest " best "%   ·   " hist.Length " bursts")
            SetText(c["r_spark"], line)
            first := hist.Length >= 6 ? Round(Coach.Avg(hist, 1, 3)) : 0
            SetText(c["r_a3"], hist.Length >= 6 ? "started at " first "%  ->  now " Round(Coach.Avg(hist, hist.Length - 2, hist.Length)) "%" : "keep shooting: the trend appears after 6 bursts")
        } else {
            SetText(c["r_acc"], "--")
            SetText(c["r_a2"], "no scored bursts for this weapon yet")
            SetText(c["r_spark"], "")
            SetText(c["r_a3"], "")
        }
        ; --- what the coach sees ---
        if IsObject(r) {
            for i, ph in [["EARLY  (to 0.5 s)", "mA", "pa"], ["MID    (0.5 - 0.9 s)", "mB", "pb"], ["LATE   (0.9 s +)", "mC", "pc"]] {
                say := Coach.Say(r[ph[2]], r[ph[3]])
                SetText(c["r_p" i], ph[1] "     macro " say)
                Ui.Paint(c["r_p" i], say = "on target" ? Clr.Green : Clr.Amber)
            }
            SetText(c["r_p4"], "SIDEWAYS     " (Abs(r["mX"]) < 0.08 ? "no drift" : "you pull " (r["mX"] > 0 ? "right" : "left") " by " Round(Abs(r["mX"]), 2)))
            Ui.Paint(c["r_p4"], Abs(r["mX"]) < 0.08 ? Clr.Green : Clr.Amber)
        } else {
            for n in ["r_p1", "r_p2", "r_p3", "r_p4"]
                SetText(c[n], "")
            SetText(c["r_p1"], "Waiting for a burst with the macro pulling...")
        }
        ; --- proposal status ---
        e := key != "" && Cfg.Data["coach"]["hist"].Has(key) ? Cfg.Data["coach"]["hist"][key] : ""
        if IsObject(e) {
            saved := Cfg.Get("learned").Has(key)
            SetText(c["r_prop"], "This round: " e["n"] " burst(s)" (e["n"] < 3 ? " (needs 3 to propose an improvement)" : saved ? "  ·  improved profile saved: copy the Lua script to use it" : ""))
        } else
            SetText(c["r_prop"], "")
        lv := c["r_list"]
        lv.Delete()
        for k, e2 in Cfg.Data["coach"]["hist"] {
            if (Type(e2) != "Map" || !e2.Has("acc"))
                continue
            p := Cfg.Get("learned").Has(k) ? Cfg.Get("learned")[k] : ""
            a := e2["acc"]
            lv.Add("", k, a.Length, a.Length ? Round(a[a.Length]) "%" : "-", IsObject(p) ? Round(p["r"], 2) : "-"
                , IsObject(p) ? Format("{:+.2f}", p["y1"]) : "-", IsObject(p) ? Format("{:+.2f}", p["y2"]) : "-"
                , e2["t"] != "" ? FormatTime(e2["t"], "MM-dd HH:mm") : "")
        }
    }

    static CoachForget() {
        key := Recorder.Key()
        if (key = "")
            return
        if (MsgBox("Forget everything the coach learned for " key "?", "Recoil coach", "YesNo Icon?") != "Yes")
            return
        Coach.ForgetKey(key)
        Toast.Show("info", "COACH DATA CLEARED", key, "", "")
        View.Changed()
    }

    ; ==========================================================================
    ; SETTINGS
    ; ==========================================================================
    static BuildSettings(g) {
        add := Center.Reg.Bind(Center, "SETTINGS")
        c := Center.Ctl
        add(Ui.Txt(g, 196, 76, 200, 20, "GAME PROFILE", 8, "Bold", Clr.Mute))
        add(Ui.Btn(g, 402, 72, 166, 26, "READ FROM SIEGE", () => Center.ReadSiege()))
        y := 100
        for row in [["dpi", "DPI", "game.dpi", 50, 32000], ["sh", "Horizontal sensitivity", "game.sensH", 0.1, 100]
            , ["sv", "Vertical sensitivity", "game.sensV", 0.1, 100], ["fov", "FOV", "game.fov", 40, 140], ["ads", "ADS", "game.ads", 1, 200]] {
            add(Ui.Txt(g, 196, y + 2, 150, 24, row[2], 9, "Norm", Clr.Dim))
            e := add(Ui.Edit(g, 350, y, 120, 26))
            e.OnEvent("Change", Center.OnNum.Bind(Center, row[3], row[4], row[5]))
            c["s_" row[1]] := e
            y += 34
        }
        add(Ui.Txt(g, 196, 272, 150, 24, "Resolution", 9, "Norm", Clr.Dim))
        c["s_rw"] := add(Ui.Edit(g, 350, 270, 64, 26))
        add(Ui.Txt(g, 418, 272, 14, 24, "×", 10, "Bold", Clr.Dim))
        c["s_rh"] := add(Ui.Edit(g, 434, 270, 64, 26))
        for k in ["s_rw", "s_rh"]
            c[k].OnEvent("Change", (*) => Center.OnRes())
        add(Ui.Btn(g, 506, 268, 62, 30, "AUTO", () => Center.DetectRes()))

        add(Ui.Txt(g, 196, 318, 300, 20, "ATTACHMENT PREFERENCES", 8, "Bold", Clr.Mute))
        y := 342
        for row in [["scope", "Preferred scope"], ["barrel", "Preferred barrel"], ["grip", "Preferred grip"]] {
            add(Ui.Txt(g, 196, y + 2, 150, 24, row[2], 9, "Norm", Clr.Dim))
            items := row[1] = "scope" ? Db.AllScopes() : row[1] = "barrel" ? LoadoutMgr.BarrelChain : LoadoutMgr.GripChain
            d := add(Ui.Drop(g, 350, y, 218, items))
            d.OnEvent("Change", Center.OnPref.Bind(Center, row[1]))
            c["s_p" row[1]] := d
            y += 34
        }

        add(Ui.Txt(g, 596, 76, 300, 20, "APPLICATION", 8, "Bold", Clr.Mute))
        add(Ui.Txt(g, 596, 104, 140, 24, "Launch state", 9, "Norm", Clr.Dim))
        c["s_launch"] := add(Ui.Drop(g, 740, 100, 220, ["Compact HUD", "Control centre", "Hidden"]))
        c["s_launch"].OnEvent("Change", (ctrl, *) => (Center.Guard ? 0 : Cfg.Set("ui.launch", ["hud", "center", "hidden"][ctrl.Value])))
        Center.Toggles["s_rem"] := Toggle(g, 596, 138, 300, "Remember window position", true, (v) => (Center.Guard ? 0 : Cfg.Set("ui.rememberPos", v)))
        add(Center.Toggles["s_rem"].Ctl)
        Center.Toggles["s_not"] := Toggle(g, 596, 168, 300, "Launch with Windows", false, (v) => (Center.Guard ? 0 : Startup.Set(v)))
        add(Center.Toggles["s_not"].Ctl)
        c["s_scl"] := add(Ui.Txt(g, 596, 204, 364, 20, "", 8, "Bold", Clr.Mute))
        c["s_scale"] := add(Center.Slider(g, 596, 226, 364, "60-200", 100))
        c["s_scale"].OnEvent("Change", (ctrl, *) => Center.OnScale(ctrl))

        add(Ui.Txt(g, 596, 278, 300, 20, "CONFIGURATION", 8, "Bold", Clr.Mute))
        add(Ui.Btn(g, 596, 302, 176, 30, "EXPORT…", () => Center.CfgExport()))
        add(Ui.Btn(g, 784, 302, 176, 30, "IMPORT…", () => Center.CfgImport()))
        add(Ui.Btn(g, 596, 340, 176, 30, "CREATE BACKUP", () => Center.CfgBackup()))
        add(Ui.Btn(g, 784, 340, 176, 30, "RESTORE BACKUP…", () => Center.CfgRestore()))
        add(Ui.Btn(g, 596, 378, 364, 30, "RESET CONFIGURATION", () => Center.CfgReset(), "d"))
        c["s_cfg"] := add(Ui.Txt(g, 596, 416, 364, 36, "", 8, "Norm", Clr.Dim))
        c["s_cfg"].Opt("-0x200 -0x4000")

        Center.Card(add, g, 196, 470, 764, 154, "LUA SYNC")
        c["s_lua"] := add(Ui.Txt(g, 212, 496, 736, 22, "", 10, "Bold", Clr.Text, Clr.Panel))
        c["s_lua2"] := add(Ui.Txt(g, 212, 520, 736, 40, "", 9, "Norm", Clr.Dim, Clr.Panel))
        c["s_lua2"].Opt("-0x200 -0x4000")
        add(Ui.Btn(g, 212, 574, 300, 34, "COPY FULL LUA SCRIPT + MY CONFIG", () => Center.CopyBlock(), "p"))
        add(Ui.Txt(g, 526, 574, 424, 34, "G HUB → open the script → select all (Ctrl+A) → paste → save.", 8, "Norm", Clr.Mute, Clr.Panel))
    }

    static OnNum(path, lo, hi, ctrl, *) {
        if Center.Guard
            return
        v := Trim(ctrl.Text)
        if (IsNumber(v) && v + 0 >= lo && v + 0 <= hi) {
            Cfg.Set(path, v + 0)
            try ctrl.SetFont("c" Clr.Text)
            View.Changed()
        } else
            try ctrl.SetFont("c" Clr.Red)
    }

    static OnRes() {
        if Center.Guard
            return
        c := Center.Ctl
        w := Trim(c["s_rw"].Text), h := Trim(c["s_rh"].Text)
        if (IsInteger(w) && IsInteger(h) && w >= 640 && h >= 480) {
            Cfg.Set("game.resW", Integer(w)), Cfg.Set("game.resH", Integer(h))
            View.Changed()
        }
    }

    ; Fills sensitivity / FOV / ADS / resolution from Siege's own GameSettings.ini (DPI is not in that file).
    static ReadSiege() {
        ini := SiegeIni.Detect()
        g := Cfg.Data["game"]
        n := 0
        for k in ["sensH", "sensV", "fov", "ads"]
            if ini.Has(k) {
                g[k] := ini[k]
                n++
            }
        if (ini.Has("res") && RegExMatch(ini["res"], "^(\d+)x(\d+)$", &m)) {
            g["resW"] := Integer(m[1]), g["resH"] := Integer(m[2])
            n++
        }
        Cfg.Dirty()
        Center.RefreshSettings()
        Toast.Show(n ? "ok" : "warn", n ? "✓ READ FROM SIEGE" : "⚠ SIEGE SETTINGS NOT FOUND", n ? n " value(s) updated" : "Enter them by hand", "", "")
    }

    static DetectRes() {
        Cfg.Set("game.resW", A_ScreenWidth), Cfg.Set("game.resH", A_ScreenHeight)
        Center.RefreshSettings()
    }

    static OnPref(field, ctrl, *) {
        if (Center.Guard || ctrl.Text = "")
            return
        Cfg.Set("prefs." field, ctrl.Text)
        View.Changed()
    }

    static OnScale(ctrl) {
        if Center.Guard
            return
        Cfg.Set("ui.scale", ctrl.Value / 100)
        SetText(Center.Ctl["s_scl"], "UI SCALE   " ctrl.Value "%   (applies when you stop dragging)")
        View.RebuildSoon(true)
    }

    static RefreshSettings() {
        c := Center.Ctl
        Center.Guard := true
        for k, path in Map("s_dpi", "game.dpi", "s_sh", "game.sensH", "s_sv", "game.sensV", "s_fov", "game.fov", "s_ads", "game.ads") {
            if (!c[k].Focused)
                c[k].Text := Cfg.Get(path)
        }
        if (!c["s_rw"].Focused)
            c["s_rw"].Text := Cfg.Get("game.resW")
        if (!c["s_rh"].Focused)
            c["s_rh"].Text := Cfg.Get("game.resH")
        for f in ["scope", "barrel", "grip"] {
            d := c["s_p" f]
            i := IndexOf(f = "scope" ? Db.AllScopes() : f = "barrel" ? LoadoutMgr.BarrelChain : LoadoutMgr.GripChain, Cfg.Get("prefs." f))
            if i
                d.Choose(i)
        }
        c["s_launch"].Choose(IndexOf(["hud", "center", "hidden"], Cfg.Get("ui.launch", "hud")) || 1)
        Center.Toggles["s_rem"].Set(Cfg.Get("ui.rememberPos", 1))
        Center.Toggles["s_not"].Set(Startup.IsOn())
        pct := Round(Cfg.Num("ui.scale", 1.0) * 100)
        c["s_scale"].Value := pct
        SetText(c["s_scl"], "UI SCALE   " pct "%")
        st := Cfg.Status
        SetText(c["s_cfg"], "Config v" App.CfgVersion "  ·  " (st = "VALID" ? "✓ VALID" : st = "NEW" ? "new" : "⚠ " Cfg.StatusMsg)
            . (Cfg.SaveError != "" ? "`n⚠ last save failed: " Cfg.SaveError : "") "`n" App.Dir)
        Ui.Paint(c["s_cfg"], (st = "VALID" || st = "NEW") && Cfg.SaveError = "" ? Clr.Dim : Clr.Amber)
        lc := Sync.LuaConfig()
        SetText(c["s_lua"], (lc[1] = "OK" ? "● " : "⚠ ") lc[2])
        Ui.Paint(c["s_lua"], lc[1] = "OK" ? Clr.Green : lc[1] = "UNKNOWN" ? Clr.Dim : Clr.Amber)
        SetText(c["s_lua2"], "The G HUB Lua cannot read files, so your settings reach it inside the script itself. This button copies your whole "
            . "siege_profile_manager.lua with your config merged in: select all in the G HUB script, paste, save. It survives G HUB / Windows restarts.")
        Center.Guard := false
    }

    static CfgExport() {
        path := FileSelect("S16", A_Desktop "\siege-profile-manager-config.json", "Export configuration", "JSON (*.json)")
        if (path = "")
            return
        err := Cfg.Export(path)
        if (err = "")
            Toast.Show("ok", "✓ CONFIGURATION EXPORTED", "", "", "")
        else
            Toast.Show("error", "⚠ EXPORT FAILED", err, "", "")
    }

    static CfgImport() {
        path := FileSelect(1, A_Desktop, "Import configuration", "JSON (*.json)")
        if (path = "")
            return
        err := Cfg.Import(path)
        if (err = "") {
            Toast.Show("ok", "✓ CONFIGURATION IMPORTED", "A backup of the old one was kept", "", "")
            View.Rebuild()
        } else
            Toast.Show("error", "⚠ IMPORT REJECTED", err, "Current configuration untouched", "")
    }

    static CfgBackup() {
        p := Cfg.Backup()
        if (p != "")
            Toast.Show("ok", "✓ BACKUP CREATED", "backups folder", "", "")
        else
            Toast.Show("error", "⚠ BACKUP FAILED", "", "", "")
    }

    static CfgRestore() {
        path := FileSelect(1, App.BackupDir, "Restore a backup", "JSON (*.json)")
        if (path = "")
            return
        err := Cfg.Import(path)
        if (err = "") {
            Toast.Show("ok", "✓ BACKUP RESTORED", "", "", "")
            View.Rebuild()
        } else
            Toast.Show("error", "⚠ RESTORE REJECTED", err, "Current configuration untouched", "")
    }

    static CfgReset() {
        if (MsgBox("Reset ALL settings, loadouts, favourites and calibration?`nA backup is created first.", "Reset configuration", "YesNo Icon!") != "Yes")
            return
        Cfg.Reset()
        View.Rebuild()
        Wizard.Start()
    }

    ; ==========================================================================
    ; HOTKEYS
    ; ==========================================================================
    static BuildHotkeys(g) {
        add := Center.Reg.Bind(Center, "HOTKEYS")
        c := Center.Ctl
        for h in [[202, "GROUP"], [332, "ACTION"], [572, "BINDING"], [772, "STATUS"]]
            add(Ui.Txt(g, h[1], 76, 120, 16, h[2], 8, "Bold", Clr.Mute))
        c["k_list"] := add(Ui.List(g, 196, 96, 764, 340, ["Group", "Action", "Binding", "Status"]))
        for i, w in [130, 240, 200, 180]
            c["k_list"].ModifyCol(i, Ui.S(w))
        c["k_list"].OnEvent("ItemSelect", (ctrl, row, sel) => (sel && !Center.Guard ? Center.HkPick() : 0))
        Center.Card(add, g, 196, 448, 764, 176, "EDIT BINDING")
        c["k_sel"] := add(Ui.Txt(g, 212, 474, 736, 22, "", 10, "Bold", Clr.Text, Clr.Panel))
        add(Ui.Txt(g, 212, 506, 60, 24, "MODIFIER", 8, "Bold", Clr.Mute, Clr.Panel))
        c["k_mod"] := add(Ui.Drop(g, 276, 503, 130, ["LCTRL", "RCTRL", "LALT", "RALT", "LSHIFT", "RSHIFT"]))
        add(Ui.Txt(g, 420, 506, 60, 24, "BUTTON", 8, "Bold", Clr.Mute, Clr.Panel))
        c["k_btn"] := add(Ui.Drop(g, 484, 503, 110, ["LMB", "RMB", "MMB", "MB4", "MB5"]))
        c["k_key"] := add(Ui.Edit(g, 276, 503, 130, 26))
        add(Ui.Btn(g, 610, 500, 120, 30, "APPLY", () => Center.HkApply(), "p"))
        add(Ui.Btn(g, 738, 500, 120, 30, "RESET", () => Center.HkReset()))
        c["k_msg"] := add(Ui.Txt(g, 212, 544, 736, 70, "", 9, "Norm", Clr.Dim, Clr.Panel))
        c["k_msg"].Opt("-0x200 -0x4000")
    }

    static RefreshHotkeys() {
        c := Center.Ctl
        lv := c["k_list"]
        Center.Guard := true
        keep := lv.GetNext()
        lv.Opt("-Redraw")
        lv.Delete()
        Center.HkRows := Hk.Rows()
        conf := Hk.Conflicts()
        for r in Center.HkRows {
            st := conf.Has(r["key"]) ? "⚠ " conf[r["key"]] : r["type"] = "fixed" ? "fixed" : r["custom"] ? "custom" : "default"
            lv.Add("", r["group"], r["label"], r["text"], st)
        }
        if (keep >= 1 && keep <= Center.HkRows.Length)
            lv.Modify(keep, "Select Focus")
        lv.Opt("+Redraw")
        Center.Guard := false
        Center.HkPick()
    }

    static HkSel() {
        row := Center.Ctl["k_list"].GetNext()
        return (row >= 1 && row <= Center.HkRows.Length) ? Center.HkRows[row] : ""
    }

    static HkPick() {
        c := Center.Ctl
        r := Center.HkSel()
        lua := IsObject(r) && r["type"] = "lua"
        ahk := IsObject(r) && r["type"] = "ahk"
        c["k_mod"].Visible := lua
        c["k_btn"].Visible := lua
        c["k_key"].Visible := ahk
        if !IsObject(r) {
            SetText(c["k_sel"], "Select a row to edit its binding")
            SetText(c["k_msg"], "")
            return
        }
        SetText(c["k_sel"], r["label"] "   ·   " r["text"])
        Center.Guard := true
        if lua {
            c["k_mod"].Choose(IndexOf(Hk.Mods, r["mod"]))
            c["k_btn"].Choose(r["button"])
        } else if ahk
            c["k_key"].Text := r["value"]
        Center.Guard := false
        SetText(c["k_msg"], lua ? "Manager hotkeys are read by the G HUB Lua: a change is sent with the config block (Settings > COPY FULL LUA SCRIPT) and takes effect when the script reloads."
            : ahk ? "These hotkeys work immediately. Type a key name such as F8, F9, F7, Insert, ^F8 (Ctrl+F8)."
            : "This binding is fixed: it is set in the Lua (CONFIG.input) and used in fixed places.")
    }

    static HkApply() {
        r := Center.HkSel()
        if !IsObject(r)
            return
        c := Center.Ctl
        if (r["type"] = "lua") {
            md := StrLower(c["k_mod"].Text)
            btn := c["k_btn"].Value
            clash := Hk.WouldClash(r["id"], md, btn)
            if (clash != "") {
                Toast.Show("warn", "⚠ BINDING CONFLICT", StrUpper(md) " + " Hk.Btns[btn], "already used by " clash, "")
                return
            }
            Cfg.Data["luaKeybinds"][r["id"]] := Map("mod", md, "button", btn)
            Cfg.Dirty()
            Toast.Show("ok", "✓ BINDING CHANGED", r["label"], StrUpper(md) " + " Hk.Btns[btn], "Copy the Lua script to apply")
        } else if (r["type"] = "ahk") {
            err := Hk.SetAhk(r["id"], Trim(c["k_key"].Text))
            if (err != "") {
                Toast.Show("warn", "⚠ HOTKEY NOT ACCEPTED", err, "", "")
                return
            }
            Toast.Show("ok", "✓ HOTKEY CHANGED", r["label"], Trim(c["k_key"].Text), "")
        } else
            return
        Center.RefreshHotkeys()
        View.Changed()
    }

    static HkReset() {
        r := Center.HkSel()
        if !IsObject(r)
            return
        if (r["type"] = "lua" && Cfg.Data["luaKeybinds"].Has(r["id"])) {
            Cfg.Data["luaKeybinds"].Delete(r["id"])
            Cfg.Dirty()
        } else if (r["type"] = "ahk")
            Hk.SetAhk(r["id"], Hk.AhkDefaults[r["id"]])
        Center.RefreshHotkeys()
    }

    ; ==========================================================================
    ; DIAGNOSTICS
    ; ==========================================================================
    static BuildDiagnostics(g) {
        add := Center.Reg.Bind(Center, "DIAGNOSTICS")
        c := Center.Ctl
        ; read-only Edit (not a label): the report is longer than the box, so it needs a scroll bar
        g.SetFont("s" Ui.Pt(9) " Norm c" Clr.Text, "Consolas")
        c["d_text"] := add(g.AddEdit("x" Ui.S(196) " y" Ui.S(76) " w" Ui.S(764) " h" Ui.S(352) " ReadOnly Multi +VScroll Background" Clr.Panel, ""))
        Ui.DarkTheme(c["d_text"], "Explorer")
        add(Ui.Btn(g, 196, 438, 220, 32, "COPY DIAGNOSTIC REPORT", () => Center.CopyReport(), "p"))
        add(Ui.Btn(g, 424, 438, 150, 32, "CLEAR LOG", () => (Diag.Lines := [], Center.RefreshDiag())))
        add(Ui.Btn(g, 582, 438, 200, 32, "RUN SETUP WIZARD", () => Wizard.Start()))
        add(Ui.Txt(g, 792, 442, 168, 24, "Report has no personal data.", 8, "Norm", Clr.Mute))
        add(Ui.Txt(g, 196, 480, 300, 16, "EVENT LOG", 8, "Bold", Clr.Mute))
        c["d_log"] := add(Ui.List(g, 196, 498, 764, 126, ["Log"]))
        c["d_log"].ModifyCol(1, Ui.S(740))
    }

    static DiagLast := ""
    static RefreshDiag() {
        c := Center.Ctl
        txt := StrReplace(Diagnostics.Text(), "`n", "`r`n")
        if (txt != Center.DiagLast) {
            Center.DiagLast := txt
            ctl := c["d_text"]
            first := 0
            try first := SendMessage(0xCE, 0, 0, ctl)       ; EM_GETFIRSTVISIBLELINE: keep the scroll position
            ctl.Value := txt
            if first
                try SendMessage(0xB6, 0, first, ctl)        ; EM_LINESCROLL
        }
        lv := c["d_log"]
        lv.Opt("-Redraw")
        lv.Delete()
        loop Diag.Lines.Length
            lv.Add("", Diag.Lines[Diag.Lines.Length - A_Index + 1])
        lv.Opt("+Redraw")
    }
}

; ------------------------------------------------------------------------------
; 16. CALIBRATION  (geometry, detection maths, capture; mirrors the Lua's grid maths)
;     Points are normalised 0..1 of the primary monitor, the same space the Lua uses.
; ------------------------------------------------------------------------------
class Calib {
    static Side := "attackers"
    static Active := false
    static Step := 1
    static Pts := []
    static Err := ""
    static Testing := false
    static Live := Map()
    static LastLua := ""
    static Fn := ""

    static PresetName() => Cfg.Get("game.resW") "x" Cfg.Get("game.resH")

    static HasCal(side) => Cfg.Get("calibration").Has(side)

    ; Map(tlx, tly, brx, bry, padx, pady): the calibrated grid, else the preset for the resolution.
    static Other(side) => side = "attackers" ? "defenders" : "attackers"

    ; Attackers and defenders share one selector layout, so an uncalibrated side uses the other side's grid
    ; (exactly what the Lua does).
    static Shared(side) => (!Calib.HasCal(side) && Calib.HasCal(Calib.Other(side)))

    static Geometry(side) {
        pre := Db.Presets.Has(Calib.PresetName() "|" side) ? Db.Presets[Calib.PresetName() "|" side] : Db.Presets["1920x1080|" side]
        g := Map("padx", pre["padx"], "pady", pre["pady"])
        src := Calib.HasCal(side) ? Cfg.Get("calibration")[side] : Calib.Shared(side) ? Cfg.Get("calibration")[Calib.Other(side)] : pre
        for k in ["tlx", "tly", "brx", "bry"]
            g[k] := src[k]
        return g
    }

    static Status(side) {
        if (Calib.Active && Calib.Side = side)
            return "CALIBRATING"
        if (Calib.Err != "" && Calib.Side = side)
            return "ERROR"
        if Calib.HasCal(side)
            return "CALIBRATED"
        return Calib.Shared(side) ? "CALIBRATED (SHARED)" : "NOT CALIBRATED (PRESET)"
    }
    static Short(side) {
        s := Calib.Status(side)
        return InStr(s, "CALIBRATED") && !InStr(s, "NOT") ? "✓" : s = "CALIBRATING" ? "…" : s = "ERROR" ? "✗" : "⚠"
    }
    static Long(side) {
        s := Calib.Status(side)
        return s = "CALIBRATED" ? "✓ CALIBRATED" : s = "CALIBRATED (SHARED)" ? "✓ SHARED WITH " Db.SideLabel(Calib.Other(side))
            : s = "CALIBRATING" ? "… CALIBRATING" : s = "ERROR" ? "✗ ERROR" : "⚠ PRESET"
    }
    static Color(side) {
        s := Calib.Status(side)
        return (InStr(s, "CALIBRATED") && !InStr(s, "NOT")) ? Clr.Green : s = "ERROR" ? Clr.Red : Clr.Amber
    }
    static Mode() => "corner calibration"

    static Start(side) {
        Calib.Side := side
        Calib.Active := true
        Calib.Step := 1
        Calib.Pts := []
        Calib.Err := ""
        Toast.Show("info", "CALIBRATION STARTED", Db.SideLabel(side) " GRID", "Step 1/2: TOP LEFT  (" Cfg.Get("hotkeys.capture") ")", "")
        View.Changed()
    }

    static Cancel() {
        if Calib.Active
            Toast.Show("warn", "CALIBRATION CANCELLED", "", "", "")
        Calib.Active := false
        Calib.Pts := []
        View.Changed()
    }

    ; Capture hotkey: normalised cursor position on the primary monitor.
    static Capture() {
        if !Calib.Active {
            Toast.Show("warn", "⚠ NOT CALIBRATING", "Press START CALIBRATION first", "", "")
            return
        }
        MouseGetPos(&x, &y)
        n := Calib.Norm(x, y)
        Calib.AddPoint(n[1], n[2])
    }

    static AddPoint(nx, ny) {
        Calib.Pts.Push([nx, ny])
        if (Calib.Pts.Length = 1) {
            Calib.Step := 2
            Toast.Show("info", "CALIBRATION POINT 1/2", "TOP LEFT captured", Format("{:.4f}, {:.4f}", nx, ny), "Now: BOTTOM RIGHT")
        } else
            Calib.Complete()
        View.Changed()
    }

    static Complete() {
        a := Calib.Pts[1], b := Calib.Pts[2]
        Calib.Pts := []
        Calib.Active := false
        if (b[1] <= a[1] || b[2] <= a[2]) {
            Calib.Err := "2nd point must be right of and below the 1st"
            Toast.Show("warn", "⚠ CALIBRATION FAILED", Calib.Err, "Start again", "")
            return
        }
        Calib.Err := ""
        Calib.Store(Calib.Side, a[1], a[2], b[1], b[2], "ahk")
        Cfg.Dirty()
        Toast.Show("ok", "✓ CALIBRATION COMPLETE", Db.SideLabel(Calib.Side) " GRID", "Copy the Lua script to use it in game", "")
    }

    ; src = "lua": measured with the Lua's own cursor reading (RSHIFT+MB4); "ahk": captured here.
    static Store(side, tlx, tly, brx, bry, src := "lua") {
        Cfg.Data["calibration"][side] := Map("tlx", tlx, "tly", tly, "brx", brx, "bry", bry, "res", Calib.PresetName(), "src", src)
        return true
    }

    ; ---- coordinate space -------------------------------------------------------------------
    ; The Lua reads the cursor as a fraction of G HUB's 0..65535 range. On one monitor that equals
    ; x / screen width; with several monitors it may span the WHOLE desktop instead. Points captured
    ; here must be converted the same way or the pasted calibration is wrong. The space is learned
    ; from the Lua's own click reports (detect_result / calibration_point) and stored.
    static Space() => Cfg.Get("game.coordSpace", "")

    static SingleMonitor() => (SysGet(76) = 0 && SysGet(77) = 0 && SysGet(78) = A_ScreenWidth && SysGet(79) = A_ScreenHeight)

    static SpaceOK() => (Calib.Space() != "" || Calib.SingleMonitor())

    static SpaceText() {
        sp := Calib.Space()
        if (sp != "")
            return "learned: " sp " monitor space"
        return Calib.SingleMonitor() ? "single monitor (no ambiguity)" : "NOT VERIFIED (multi-monitor): click a tile with RSHIFT+LMB in game"
    }

    ; screen pixels -> the Lua's 0..1 space
    static Norm(px, py) {
        if (Calib.Space() = "virtual") {
            vl := SysGet(76), vt := SysGet(77), vw := SysGet(78), vh := SysGet(79)
            return [(px - vl) / vw, (py - vt) / vh]
        }
        return [px / A_ScreenWidth, py / A_ScreenHeight]
    }

    ; Called with a point the Lua just reported (lx, ly in ITS space) while the cursor is still there.
    static Learn(lx, ly) {
        MouseGetPos(&px, &py)
        vl := SysGet(76), vt := SysGet(77), vw := SysGet(78), vh := SysGet(79)
        dp := Abs(px / A_ScreenWidth - lx) + Abs(py / A_ScreenHeight - ly)
        dv := Abs((px - vl) / vw - lx) + Abs((py - vt) / vh - ly)
        if (Abs(dp - dv) < 0.02 || Min(dp, dv) > 0.06)
            return                                      ; ambiguous (single monitor) or the cursor already moved
        sp := dp < dv ? "primary" : "virtual"
        if (Calib.Space() != sp) {
            Cfg.Set("game.coordSpace", sp)
            Diag.Log("coordinate space learned: " sp)
        }
    }

    ; A calibration is sent to the Lua only if it was measured by the Lua, or the space is verified.
    static Exportable(c) => (c.Get("src", "") = "lua" || Calib.SpaceOK())

    static Matches(c, text) {
        p := StrSplit(text, ",")
        if (p.Length != 4)
            return false
        for i, k in ["tlx", "tly", "brx", "bry"]
            if (!IsNumber(p[i]) || Abs(p[i] - c[k]) > 0.001)
                return false
        return true
    }

    ; entries saved by older versions have no source: it is "lua" if the Lua reports the same numbers
    static SetSrc(side, luaText) {
        c := Cfg.Data["calibration"].Has(side) ? Cfg.Data["calibration"][side] : ""
        if (!IsObject(c) || c.Get("src", "") != "")
            return false
        c["src"] := Calib.Matches(c, luaText) ? "lua" : "ahk"
        return true
    }

    ; what the Lua reported for its last RSHIFT+click, compared with this app's own grid maths
    static LuaLast := Map()
    static OnLuaDetect(e) {
        x := Float(e.Get("x", 0)), y := Float(e.Get("y", 0))
        side := e.Get("side", "attackers")
        Calib.Learn(x, y)
        d := Calib.Detect(x, y, side)
        lr := Integer(e.Get("row", 0)), lc := Integer(e.Get("col", 0))
        agree := (d["row"] = lr && d["col"] = lc)
        Calib.LuaLast := Map("x", x, "y", y, "side", side, "row", lr, "col", lc, "result", e.Get("result", ""), "name", e.Get("name", "-")
            , "ahkRow", d["row"], "ahkCol", d["col"], "ahkName", d["name"], "agree", agree)
        View.Changed()
    }

    ; Clears every grid saved here so the Lua falls back to its own presets (the calibration "undo").
    static ResetBoth() {
        for side in Db.Sides
            if Calib.HasCal(side)
                Cfg.Data["calibration"].Delete(side)
        Cfg.Dirty()
        Calib.Err := ""
        Toast.Show("info", "CALIBRATION RESET", "Both grids use the Lua presets", "Copy the Lua script to apply", "")
        View.Changed()
    }

    static ResetSide(side) {
        Cfg.Data["calibration"].Delete(side)
        Cfg.Dirty()
        Calib.Err := ""
        Toast.Show("info", "CALIBRATION RESET", Db.SideLabel(side) " grid uses the preset", "Copy the Lua script to apply", "")
        View.Changed()
    }

    ; --- events from the Lua's own calibration (RSHIFT+MB4) -------------------
    static OnLuaStarted(sideLabel) {
        Calib.Side := Db.SideFromLua(sideLabel)
        Calib.Active := true, Calib.Step := 1, Calib.Pts := [], Calib.Err := ""
        View.Changed()
    }
    static OnLuaPoint(sideLabel, step, x, y) {
        Calib.Side := Db.SideFromLua(sideLabel)
        Calib.Learn(x, y)
        Calib.Pts.Push([x, y])
        Calib.Step := Min(2, step + 1)
        View.Changed()
    }
    static OnLuaComplete(sideLabel, tlx, tly, brx, bry) {
        side := Db.SideFromLua(sideLabel)
        Calib.Side := side
        Calib.Active := false, Calib.Pts := [], Calib.Err := ""
        Cfg.FromLua(Calib.Store.Bind(Calib, side, tlx, tly, brx, bry, "lua"))
        View.Changed()
    }
    static OnLuaFailed(sideLabel, reason) {
        Calib.Active := false, Calib.Pts := []
        Calib.Err := (reason = "cancelled") ? "" : reason
        View.Changed()
    }
    static OnLuaReset(sideLabel) {
        side := Db.SideFromLua(sideLabel)
        Cfg.FromLua(Calib.DropCal.Bind(Calib, side))
        Calib.Err := ""
        View.Changed()
    }
    static DropCal(side) {
        if !Calib.HasCal(side)
            return false
        Cfg.Data["calibration"].Delete(side)
        return true
    }

    ; --- detection (same maths as the Lua's MapCoordinatesToOperatorGrid) -----
    static Detect(nx, ny, side) {
        g := Calib.Geometry(side)
        out := Map("row", 0, "col", 0, "name", "", "reason", "outside")
        if (nx < g["tlx"] || ny < g["tly"] || nx > g["brx"] || ny > g["bry"])
            return out
        cols := 7, rows := 7
        cw := ((g["brx"] - g["tlx"]) - g["padx"] * (cols - 1)) / cols
        ch := ((g["bry"] - g["tly"]) - g["pady"] * (rows - 1)) / rows
        px := cw + g["padx"], py := ch + g["pady"]
        col := Floor((nx - g["tlx"]) / px) + 1
        row := Floor((ny - g["tly"]) / py) + 1
        if (col > cols || row > rows)
            return out
        inX := (nx - g["tlx"]) - (col - 1) * px
        inY := (ny - g["tly"]) - (row - 1) * py
        if (inX > cw || inY > ch) {
            out["reason"] := "gap"
            return out
        }
        out["row"] := row, out["col"] := col
        name := Db.Grid[side][row][col]
        out["name"] := name
        out["reason"] := name = "" ? "empty" : ""
        return out
    }

    static SetTesting(on) {
        on := on ? true : false
        if (on = Calib.Testing && IsObject(Calib.Fn))
            return                              ; no change (the wizard calls this on every step)
        Calib.Testing := on
        if !IsObject(Calib.Fn)
            Calib.Fn := ObjBindMethod(Calib, "Tick")
        if on
            SetTimer(Calib.Fn, 60)
        else {
            SetTimer(Calib.Fn, 0)               ; period 0 deletes the timer in AHK v2
            Calib.Live := Map()
        }
        View.Changed()
    }

    static Tick() {
        MouseGetPos(&x, &y)
        n := Calib.Norm(x, y)
        nx := n[1], ny := n[2]
        d := Calib.Detect(nx, ny, Calib.Side)
        d["x"] := x, d["y"] := y, d["nx"] := nx, d["ny"] := ny
        Calib.Live := d
        if (Center.Visible && Center.Cur = "CALIBRATION")
            Center.RefreshCalibLive()
        if Wizard.Visible
            Wizard.Refresh()
    }
}

; ------------------------------------------------------------------------------
; 16b. AUTO CALIBRATION  (finds the 7x7 operator grid on screen, no clicks)
;     Screenshots the primary monitor, counts hard edges per column / row, then looks for seven
;     evenly spaced tile edges (left + right) on each axis. Only a clean, plausible result is
;     saved; anything uncertain is rejected and the manual 2-click calibration stays available.
;     It runs by itself while Siege is the active window and a side has no calibration yet.
; ------------------------------------------------------------------------------
class AutoCal {
    static Busy := false
    static Last := ""

    ; Screenshot -> 32-bit top-down pixel buffer (B,G,R,A per pixel)
    static Grab(w, h) {
        hdc := DllCall("GetDC", "Ptr", 0, "Ptr")
        mdc := DllCall("CreateCompatibleDC", "Ptr", hdc, "Ptr")
        bmp := DllCall("CreateCompatibleBitmap", "Ptr", hdc, "Int", w, "Int", h, "Ptr")
        old := DllCall("SelectObject", "Ptr", mdc, "Ptr", bmp, "Ptr")
        DllCall("BitBlt", "Ptr", mdc, "Int", 0, "Int", 0, "Int", w, "Int", h, "Ptr", hdc, "Int", 0, "Int", 0, "UInt", 0x40CC0020)   ; SRCCOPY | CAPTUREBLT
        bi := Buffer(40, 0)
        NumPut("UInt", 40, bi, 0), NumPut("Int", w, bi, 4), NumPut("Int", -h, bi, 8), NumPut("UShort", 1, bi, 12), NumPut("UShort", 32, bi, 14)
        buf := Buffer(w * h * 4, 0)
        DllCall("GetDIBits", "Ptr", mdc, "Ptr", bmp, "UInt", 0, "UInt", h, "Ptr", buf, "Ptr", bi, "UInt", 0)
        DllCall("SelectObject", "Ptr", mdc, "Ptr", old)
        DllCall("DeleteObject", "Ptr", bmp)
        DllCall("DeleteDC", "Ptr", mdc)
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
        return buf
    }

    ; How many sampled lines have a hard edge at each column (px) and each row (py). Index = pixel + 1.
    static Profiles(buf, w, h, &px, &py) {
        px := [], py := []
        loop w
            px.Push(0)
        loop h
            py.Push(0)
        thr := 28, stp := 4
        y := 0
        while (y < h) {
            row := y * w * 4 + 1                        ; +1 = the green byte, a good enough brightness
            prev := NumGet(buf, row, "UChar")
            x := 1
            while (x < w) {
                cur := NumGet(buf, row + x * 4, "UChar")
                if (Abs(cur - prev) > thr)
                    px[x + 1] += 1
                prev := cur
                x += 1
            }
            y += stp
        }
        x := 0
        while (x < w) {
            prev := NumGet(buf, x * 4 + 1, "UChar")
            y := 1
            while (y < h) {
                cur := NumGet(buf, (y * w + x) * 4 + 1, "UChar")
                if (Abs(cur - prev) > thr)
                    py[y + 1] += 1
                prev := cur
                y += 1
            }
            x += stp
        }
    }

    ; Finds the seven-tile comb on one axis. Returns Map(start, stop, score) in pixels or "" when nothing clean is found.
    static Comb(P) {
        n := P.Length
        mx := 0
        for v in P
            mx := Max(mx, v)
        if (mx < 12)
            return ""
        hist := []
        loop mx + 1
            hist.Push(0)
        for v in P
            hist[v + 1] += 1
        cut := n * 0.02, acc := 0, p98 := mx
        loop mx + 1 {
            i := mx + 2 - A_Index
            acc += hist[i]
            if (acc >= cut) {
                p98 := i - 1
                break
            }
        }
        T := Max(8, p98 * 0.5)
        ; M = P widened by +-3 px, so a fractional pitch still lands on the edge
        M := []
        loop n {
            lo := Max(1, A_Index - 3), hi := Min(n, A_Index + 3), m := 0
            i := lo
            while (i <= hi) {
                m := Max(m, P[i])
                i += 1
            }
            M.Push(m)
        }
        cands := []
        loop n
            if (P[A_Index] >= T)
                cands.Push(A_Index)
        if (cands.Length < 7)
            return ""
        best := 0, bs := 0, bp := 0, bc := 0
        p := Max(8, Round(n * 0.03))
        pmax := Round(n * 0.2)
        while (p <= pmax) {
            for s in cands {
                if (s + 6 * p + p > n)
                    break
                sum := 0, ok := true
                loop 7 {
                    v := M[Round(s + (A_Index - 1) * p)]
                    if (v < T) {
                        ok := false
                        break
                    }
                    sum += v
                }
                if !ok
                    continue
                cb := 0, csum := 0
                c := Round(p * 0.8)
                while (c <= Round(p * 0.995)) {
                    rs := 0, ok2 := true
                    loop 7 {
                        pos := Round(s + c + (A_Index - 1) * p)
                        v := pos <= n ? M[pos] : 0
                        if (v < T) {
                            ok2 := false
                            break
                        }
                        rs += v
                    }
                    if (ok2 && rs > csum)
                        csum := rs, cb := c
                    c += 1
                }
                if (cb && sum + csum > best)
                    best := sum + csum, bs := s, bp := p, bc := cb
            }
            p += 0.5
        }
        if !bs
            return ""
        ; snap both outer edges to the strongest nearby line
        a := bs, b := Round(bs + 6 * bp + bc)
        va := 0, vb := 0
        loop 7 {
            ia := bs - 4 + A_Index, ib := b - 4 + A_Index
            if (ia >= 1 && ia <= n && P[ia] > va)
                va := P[ia], a := ia
            if (ib >= 1 && ib <= n && P[ib] > vb)
                vb := P[ib], b := ib
        }
        return Map("start", a - 1, "stop", b - 1, "score", best, "pitch", bp)
    }

    ; Detects the grid and saves it for `side`. quiet = no toasts on failure (background attempts).
    static Run(side, quiet := false) {
        if (AutoCal.Busy || Calib.Active)
            return false
        AutoCal.Busy := true
        ok := false
        try {
            w := A_ScreenWidth, h := A_ScreenHeight
            buf := AutoCal.Grab(w, h)
            AutoCal.Profiles(buf, w, h, &px, &py)
            cx := AutoCal.Comb(px)
            cy := AutoCal.Comb(py)
            why := ""
            if (!IsObject(cx) || !IsObject(cy))
                why := "no 7x7 tile grid found on screen"
            else if ((cx["stop"] - cx["start"]) < w * 0.2 || (cy["stop"] - cy["start"]) < h * 0.2)
                why := "the grid it found is too small to be the operator selector"
            else if (cx["start"] < 0 || cy["start"] < 0 || cx["stop"] > w || cy["stop"] > h)
                why := "the grid it found runs off the screen"
            if (why = "") {
                a := Calib.Norm(cx["start"], cy["start"]), b := Calib.Norm(cx["stop"], cy["stop"])
                if (b[1] <= a[1] || b[2] <= a[2])
                    why := "the corners came out in the wrong order"
            }
            if (why != "") {
                AutoCal.Last := why
                Diag.Log("auto calibration: " why)
                if !quiet
                    Toast.Show("warn", "AUTO CALIBRATION", "Could not find the grid", "Open the operator selector and try again, or use MANUAL", "")
            } else {
                Calib.Store(side, a[1], a[2], b[1], b[2], "auto")
                Cfg.Dirty()
                AutoCal.Last := Format("found {:.4f},{:.4f} to {:.4f},{:.4f}", a[1], a[2], b[1], b[2])
                Diag.Log("auto calibration " side ": " AutoCal.Last)
                Toast.Show("ok", "✓ AUTO CALIBRATED", Db.SideLabel(side) " GRID", "Copy the Lua script to use it in game", "")
                ok := true
            }
        } catch as e {
            AutoCal.Last := "error: " e.Message
            Diag.Log("auto calibration " AutoCal.Last)
            if !quiet
                Toast.Show("warn", "AUTO CALIBRATION", "Failed: " e.Message, "", "")
        } finally
            AutoCal.Busy := false
        View.Changed()
        return ok
    }

    ; Background attempt: only while Siege is the active window and the current side has no grid of its own.
    static Tick() {
        if (!Cfg.Get("game.autoCal", 1) || AutoCal.Busy || Calib.Active || Calib.Testing)
            return
        side := Calib.Side
        if (Calib.HasCal(side) || Calib.Shared(side))
            return
        if !SlotSync.SiegeActive()
            return
        AutoCal.Run(side, true)
    }
}

; ------------------------------------------------------------------------------
; 17. HOTKEYS
; ------------------------------------------------------------------------------
class Hk {
    static Mods := ["lctrl", "rctrl", "lalt", "ralt", "lshift", "rshift"]
    static Btns := Map(1, "LMB", 2, "RMB", 3, "MMB", 4, "MB4", 5, "MB5")
    ; group, Lua action id, label, default modifier, default button (as in CONFIG.input.keybinds)
    static LuaDefs := [
        ["OPERATOR", "nextOperator", "Next operator", "rctrl", 5], ["OPERATOR", "prevOperator", "Previous operator", "rctrl", 4],
        ["OPERATOR", "toggleFavorite", "Favourite on/off", "rctrl", 1], ["OPERATOR", "nextFavorite", "Next favourite", "lctrl", 5],
        ["OPERATOR", "prevFavorite", "Previous favourite", "lctrl", 4], ["OPERATOR", "toggleSide", "Attack / Defence page", "lctrl", 1],
        ["LOADOUT", "nextPrimary", "Next primary weapon", "lalt", 5], ["LOADOUT", "nextSecondary", "Next secondary weapon", "lalt", 4],
        ["LOADOUT", "nextLoadout", "Next saved loadout", "ralt", 2], ["LOADOUT", "prevLoadout", "Previous saved loadout", "ralt", 3],
        ["ATTACHMENTS", "nextScope", "Next scope", "lshift", 5], ["ATTACHMENTS", "nextBarrel", "Next barrel", "lshift", 4],
        ["ATTACHMENTS", "nextGrip", "Next grip", "lalt", 3],
        ["CALIBRATION", "toggleCalibration", "Calibrate: start / set corner", "rshift", 4], ["CALIBRATION", "resetCalibration", "Cancel / reset calibration", "rshift", 5],
        ["SYSTEM", "toggleSystem", "System on/off", "ralt", 5], ["SYSTEM", "toggleDebug", "Debug on/off", "ralt", 4],
        ["SYSTEM", "redraw", "Redraw / resend state", "ralt", 1]
    ]
    static AhkDefaults := Map("mode", "F8", "visible", "F9", "capture", "F7", "profiles", "F10", "record", "F6")
    static AhkLabels := Map("mode", "Compact HUD / Control centre", "visible", "Show / hide everything"
        , "capture", "Capture calibration point", "profiles", "Copy tuned recoil profiles", "record", "Recoil coach on / off")
    static AhkGroups := Map("mode", "HUD", "visible", "HUD", "capture", "CALIBRATION", "profiles", "SYSTEM", "record", "RECOIL")
    static Fn := Map()

    static Text(md, btn) => StrUpper(md) " + " Hk.Btns[btn]

    static Effective(def) {
        o := Cfg.Get("luaKeybinds")
        if (Type(o) = "Map" && o.Has(def[2]))
            return [o[def[2]]["mod"], o[def[2]]["button"], true]
        return [def[4], def[5], false]
    }

    static Rows() {
        rows := []
        rows.Push(Map("group", "OPERATOR", "label", "Detect operator (click a tile)", "text", "RSHIFT + LMB", "key", "fixed:detect", "type", "fixed", "id", "detect", "mod", "rshift", "button", 1, "custom", false))
        for d in Hk.LuaDefs {
            e := Hk.Effective(d)
            rows.Push(Map("group", d[1], "label", d[3], "text", Hk.Text(e[1], e[2]), "key", "lua:" d[2], "type", "lua"
                , "id", d[2], "mod", e[1], "button", e[2], "custom", e[3]))
        }
        for id in ["mode", "visible", "capture", "profiles", "record"] {
            k := Cfg.Get("hotkeys." id, Hk.AhkDefaults[id])
            rows.Push(Map("group", Hk.AhkGroups[id], "label", Hk.AhkLabels[id], "text", k, "key", "ahk:" id, "type", "ahk"
                , "id", id, "value", k, "custom", k != Hk.AhkDefaults[id]))
        }
        rows.Push(Map("group", "SYSTEM", "label", "Select weapon slot (in Siege)", "text", "1 / 2", "key", "fixed:slot", "type", "fixed", "id", "slot", "custom", false))
        for t in [["Tune: raise value", "MB5"], ["Tune: lower value", "MB4"], ["Tune: next step", "LALT + MB5"], ["Tune: previous step", "LALT + MB4"], ["Tune: reset weapon", "LSHIFT + MB4"]]
            rows.Push(Map("group", "TUNE MODE", "label", t[1], "text", t[2], "key", "fixed:" t[1], "type", "fixed", "id", t[1], "custom", false))
        return rows
    }

    ; row key -> conflict description, for every binding that is used twice.
    static Conflicts() {
        use := Map()
        for r in Hk.Rows() {
            if (r["type"] = "lua" || r["id"] = "detect")
                k := "m:" r["mod"] ":" r["button"]
            else if (r["type"] = "ahk")
                k := "a:" StrLower(r["value"])
            else if (r["id"] = "slot")
                k := "a:1", use["a:2"] := use.Get("a:2", []), use["a:2"].Push(r)
            else
                continue
            if !use.Has(k)
                use[k] := []
            use[k].Push(r)
        }
        out := Map()
        for k, list in use
            if (list.Length > 1)
                for r in list
                    out[r["key"]] := "conflict with " (list[1]["key"] = r["key"] ? list[2]["label"] : list[1]["label"])
        return out
    }

    ; Name of the action that already owns mod+button (other than `id`), or "".
    static WouldClash(id, md, btn) {
        if (md = "rshift" && btn = 1)
            return "Detect operator"
        for d in Hk.LuaDefs {
            if (d[2] = id)
                continue
            e := Hk.Effective(d)
            if (e[1] = md && e[2] = btn)
                return d[3]
        }
        return ""
    }

    static RegisterAll() {
        Hk.Fn := Map("mode", (*) => View.ToggleMode(), "visible", (*) => View.ToggleVisible()
            , "capture", (*) => Calib.Capture(), "profiles", (*) => Profiles.Copy(), "record", (*) => Recorder.Toggle())
        for id, def in Hk.AhkDefaults {
            key := Cfg.Get("hotkeys." id, def)
            try Hotkey(key, Hk.Fn[id], "On")
            catch {
                Diag.Log("hotkey '" key "' rejected, using " def)
                Cfg.Set("hotkeys." id, def)
                try Hotkey(def, Hk.Fn[id], "On")
            }
        }
    }

    ; Returns "" or an error message.
    static SetAhk(id, key) {
        if (key = "")
            return "empty key"
        for other, def in Hk.AhkDefaults
            if (other != id && StrLower(Cfg.Get("hotkeys." other, def)) = StrLower(key))
                return "already used by " Hk.AhkLabels[other]
        if (key = "1" || key = "2")
            return "reserved for the slot sync"
        old := Cfg.Get("hotkeys." id, Hk.AhkDefaults[id])
        try Hotkey(key, Hk.Fn[id], "On")
        catch as e
            return "not a valid hotkey (" e.Message ")"
        if (StrLower(old) != StrLower(key))
            try Hotkey(old, "Off")
        Cfg.Set("hotkeys." id, key)
        return ""
    }
}

; ------------------------------------------------------------------------------
; 18. TUNED PROFILES  (F10: copy recoil profiles tuned in the Lua's tune mode)
; ------------------------------------------------------------------------------
class Profiles {
    static Pastes := Map()
    static WasTuning := false

    static Note(pkt) {
        p := pkt.Get("paste", "-")
        if (p != "-" && RegExMatch(p, '^\["(.+?)"\]', &m))
            Profiles.Pastes[m[1]] := p
        tuning := pkt.Get("tune", "0") = "1"
        if (tuning && !Profiles.WasTuning && (View.Hidden || View.Mode != "hud")) {
            View.Hidden := false                ; tuning started: bring the HUD up so the button hints are visible
            View.Mode := "hud"
            View.Apply()
        }
        if (Profiles.WasTuning && !tuning)
            Profiles.Copy()                     ; tuning just finished
        Profiles.WasTuning := tuning
    }

    static Copy() {
        if (Profiles.Pastes.Count = 0) {
            Toast.Show("warn", "NO TUNED PROFILES", "Tune one in the range first", "", "")
            return
        }
        text := "-- paste these into RECOIL_PROFILES in siege_profile_manager.lua`r`n"
        for w, line in Profiles.Pastes
            text .= line "`r`n"
        A_Clipboard := text
        try {
            f := FileOpen(App.Dir "\SiegeRecoilProfiles.txt", "w", "UTF-8")
            f.Write(text)
            f.Close()
        }
        Toast.Show("ok", "✓ PROFILES COPIED", Profiles.Pastes.Count " tuned profile(s)", "Paste into RECOIL_PROFILES", "")
    }
}

; ------------------------------------------------------------------------------
; 18b. RECOIL COACH  (the system checks its own compensation and improves it)
;   While the macro is pulling, your hand is the error sensor: if you have to pull down extra, the
;   macro is under-compensating at that moment; if you push up, it is over-compensating. Windows Raw
;   Input (the same data mouse software sees) gives this app your real mouse movement. The Lua reports
;   what it injected (burst_end: py / px) and which profile it ran (pull_a / pull_b / pull_c). Per burst
;   the coach measures your residual correction in three phases of the spray, scores the burst, and
;   nudges the profile a fraction of the way toward zero error. Nothing here reads the screen or the game.
;   It only adjusts a profile (never more than 40% away from the first one it saw). The new profile
;   reaches the game with the next COPY LUA SCRIPT.
; ------------------------------------------------------------------------------
class Recorder {
    static On := false
    static Gui := ""
    static Buf := ""
    static Freq := 0
    static Fn := ""
    static TickFn := ""
    static Cur := ""                ; the burst being captured: Map(t0, key, s[samples], macro, recoil, pa, pb, pc, px, t1, t2, gain)
    static Dev := Map()             ; device handle -> movement seen while NOT firing (= your physical mouse)
    static Hdr := 8 + 2 * A_PtrSize          ; sizeof(RAWINPUTHEADER)

    static Init() {
        Recorder.Gui := Gui("+ToolWindow -Caption", "SPM raw input")     ; never shown: only receives WM_INPUT
        Recorder.Buf := Buffer(64, 0)
        DllCall("QueryPerformanceFrequency", "Int64*", &f := 0)
        Recorder.Freq := f
    }

    static Now() {
        DllCall("QueryPerformanceCounter", "Int64*", &c := 0)
        return c * 1000 / Recorder.Freq
    }

    static Toggle() => Recorder.Set(!Recorder.On)

    static Set(on, quiet := false) {
        on := on ? true : false
        if (on = Recorder.On)
            return
        if !IsObject(Recorder.Gui)
            Recorder.Init()
        if !Recorder.Reg(on) {
            Toast.Show("error", "⚠ COACH", "Windows refused the raw-input registration", "", "")
            return
        }
        if !IsObject(Recorder.Fn)
            Recorder.Fn := ObjBindMethod(Recorder, "OnInput")
        if !IsObject(Recorder.TickFn)
            Recorder.TickFn := ObjBindMethod(Coach, "Tick")
        OnMessage(0x00FF, Recorder.Fn, on ? 1 : 0)                ; WM_INPUT
        SetTimer(Recorder.TickFn, on ? 250 : 0)
        Recorder.On := on
        Recorder.Cur := ""
        Cfg.Set("coach.on", on ? 1 : 0)
        Coach.Msg := on ? "Watching your bursts" : "Coach is off"
        if !quiet
            Toast.Show(on ? "ok" : "info", on ? "● COACH ON" : "COACH OFF", on ? "Just play: it learns from every spray" : "", "", "")
        View.Changed()
    }

    ; RegisterRawInputDevices: generic mouse, RIDEV_INPUTSINK so it also works while Siege has focus.
    static Reg(on) {
        b := Buffer(8 + A_PtrSize, 0)
        NumPut("UShort", 1, b, 0)
        NumPut("UShort", 2, b, 2)
        NumPut("UInt", on ? 0x100 : 0x1, b, 4)                ; RIDEV_INPUTSINK / RIDEV_REMOVE
        NumPut("Ptr", on ? Recorder.Gui.Hwnd : 0, b, 8)
        return DllCall("RegisterRawInputDevices", "Ptr", b, "UInt", 1, "UInt", 8 + A_PtrSize, "Int")
    }

    ; WM_INPUT handler: small on purpose, it can run 1000 times a second.
    static OnInput(wParam, lParam, msg, hwnd) {
        size := 64
        n := DllCall("GetRawInputData", "Ptr", lParam, "UInt", 0x10000003, "Ptr", Recorder.Buf, "UInt*", &size, "UInt", Recorder.Hdr, "UInt")
        if (n = 0 || n = 0xFFFFFFFF)
            return
        if (NumGet(Recorder.Buf, 0, "UInt") != 0)             ; RIM_TYPEMOUSE only
            return
        h := Recorder.Hdr
        if (NumGet(Recorder.Buf, h, "UShort") & 1)            ; absolute pointer device: ignore
            return
        hd := NumGet(Recorder.Buf, 8, "Ptr")                  ; RAWINPUTHEADER.hDevice
        bf := NumGet(Recorder.Buf, h + 4, "UShort")           ; RAWMOUSE.usButtonFlags
        dx := NumGet(Recorder.Buf, h + 12, "Int")
        dy := NumGet(Recorder.Buf, h + 16, "Int")
        now := Recorder.Now()
        if (bf & 1)                                           ; RI_MOUSE_LEFT_BUTTON_DOWN
            Recorder.Down(now)
        if (dx || dy) {
            if IsObject(Recorder.Cur)
                Recorder.Cur["s"].Push([now - Recorder.Cur["t0"], dx, dy, hd])
            else if !Live.Burst["active"]
                Recorder.Dev[hd] := Recorder.Dev.Get(hd, 0) + Abs(dx) + Abs(dy)
        }
        if (bf & 2)                                           ; RI_MOUSE_LEFT_BUTTON_UP
            Recorder.Up(now)
    }

    ; "WEAPON:BARREL:GRIP" of the active slot, exactly like the Lua's RecoilKey.
    static Key() {
        w := Live.Get("weapon", "-")
        if (w = "-" || w = "NONE")
            return ""
        b := Live.Get("barrel", "-"), g := Live.Get("grip", "-")
        return w ":" (b = "-" ? "nil" : b) ":" (g = "-" ? "nil" : g)
    }

    static Down(now) {
        if (!Recorder.On || IsObject(Recorder.Cur) || !Live.Fresh())
            return
        if !(SlotSync.Anywhere || SlotSync.SiegeActive())
            return                                            ; only while Siege is the active window
        key := Recorder.Key()
        if (key = "")
            return
        ; snapshot of the profile the Lua is about to run (from its last state packet)
        Recorder.Cur := Map("t0", now, "key", key, "s", [], "macro", Live.Burst["active"] ? 1 : 0, "recoil", 0
            , "pa", Live.Get("pull_a", "-"), "pb", Live.Get("pull_b", "-"), "pc", Live.Get("pull_c", "-")
            , "px", Live.Get("pull_x", "-"), "t1", Live.Get("pull_t1", "-"), "t2", Live.Get("pull_t2", "-")
            , "pk", Live.Get("pull_key", "-"), "gain", Live.Get("recoil_gain", "1"))
    }

    static Up(now) {
        if !IsObject(Recorder.Cur)
            return
        b := Recorder.Cur
        Recorder.Cur := ""
        b["dur"] := now - b["t0"]
        Coach.OnRaw(b)
    }
}

class Coach {
    static Raw := ""                ; finished capture of the last burst, waiting for the Lua's totals
    static End := ""                ; the Lua's burst_end totals
    static TestOn := false
    static Msg := "Coach is off"
    static Result := ""             ; the last analysed burst
    static Seen := 0
    static Skipped := 0
    static Eta := 0.5               ; fraction of the measured error corrected per proposal
    static RefDpi := 800
    static RefH := 11
    static RefV := 11

    static Mode() => Cfg.Get("coach.mode", "")

    ; ---- pairing the raw capture with the Lua's report of the same burst ---------------------
    static OnRaw(b) {
        if (!b["macro"] || !b["recoil"]) {
            Coach.Skip("that burst had no macro pull (ADS + fire with the system ON)")
            return
        }
        b["got"] := A_TickCount
        Coach.Raw := b
        Coach.TryPair()
    }

    static OnLuaStart() {
        Coach.End := ""
    }

    static OnLuaEnd(e) {
        Coach.End := Map("py", Float(e.Get("py", 0)), "px", Float(e.Get("px", 0)), "ms", Float(e.Get("ms", 0))
            , "ticks", Integer(e.Get("ticks", 0)), "t", A_TickCount)
        Coach.TryPair()
    }

    static TryPair() {
        if (IsObject(Coach.Raw) && IsObject(Coach.End))
            Coach.Analyze()
    }

    ; 250 ms timer: drop half-finished pairs
    static Tick() {
        if (IsObject(Coach.Raw) && A_TickCount - Coach.Raw["got"] > 2500)
            Coach.Raw := ""
        if (IsObject(Coach.End) && A_TickCount - Coach.End["t"] > 2500)
            Coach.End := ""
    }

    static Skip(msg) {
        ScreenCoach.Last := "skipped: " msg
        Coach.Seen++                    ; a skipped burst is still a burst seen (scored = seen - skipped)
        Coach.Skipped++
        Coach.Msg := "skipped: " msg
        View.Changed()
    }

    ; ---- the analysis ------------------------------------------------------------------------
    static PhysSet() {
        m := Map()
        for hd, n in Recorder.Dev
            if (n >= 300)
                m[hd] := 1
        return m
    }

    static Analyze() {
        raw := Coach.Raw, fin := Coach.End
        Coach.Raw := "", Coach.End := ""
        if (fin["py"] <= 0 || fin["ticks"] < 25) {
            Coach.Skip("the macro did not pull (aim down sights, hold fire 0.3 s or more)")
            return
        }
        nb := Min(80, Floor(raw["dur"] / 100))
        if (nb < 3) {
            Coach.Skip("burst too short (" Round(raw["dur"]) " ms)")
            return
        }
        if !(IsNumber(raw["pa"]) && IsNumber(raw["pb"]) && IsNumber(raw["pc"])) {
            Coach.Skip("the Lua did not report a profile for this weapon")
            return
        }
        phys := Coach.PhysSet()
        ya := [], yp := [], xa := [], xp := []
        loop nb
            ya.Push(0), yp.Push(0), xa.Push(0), xp.Push(0)
        for smp in raw["s"] {
            i := Floor(smp[1] / 100) + 1
            if (i > nb)
                continue
            ya[i] += smp[3], xa[i] += smp[2]
            if phys.Has(smp[4])
                yp[i] += smp[3], xp[i] += smp[2]
        }
        if Coach.TestOn {
            Coach.Classify(ya, yp, fin["py"], phys.Count)
            return
        }
        mode := Coach.Mode()
        if (mode = "") {
            Coach.Skip("run the HANDS-OFF TEST once so the coach knows how your mouse is seen")
            return
        }
        Coach.Score(raw, fin, nb, mode, ya, yp, xa, xp)
    }

    ; One-time test (hands off the mouse while the macro pulls): how does the macro's own movement
    ; look to Raw Input? This decides how the user's correction is separated from it.
    static Classify(ya, yp, py, physCount) {
        Coach.TestOn := false
        if (physCount = 0) {
            Coach.Msg := "TEST FAILED: wiggle the mouse first so it can be recognised, then try again"
            View.Changed()
            return
        }
        totalAll := 0, totalP := 0
        for v in ya
            totalAll += v
        for v in yp
            totalP += v
        foreign := totalAll - totalP
        mode := ""
        if (Abs(foreign) >= 0.5 * py)
            mode := "phys"
        else if (Abs(totalP) >= 0.5 * py && Abs(totalP) <= 1.8 * py)
            mode := "subtract"
        else if (Abs(totalAll) < 0.25 * py)
            mode := "direct"
        if (mode = "") {
            Coach.Msg := "TEST UNCLEAR (did the mouse move?). Hands completely off, try again."
        } else {
            Cfg.Set("coach.mode", mode)
            Coach.Msg := "TEST OK: " (mode = "phys" ? "the macro shows up as a separate device" : mode = "subtract"
                ? "the macro shares your mouse's channel (its pull is subtracted)" : "the macro is invisible to Raw Input")
            Toast.Show("ok", "✓ COACH READY", "Mouse test passed", "It now learns from every spray", "")
        }
        View.Changed()
    }

    ; Per-phase residual (reference units per 7 ms tick): + means you had to pull DOWN extra (macro too weak).
    static Score(raw, fin, nb, mode, ya, yp, xa, xp) {
        g := Cfg.Data["game"]
        gain := IsNumber(raw["gain"]) ? raw["gain"] + 0 : 1
        sy := gain * (Coach.RefDpi * Coach.RefV) / (g["dpi"] * g["sensV"])
        sx := gain * (Coach.RefDpi * Coach.RefH) / (g["dpi"] * g["sensH"])
        pa := raw["pa"] + 0, pb := raw["pb"] + 0, pc := raw["pc"] + 0, pxs := IsNumber(raw["px"]) ? raw["px"] + 0 : 0
        t1 := IsNumber(raw["t1"]) ? raw["t1"] + 0 : 500
        t2 := IsNumber(raw["t2"]) ? raw["t2"] + 0 : 900
        ; expected pull weight per bucket (for the "subtract" mode)
        sumW := 0
        w := []
        loop nb {
            tc := (A_Index - 0.5) * 100
            v := tc < t1 ? pa : tc < t2 ? pb : pc
            w.Push(v), sumW += v
        }
        sA := 0, sB := 0, sC := 0, nA := 0, nB := 0, nC := 0, sX := 0, nX := 0
        moved := 0                                            ; how much you actually corrected by hand (counts)
        loop nb {
            i := A_Index
            if (i = 1)
                continue                                      ; 0-100 ms is reaction time
            if (mode = "phys")
                yr := yp[i], xr := xp[i]
            else if (mode = "direct")
                yr := ya[i], xr := xa[i]
            else {                                            ; subtract: remove what the macro itself injected
                yr := yp[i] - (sumW > 0 ? fin["py"] * w[i] / sumW : 0)
                xr := xp[i] - fin["px"] / nb
            }
            moved += Abs(yr) + Abs(xr)
            ry := yr * 0.07 / sy
            rx := xr * 0.07 / sx
            tc := (i - 0.5) * 100
            if (tc < t1)
                sA += ry, nA++
            else if (tc < t2)
                sB += ry, nB++
            else
                sC += ry, nC++
            sX += rx, nX++
        }
        if (moved < 60) {
            ; The score only sees YOUR corrections. No correction means "unknown", not "perfect": the old code scored it 100%.
            Coach.Skip("no corrections from you in that spray, so there is nothing to score (this app cannot see where the bullets land)")
            return
        }
        mA := nA ? sA / nA : 0, mB := nB ? sB / nB : 0, mC := nC ? sC / nC : 0, mX := nX ? sX / nX : 0
        n := nA + nB + nC
        err := (Abs(mA) * nA + Abs(mB) * nB + Abs(mC) * nC) / Max(n, 1)
        meanPull := (pa * nA + pb * nB + pc * nC) / Max(n, 1)
        acc := 100 * (1 - Min(1, err / Max(meanPull, 0.5) * 2))
        Coach.Result := Map("key", raw["key"], "acc", acc, "mA", mA, "mB", mB, "mC", mC, "mX", mX, "pa", pa, "pb", pb, "pc", pc
            , "nA", nA, "nB", nB, "nC", nC, "dur", raw["dur"], "py", fin["py"], "t", A_Now)
        Coach.Seen++
        Coach.Record(raw["key"], pa, pb, pc, pxs, t1, t2, mA, mB, mC, mX, acc)
        Coach.Msg := "burst scored: " Round(acc) "% accurate"
        View.Changed()
    }

    ; ---- storage + proposal --------------------------------------------------------------------
    static Entry(key) {
        H := Cfg.Data["coach"]["hist"]
        if (!H.Has(key) || Type(H[key]) != "Map")
            H[key] := Map()
        e := H[key]
        for k, v in Map("sig", "", "n", 0, "A", 0, "B", 0, "C", 0, "X", 0, "pa", 0, "pb", 0, "pc", 0, "px", 0, "t1", 500, "t2", 900, "t", "")
            if !e.Has(k)
                e[k] := v
        if (!e.Has("acc") || Type(e["acc"]) != "Array")
            e["acc"] := []
        return e
    }

    static Record(key, pa, pb, pc, px, t1, t2, mA, mB, mC, mX, acc) {
        e := Coach.Entry(key)
        sig := key "|" Round(pa, 2) "|" Round(pb, 2) "|" Round(pc, 2) "|" Round(px, 2)
        if (e["sig"] != sig) {                                ; the game loaded a new profile: start a fresh round
            e["sig"] := sig, e["n"] := 0, e["A"] := 0, e["B"] := 0, e["C"] := 0, e["X"] := 0
            e["pa"] := pa, e["pb"] := pb, e["pc"] := pc, e["px"] := px, e["t1"] := t1, e["t2"] := t2
        }
        if !e.Has("base") || !IsObject(e["base"])
            e["base"] := Map("a", pa, "b", pb, "c", pc, "x", px)     ; the first profile ever seen bounds all later changes
        e["n"] += 1
        e["A"] += mA, e["B"] += mB, e["C"] += mC, e["X"] += mX
        e["t"] := A_Now
        e["acc"].Push(Round(acc))
        while (e["acc"].Length > 60)
            e["acc"].RemoveAt(1)
        Cfg.Dirty()
        if (e["n"] >= 3)
            Coach.Propose(key)
    }

    static Bound(v, base) {
        lo := base > 0.3 ? base * 0.6 : 0
        hi := base > 0.3 ? base * 1.5 : 6
        return Clamp(v, lo, hi)
    }

    ; New profile = the running one + Eta * the average error of the bursts run on it. Returns the Map or "".
    static Propose(key) {
        e := Coach.Entry(key)
        n := e["n"]
        if (n < 3 || !IsObject(e["base"]))
            return ""
        ; LOCKED: when the average error of this round is under 4% of every phase's pull (and the sideways drift is
        ; tiny) the profile is accurate: stop changing it instead of chasing noise.
        rel := Max(Abs(e["A"] / n) / Max(e["pa"], 0.5), Abs(e["B"] / n) / Max(e["pb"], 0.5), Abs(e["C"] / n) / Max(e["pc"], 0.5))
        if (rel < 0.04 && Abs(e["X"] / n) < 0.1) {
            Coach.Msg := "profile LOCKED for " key ": the last " n " sprays were within " Round(rel * 100, 1) "% - nothing to change"
            return ""
        }
        b := e["base"]
        a2 := Coach.Bound(e["pa"] + Coach.Eta * e["A"] / n, b["a"])
        b2 := Coach.Bound(e["pb"] + Coach.Eta * e["B"] / n, b["b"])
        c2 := Coach.Bound(e["pc"] + Coach.Eta * e["C"] / n, b["c"])
        x2 := Clamp(e["px"] + Coach.Eta * e["X"] / n, b["x"] - 4, b["x"] + 4)
        prof := Map("r", Round(a2, 3), "y1", Round(b2 - a2, 3), "y2", Round(c2 - b2, 3), "tym1", e["t1"], "tym2", e["t2"]
            , "side", Round(x2, 3), "strength", 1, "late", 1, "n", n, "t", A_Now)
        old := Cfg.Data["learned"].Has(key) ? Cfg.Data["learned"][key] : ""
        changed := !IsObject(old) || Abs(old["r"] - prof["r"]) > 0.03 || Abs(old["y1"] - prof["y1"]) > 0.03 || Abs(old["y2"] - prof["y2"]) > 0.03
        if changed {
            Cfg.Data["learned"][key] := prof
            Cfg.Dirty()
            Toast.Show("ok", "✓ COACH IMPROVED YOUR PROFILE", key, "From " n " bursts", "Copy the Lua script to use it")
        }
        return prof
    }

    static ForgetKey(key) {
        Cfg.Data["coach"]["hist"].Delete(key)
        Cfg.Data["learned"].Delete(key)
        Cfg.Dirty()
    }

    ; accuracy history (last N) of a loadout
    static History(key, n := 30) {
        H := Cfg.Data["coach"]["hist"]
        out := []
        if (!H.Has(key) || Type(H[key]) != "Map" || !H[key].Has("acc"))
            return out
        a := H[key]["acc"]
        start := Max(1, a.Length - n + 1)
        loop a.Length - start + 1
            out.Push(a[start + A_Index - 1])
        return out
    }

    ; plain-language verdict for one phase: r = residual, pull = what the macro is pulling then
    static Say(res, pull) {
        rel := res / Max(pull, 0.5)
        if (Abs(rel) < 0.05)
            return "on target"
        return (rel > 0 ? "pulls TOO LITTLE by " : "pulls TOO MUCH by ") Round(Abs(rel) * 100) "%"
    }

    static Avg(arr, a, b) {
        sum := 0, n := 0
        loop b - a + 1 {
            i := a + A_Index - 1
            if (i >= 1 && i <= arr.Length)
                sum += arr[i], n++
        }
        return n ? sum / n : 0
    }

    static StartTest() {
        if !Recorder.On
            Recorder.Set(true, true)
        Coach.TestOn := true
        Coach.Msg := "TEST: 1) wiggle the mouse  2) let go completely  3) system ON, aim down sights and hold fire 2 s"
        Toast.Show("info", "HANDS-OFF TEST", "Wiggle the mouse, then let go", "ADS + hold fire for 2 seconds", "Do not touch the mouse")
        View.Changed()
    }
}

; ------------------------------------------------------------------------------
; 18b. SCREEN COACH  (measures where the view really ends up, phase by phase, no corrections from you needed)
;     While a burst runs it takes a picture of the top-left of the screen every 250 ms and measures how far the
;     picture moved between neighbouring pictures (row / column brightness profiles, cross-correlated). The camera
;     moves by recoil minus the macro's pull, so each movement is the error of that part of the spray: EARLY, MID and
;     LATE are measured separately and tuned separately. Vertical and sideways are judged independently, an unclear
;     interval is skipped (never guessed), and once a profile is accurate the coach stops changing it (LOCKED).
;     F11 (hold ADS, TRAINING on) measures how many screen pixels one mouse count moves the view; until then 0.4
;     px/count is assumed. Training only (F12): in a match the picture changes for other reasons.
; ------------------------------------------------------------------------------
class ScreenCoach {
    static Frames := []
    static TickFn := ""
    static Busy := false
    static RX := 0
    static RY := 0
    static Stp := 6                         ; pixel stride of the analysis: keeps it short (the Lua waits for this script)

    ; Training only: the screen check is wrong in a match (you move, enemies appear, doors open) and the analysis can briefly
    ; hitch the Lua. It never runs unless you switch TRAINING on (F12) - and it switches itself off after 20 minutes.
    static Training := false
    static TrainUntil := 0
    static ToggleTraining() {
        ScreenCoach.Training := !ScreenCoach.Training
        ScreenCoach.TrainUntil := ScreenCoach.Training ? A_TickCount + 1200000 : 0
        Toast.Show(ScreenCoach.Training ? "ok" : "info", ScreenCoach.Training ? "● TRAINING ON" : "TRAINING OFF"
            , ScreenCoach.Training ? "Screen coach is measuring your sprays" : "No screenshots are taken"
            , ScreenCoach.Training ? "Use it in the range only. Off again in 20 min" : "", "")
        View.Changed()
    }
    static Last := "no spray measured yet"
    ; Why the screen coach is not measuring right now ("" = it is).
    static Why() {
        if (ScreenCoach.Training && A_TickCount > ScreenCoach.TrainUntil)
            ScreenCoach.Training := false
        if !Recorder.On
            return "the coach is OFF (press F6)"
        if !ScreenCoach.Training
            return "TRAINING is OFF (press F12 in the range)"
        if !Live.Fresh()
            return "no live data from G HUB"
        if !(SlotSync.Anywhere || SlotSync.SiegeActive())
            return "Siege is not the active window"
        return ""
    }
    static Active() => ScreenCoach.Why() = ""


    ; Area compared: left 60% x top 50% of the screen (the gun, ammo counter and compass are outside it).
    static Region() {
        w := A_ScreenWidth, h := A_ScreenHeight
        ScreenCoach.RX := Round(w * 0.05), ScreenCoach.RY := Round(h * 0.05)
        return [ScreenCoach.RX, ScreenCoach.RY, Round(w * 0.60), Round(h * 0.50)]
    }

    static Grab(x, y, w, h) {
        hdc := DllCall("GetDC", "Ptr", 0, "Ptr")
        mdc := DllCall("CreateCompatibleDC", "Ptr", hdc, "Ptr")
        bmp := DllCall("CreateCompatibleBitmap", "Ptr", hdc, "Int", w, "Int", h, "Ptr")
        old := DllCall("SelectObject", "Ptr", mdc, "Ptr", bmp, "Ptr")
        DllCall("BitBlt", "Ptr", mdc, "Int", 0, "Int", 0, "Int", w, "Int", h, "Ptr", hdc, "Int", x, "Int", y, "UInt", 0x40CC0020)
        bi := Buffer(40, 0)
        NumPut("UInt", 40, bi, 0), NumPut("Int", w, bi, 4), NumPut("Int", -h, bi, 8), NumPut("UShort", 1, bi, 12), NumPut("UShort", 32, bi, 14)
        buf := Buffer(w * h * 4, 0)
        DllCall("GetDIBits", "Ptr", mdc, "Ptr", bmp, "UInt", 0, "UInt", h, "Ptr", buf, "Ptr", bi, "UInt", 0)
        DllCall("SelectObject", "Ptr", mdc, "Ptr", old)
        DllCall("DeleteObject", "Ptr", bmp)
        DllCall("DeleteDC", "Ptr", mdc)
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
        return buf
    }

    ; Mean brightness per column and per row (every Stp-th pixel), without a box around the crosshair.
    static Profiles(buf, w, h) {
        stp := ScreenCoach.Stp
        nx := w // stp, ny := h // stp
        sx := [], sy := [], cx := [], cy := []
        loop nx
            sx.Push(0), cx.Push(0)
        loop ny
            sy.Push(0), cy.Push(0)
        mx := A_ScreenWidth // 2 - ScreenCoach.RX
        my := A_ScreenHeight // 2 - ScreenCoach.RY
        iy := 1
        while (iy <= ny) {
            y := (iy - 1) * stp
            row := y * w * 4 + 1                          ; +1 = the green byte
            ix := 1
            while (ix <= nx) {
                x := (ix - 1) * stp
                if (Abs(x - mx) > 70 || Abs(y - my) > 70) {
                    L := NumGet(buf, row + x * 4, "UChar")
                    sx[ix] += L, cx[ix] += 1
                    sy[iy] += L, cy[iy] += 1
                }
                ix += 1
            }
            iy += 1
        }
        loop nx
            sx[A_Index] := cx[A_Index] ? sx[A_Index] / cx[A_Index] : 0
        loop ny
            sy[A_Index] := cy[A_Index] ? sy[A_Index] / cy[A_Index] : 0
        return Map("x", sx, "y", sy)
    }

    ; First difference (kills lighting gradients), normalised to zero mean / unit spread. "" = blank picture.
    static Prep(arr) {
        n := arr.Length - 1
        if (n < 30)
            return ""
        dif := []
        i := 1
        while (i <= n) {
            dif.Push(arr[i + 1] - arr[i])
            i += 1
        }
        m := 0
        for v in dif
            m += v
        m /= dif.Length
        ss := 0
        for v in dif
            ss += (v - m) ** 2
        sd := Sqrt(ss / dif.Length)
        if (sd < 0.02)
            return ""
        out := []
        for v in dif
            out.Push((v - m) / sd)
        return out
    }

    ; d (in samples) such that b[i + d] ~ a[i]; c = its correlation, sec = the best other peak.
    static Shift(a, b, maxd) {
        n := Min(a.Length, b.Length)
        best := -2, bd := 0
        cs := []
        d := -maxd
        while (d <= maxd) {
            s := 0, cnt := 0
            i := Max(1, 1 - d)
            i1 := Min(n, n - d)
            while (i <= i1) {
                s += a[i] * b[i + d]
                cnt += 1
                i += 1
            }
            c := cnt > n / 2 ? s / cnt : -1
            cs.Push(c)
            if (c > best)
                best := c, bd := d
            d += 1
        }
        sec := -2
        for k, c in cs {
            dd := k - maxd - 1
            if (Abs(dd - bd) > 3 && c > sec)
                sec := c
        }
        return Map("d", bd, "c", best, "sec", sec)
    }

    static Clear(sh) => (sh["c"] >= 0.4 && sh["c"] - sh["sec"] >= 0.03)

    ; Prepared profiles of one picture, or "" when it is blank.
    static Prof(buf, w, h) {
        p := ScreenCoach.Profiles(buf, w, h)
        px := ScreenCoach.Prep(p["x"]), py := ScreenCoach.Prep(p["y"])
        return (IsObject(px) && IsObject(py)) ? Map("x", px, "y", py) : ""
    }

    ; Movement of picture B relative to picture A in pixels: Map(dx, dy) where an unclear axis is "" (and cx / cy hold the
    ; match scores). Returns "" with the reason in why when neither axis is usable.
    static Measure(pa, pb, &why) {
        why := ""
        if (!IsObject(pa) || !IsObject(pb)) {
            why := "a picture looks blank to the screen coach (is the game in borderless / windowed mode? exclusive fullscreen captures black)"
            return ""
        }
        sy := ScreenCoach.Shift(pa["y"], pb["y"], Min(60, pa["y"].Length // 2 - 10))
        sx := ScreenCoach.Shift(pa["x"], pb["x"], Min(60, pa["x"].Length // 2 - 10))
        st := ScreenCoach.Stp
        m := Map("dx", ScreenCoach.Clear(sx) ? sx["d"] * st : "", "dy", ScreenCoach.Clear(sy) ? sy["d"] * st : ""
            , "cx", sx["c"], "cy", sy["c"])
        if (m["dx"] = "" && m["dy"] = "") {
            why := Format("the picture match was unclear (vertical {:.2f} vs {:.2f}, horizontal {:.2f} vs {:.2f}; needs 0.40 and a clear gap)"
                , sy["c"], sy["sec"], sx["c"], sx["sec"])
            return ""
        }
        return m
    }

    ; ---- during a burst --------------------------------------------------------------------------
    static OnStart() {
        ScreenCoach.Frames := []
        if (IsObject(ScreenCoach.TickFn))
            SetTimer(ScreenCoach.TickFn, 0)
        why := ScreenCoach.Why()
        if (why != "") {
            ScreenCoach.Last := "idle: " why
            if Recorder.On {
                Coach.Msg := "screen coach idle: " why
                View.Changed()
            }
            return
        }
        if ScreenCoach.Busy
            return
        ScreenCoach.Snap()
        if !IsObject(ScreenCoach.TickFn)
            ScreenCoach.TickFn := ObjBindMethod(ScreenCoach, "Snap")
        SetTimer(ScreenCoach.TickFn, 250)
    }

    static Snap() {
        if (ScreenCoach.Frames.Length >= 14) {
            if IsObject(ScreenCoach.TickFn)
                SetTimer(ScreenCoach.TickFn, 0)
            return
        }
        r := ScreenCoach.Region()
        try ScreenCoach.Frames.Push([A_TickCount, ScreenCoach.Grab(r[1], r[2], r[3], r[4])])
    }

    static OnEnd(e) {
        if IsObject(ScreenCoach.TickFn)
            SetTimer(ScreenCoach.TickFn, 0)
        fr := ScreenCoach.Frames
        ScreenCoach.Frames := []
        if (fr.Length = 0 || ScreenCoach.Busy)
            return
        py := Float(e.Get("py", 0)), ticks := Integer(e.Get("ticks", 0)), ms := Float(e.Get("ms", 0))
        if (py <= 0 || ticks < 40) {
            Coach.Skip("screen check: hold fire a bit longer (the macro must pull for 0.5 s or more)")
            return
        }
        ScreenCoach.Busy := true
        try {
            r := ScreenCoach.Region()
            fr.Push([A_TickCount, ScreenCoach.Grab(r[1], r[2], r[3], r[4])])
            ScreenCoach.Analyze(fr, r[3], r[4], py, ticks, ms)
        } catch as err {
            Diag.Log("screen coach: " err.Message)
            Coach.Skip("screen check failed: " err.Message)
        } finally
            ScreenCoach.Busy := false
    }

    static Analyze(fr, w, h, py, ticks, ms) {
        n := fr.Length
        if (n < 3) {
            Coach.Skip("screen check: the spray was too short to sample (hold fire for 0.7 s or more)")
            return
        }
        key := Recorder.Key()
        pa := Live.Get("pull_a", "-"), pb := Live.Get("pull_b", "-"), pc := Live.Get("pull_c", "-"), pxs := Live.Get("pull_x", "-")
        if (key = "" || !IsNumber(pa) || !IsNumber(pb) || !IsNumber(pc)) {
            Coach.Skip("screen check: the Lua did not report a profile for this weapon")
            return
        }
        pa += 0, pb += 0, pc += 0, pxs := IsNumber(pxs) ? pxs + 0 : 0
        t1 := IsNumber(Live.Get("pull_t1", "-")) ? Live.Get("pull_t1", "-") + 0 : 500
        t2 := IsNumber(Live.Get("pull_t2", "-")) ? Live.Get("pull_t2", "-") + 0 : 900
        g := Cfg.Data["game"]
        gain := IsNumber(Live.Get("recoil_gain", "1")) ? Live.Get("recoil_gain", "1") + 0 : 1
        sy := gain * (Coach.RefDpi * Coach.RefV) / (g["dpi"] * g["sensV"])
        sxs := gain * (Coach.RefDpi * Coach.RefH) / (g["dpi"] * g["sensH"])
        cyv := Cfg.Num("coach.pxy", 0.4), cxv := Cfg.Num("coach.pxx", 0.4)
        prof := []
        for f in fr
            prof.Push(ScreenCoach.Prof(f[2], w, h))
        tpm := ticks / Max(ms, 1)                       ; macro ticks per millisecond
        t0 := fr[1][1]
        sumY := [0, 0, 0], tkY := [0, 0, 0], sumX := 0, tkX := 0, used := 0
        i := 1
        while (i < n) {
            m := ScreenCoach.Measure(prof[i], prof[i + 1], &why)
            if IsObject(m) {
                dt := fr[i + 1][1] - fr[i][1]
                mid := (fr[i][1] + fr[i + 1][1]) / 2 - t0
                ph := mid < t1 ? 1 : mid < t2 ? 2 : 3
                tk := dt * tpm
                if (m["dy"] != "")
                    sumY[ph] += m["dy"], tkY[ph] += tk, used += 1
                if (m["dx"] != "")
                    sumX += -m["dx"], tkX += tk                 ; picture moved LEFT = the view drifted RIGHT
            }
            i += 1
        }
        if (used < 2) {
            Coach.Skip("screen check: too few clear pictures in that spray (" used " of " (n - 1) ")" (IsSet(why) && why != "" ? ", last: " why : ""))
            return
        }
        pulls := [pa, pb, pc]
        res := [0, 0, 0]
        loop 3 {
            ph := A_Index
            if (tkY[ph] > 0) {
                mp := Max(pulls[ph], 0.5)
                ; picture moved DOWN = the view ended ABOVE where it started = the macro pulled too little in this phase
                res[ph] := Clamp((sumY[ph] / cyv) / tkY[ph] / sy, -0.5 * mp, 0.5 * mp)
            }
        }
        mX := tkX > 0 ? Clamp(-(sumX / cxv) / tkX / sxs, -3, 3) : 0
        wacc := 0, wsum := 0
        loop 3 {
            if (tkY[A_Index] > 0) {
                wacc += Abs(res[A_Index]) / Max(pulls[A_Index], 0.5) * tkY[A_Index], wsum += tkY[A_Index]
            }
        }
        acc := wsum ? 100 * (1 - Min(1, wacc / wsum * 2)) : 0
        Coach.Result := Map("key", key, "acc", acc, "mA", res[1], "mB", res[2], "mC", res[3], "mX", mX
            , "pa", pa, "pb", pb, "pc", pc, "nA", 1, "nB", 1, "nC", 1, "dur", ms, "py", py, "t", A_Now)
        Coach.Seen++
        Coach.Record(key, pa, pb, pc, pxs, t1, t2, res[1], res[2], res[3], mX, acc)
        ScreenCoach.Last := "measured: EARLY " Coach.Say(res[1], pa) ", MID " Coach.Say(res[2], pb) ", LATE " Coach.Say(res[3], pc) " (" used " clear intervals of " (n - 1) ")"
        Coach.Msg := "screen coach: EARLY " Coach.Say(res[1], pa) "  ·  MID " Coach.Say(res[2], pb) "  ·  LATE " Coach.Say(res[3], pc)
            . "  ·  sideways " (Abs(mX) < 0.08 ? "ok" : "drifts " (mX < 0 ? "RIGHT" : "LEFT"))
            . (Cfg.Get("coach.pxy", "") = "" ? "   (press F11 holding ADS to calibrate px per count)" : "")
        View.Changed()
    }

    ; Relative mouse movement in small steps with mouse_event (MOUSEEVENTF_MOVE only). AHK's MouseMove sends an absolute
    ; position, which a game reading raw input can take as a huge movement. 12 steps of total/12 counts.
    static Nudge(dx, dy) {
        loop 12 {
            DllCall("mouse_event", "UInt", 0x0001, "Int", dx // 12, "Int", dy // 12, "UInt", 0, "UPtr", 0)
            Sleep(8)
        }
    }

    ; F11 while holding the aim button: moves the mouse 300 counts down, then 300 right, and measures how many screen
    ; pixels the view moved each time. Do it with the sight you normally use (zoom changes the number).
    static CalibratePx() {
        if !ScreenCoach.Training {
            Toast.Show("warn", "CALIBRATE PX", "Switch TRAINING on first (F12)", "Range only: it moves your view", "")
            return
        }
        if !(SlotSync.Anywhere || SlotSync.SiegeActive()) {
            Toast.Show("warn", "CALIBRATE PX", "Siege must be the active window", "", "")
            return
        }
        if !GetKeyState("RButton", "P") {
            Toast.Show("warn", "CALIBRATE PX", "Hold RIGHT mouse (aim down sights)", "then press F11 again", "")
            return
        }
        if ScreenCoach.Busy
            return
        ScreenCoach.Busy := true
        try {
            r := ScreenCoach.Region()
            res := Map()
            for axis in ["y", "x"] {
                pA := ScreenCoach.Prof(ScreenCoach.Grab(r[1], r[2], r[3], r[4]), r[3], r[4])
                ScreenCoach.Nudge(axis = "x" ? 300 : 0, axis = "y" ? 300 : 0)
                Sleep(200)
                pB := ScreenCoach.Prof(ScreenCoach.Grab(r[1], r[2], r[3], r[4]), r[3], r[4])
                ScreenCoach.Nudge(axis = "x" ? -300 : 0, axis = "y" ? -300 : 0)       ; straight back to where you were
                Sleep(150)
                m := ScreenCoach.Measure(pA, pB, &why)
                v := IsObject(m) ? m[axis = "y" ? "dy" : "dx"] : ""
                if (v = "") {
                    Toast.Show("warn", "CALIBRATE PX", "Failed: " (why != "" ? why : "that axis was unclear"), "Aim at a textured wall or the target and try again", "")
                    return
                }
                res[axis] := Abs(v) / 300
            }
            if (res["y"] < 0.02 || res["x"] < 0.02) {
                Toast.Show("warn", "CALIBRATE PX", "The view did not move (is the cursor free in a menu?)", "", "")
                return
            }
            Cfg.Data["coach"]["pxy"] := Round(res["y"], 3)
            Cfg.Data["coach"]["pxx"] := Round(res["x"], 3)
            Cfg.Dirty()
            Toast.Show("ok", "✓ PX PER COUNT", "vertical " Round(res["y"], 3) "   horizontal " Round(res["x"], 3), "The coach now converts errors to pull changes", "")
        } catch as err {
            Toast.Show("warn", "CALIBRATE PX", "Failed: " err.Message, "", "")
        } finally
            ScreenCoach.Busy := false
    }
}

; ------------------------------------------------------------------------------
; 18c. SIGHT TRACE  (follows the pink sight on screen during a spray; light enough to leave on in a match)
;     Every 50 ms while a burst is running it scans the middle of the screen for pink pixels and records
;     where their centre is. At the end it reports how far that centre moved. It only reports: nothing is
;     learned from it yet (we first need to see what the number looks like for a good and a bad spray).
;     Runs while the coach (F6) is on.
; ------------------------------------------------------------------------------
class SightTrace {
    static Samples := []
    static Fn := ""
    static T0 := 0
    static Busy := false

    static Region() {
        w := A_ScreenWidth, h := A_ScreenHeight
        return [Round(w * 0.25), Round(h * 0.25), Round(w * 0.50), Round(h * 0.50)]
    }

    ; Pink = strong red and blue, clearly more red than green (works for hot pink and soft pink).
    static IsPink(r, g, b) => (r > 150 && b > 100 && r - g > 45 && b - g > 5)

    static Sample() {
        if SightTrace.Busy
            return
        SightTrace.Busy := true
        try {
            rg := SightTrace.Region()
            buf := ScreenCoach.Grab(rg[1], rg[2], rg[3], rg[4])
            w := rg[3], h := rg[4]
            n := 0, sx := 0, sy := 0
            y := 0
            while (y < h) {
                row := y * w * 4
                x := 0
                while (x < w) {
                    o := row + x * 4
                    if SightTrace.IsPink(NumGet(buf, o + 2, "UChar"), NumGet(buf, o + 1, "UChar"), NumGet(buf, o, "UChar"))
                        n += 1, sx += x, sy += y
                    x += 4
                }
                y += 4
            }
            if (n >= 20)
                SightTrace.Samples.Push([A_TickCount - SightTrace.T0, sx / n + rg[1], sy / n + rg[2], n])
        } finally
            SightTrace.Busy := false
    }

    static OnStart() {
        SightTrace.Samples := []
        if (!Recorder.On || !Live.Fresh() || !(SlotSync.Anywhere || SlotSync.SiegeActive()))
            return
        SightTrace.T0 := A_TickCount
        if !IsObject(SightTrace.Fn)
            SightTrace.Fn := ObjBindMethod(SightTrace, "Sample")
        SetTimer(SightTrace.Fn, 50)
    }

    static OnEnd(e) {
        if IsObject(SightTrace.Fn)
            SetTimer(SightTrace.Fn, 0)
        sm := SightTrace.Samples
        if (sm.Length < 6) {
            if (Recorder.On && Live.Fresh())
                Diag.Log("sight trace: no pink sight found (" sm.Length " samples)")
            return
        }
        k := Min(3, sm.Length // 2)
        x0 := 0, y0 := 0, x1 := 0, y1 := 0, ymax := -1e9, ymin := 1e9
        loop k {
            x0 += sm[A_Index][2] / k, y0 += sm[A_Index][3] / k
            x1 += sm[sm.Length - A_Index + 1][2] / k, y1 += sm[sm.Length - A_Index + 1][3] / k
        }
        for q in sm
            ymax := Max(ymax, q[3]), ymin := Min(ymin, q[3])
        dy := Round(y1 - y0), dx := Round(x1 - x0)
        msg := Format("sight trace: pink sight moved {} px {} and {} px {} over the spray  (range {} px, {} samples)"
            , Abs(dy), dy < 0 ? "UP" : "DOWN", Abs(dx), dx < 0 ? "LEFT" : "RIGHT", Round(ymax - ymin), sm.Length)
        Diag.Log(msg)
        Coach.Msg := msg
        View.Changed()
    }
}

; ------------------------------------------------------------------------------
; 19. DIAGNOSTICS REPORT  (no paths, no user names, nothing private)
; ------------------------------------------------------------------------------
class Diagnostics {
    static Row(label, value) => Format("{:-22s}{}", label, value) "`n"

    ; --- module status ---------------------------------------------------------------
    ; Every state comes from a field the Lua put into SPMSTATE. A field the Lua did not send
    ; (old script, no data yet) is shown as UNKNOWN - a module is never assumed from the weapon.
    static Sym(state) {
        switch state {
            case "ENABLED": return "✓ ENABLED"
            case "DISABLED": return "○ DISABLED"
            case "ACTIVE": return "▶ ACTIVE"
            case "UNAVAILABLE": return "⚠ UNAVAILABLE"
        }
        return "? UNKNOWN"
    }

    ; state text for one Lua field; kind = "recoil"/"rapid" lets a running burst upgrade ENABLED to ACTIVE.
    static Mod(label, field, detail := "", kind := "") {
        state := Live.Data.Has(field) ? Live.Data[field] : ""
        b := Live.Burst
        if (state = "ENABLED" && kind != "" && b["active"] && b[kind] = 1 && (A_TickCount - b["t"]) < 60000)
            state := "ACTIVE"
        txt := Diagnostics.Sym(state)
        if (state = "ACTIVE" && kind != "")
            txt .= " (firing)"
        return Format("{:-22s}{:-18s}{}", label, txt, detail) "`n"
    }

    static Modules() {
        if (Live.Data.Count = 0)
            return "  no state received yet - every module is UNKNOWN`n"
        g := (k, d := "") => Live.Data.Has(k) ? Live.Data[k] : d
        t := ""
        t .= Diagnostics.Mod("SYSTEM", "m_system")
        t .= Diagnostics.Mod("OPERATOR DETECTION", "m_detect", "GetMousePosition + tile grid")
        t .= Diagnostics.Mod("CALIBRATION", "m_calib", "ATK " Calib.Short("attackers") "  DEF " Calib.Short("defenders") "  grid " g("grid", "?"))
        t .= Diagnostics.Mod("SLOT SYNC (1 / 2)", "m_slotsync", g("slot_key", "?") " is " g("slot_lock", "?") "  (OFF = primary, ON = secondary)")
        t .= Diagnostics.Mod("RECOIL", "m_recoil", SubStr(g("recoil", ""), 1, 40), "recoil")
        rp := g("recoil_profile", "")
        t .= Format("{:-22s}{:-18s}{}", "  RECOIL PROFILE", rp != "" ? rp : "? UNKNOWN"
            , rp != "" ? "gain " g("recoil_gain", "?") ", secondary " (g("recoil_secondary", "0") = "1" ? "on" : "off") : "") "`n"
        t .= Diagnostics.Mod("JITTER", "m_jitter", g("jitter_amount", "") != "" ? "amount x" g("jitter_amount") : "")
        cap := g("rapid_cap", "")
        rd := cap = "" ? "" : cap = "-" ? "weapon " g("weapon", "?") " is not in the Lua's semi-auto list"
            : "weapon " g("weapon", "?") ": semi-auto, cap " cap " rpm"
        t .= Diagnostics.Mod("RAPID FIRE", "m_rapid", rd, "rapid")
        ; why is (or is not) it clicking? counters straight from the Lua's input handler
        t .= Format("{:-22s}{}", "  INPUT EVENTS", "LMB " g("ev_lmb", "?") "  RMB " g("ev_rmb", "?") "  bursts " g("ev_bursts", "?") "  clicks sent " g("ev_clicks", "?")) "`n"
        t .= Format("{:-22s}{}", "  LAST BUTTON SEEN", g("ev_last", "?")) "`n"
        t .= Format("{:-22s}{}", "  LAST SKIP REASON", g("ev_skip", "-") (g("ev_skips", "0") != "0" ? "   (" g("ev_skips") "x)" : "")) "`n"
        inj := g("ev_inj", "-")
        t .= Format("{:-22s}{}", "  CLICK INJECTION", inj = "-" ? "not tested yet (needs one rapid-fire burst)" : inj) "`n"
        hint := ""
        if (InStr(inj, "LOGICAL"))
            hint := "IsMouseButtonPressed follows the injected clicks, so the burst ends after the first click."
        else if (InStr(g("ev_skip", ""), "manager hotkey"))
            hint := "A modifier held while firing (Ctrl/Shift/Alt) triggered a manager hotkey instead of the macro."
        else if (g("ev_lmb", "") = "0")
            hint := "No LMB event received yet. Fire once; if this stays 0, G HUB is not sending clicks to this script."
        if (hint != "")
            t .= "  ⚠ " hint "`n"
        t .= Format("{:-22s}{:-18s}{}", "  RECOIL COACH", Recorder.On ? "▶ ACTIVE" : "○ DISABLED", "scored " (Coach.Seen - Coach.Skipped) ", skipped " Coach.Skipped ", mouse test: " (Coach.Mode() != "" ? Coach.Mode() : "not done") "  (" Coach.Msg ")") "`n"
        t .= Format("{:-22s}{:-18s}{}", "  SCREEN COACH", ScreenCoach.Training ? "▶ TRAINING" : "○ TRAINING OFF", ScreenCoach.Last " | px/count " Cfg.Get("coach.pxy", "not calibrated (F11)")) "`n"
        t .= Diagnostics.Mod("DEBUG LOG", "m_debug")
        t .= Format("{:-22s}{:-18s}{}", "LOADOUT MANAGER", "✓ ENABLED", "loadout " g("loadout", "-") " (" g("loadout_n", "0") " saved), " g("fav_n", "?") " favourites") "`n"
        lk := Live.Status
        t .= Format("{:-22s}{:-18s}{}", "STATE EXPORT", (lk = "CONNECTED" || lk = "IDLE") ? "✓ ENABLED" : "⚠ " lk, "protocol " g("protocol", "?") ", seq " Live.Seq) "`n"
        lc := Sync.LuaConfig()
        t .= Format("{:-22s}{:-18s}{}", "CONFIG BLOCK", lc[1] = "OK" ? "✓ IN SYNC" : "⚠ " lc[1], "rev " g("cfgrev", "?")) "`n"
        b := Live.Burst
        lastAge := b["lastT"] ? Round((A_TickCount - b["lastT"]) / 1000) "s ago" : ""
        t .= Format("{:-22s}{}", "LAST FIRING BURST", b["last"] != "" ? b["last"] "  (" lastAge ")" : "none yet") "`n"
        wn := g("warn_n", "0")
        t .= Format("{:-22s}{}", "LUA WARNINGS", wn = "0" ? "none" : "⚠ " wn " - first: " SubStr(g("warn_1", ""), 1, 60)) "`n"
        return t
    }

    static Text() {
        t := ""
        age := Live.AgeMs()
        t .= "SYSTEM`n"
        t .= Diagnostics.Row("G HUB STATE LINK", Live.Status = "CONNECTED" ? "✓ CONNECTED" : Live.Status = "IDLE" ? "✓ CONNECTED (idle)" : Live.Status = "LOST" ? "✗ SIGNAL LOST" : Live.Status = "MISMATCH" ? "⚠ PROTOCOL MISMATCH" : "… WAITING")
        t .= Diagnostics.Row("LAST STATE", age >= 0 ? (age < 10000 ? age " ms ago" : Round(age / 1000) " s ago") : "never")
        t .= Diagnostics.Row("PROTOCOL", Live.Protocol ? "v" Live.Protocol " (build understands v" App.Protocol ")" : "-")
        t .= Diagnostics.Row("SESSION", Live.Session != "" ? Live.Session : "-")
        t .= Diagnostics.Row("SEQUENCE", Live.Seq)
        t .= Diagnostics.Row("PACKETS", Live.Count " ok / " Live.Bad " rejected / " Live.Dups " duplicate / " Live.Restarts " restart(s)")
        t .= Diagnostics.Row("LISTENER", !DbgListener.Ready ? "✗ failed to start" : DbgListener.Shared ? "⚠ another debug monitor is running" : "✓ ready")
        t .= "`nGAME`n"
        has := Live.Data.Count > 0
        t .= Diagnostics.Row("SIDE", has ? Db.SideLabel(Live.Side()) : "-")
        t .= Diagnostics.Row("OPERATOR", has ? StrUpper(Live.OpName()) : "-")
        t .= Diagnostics.Row("ACTIVE SLOT", has ? StrUpper(Live.Slot()) : "-")
        t .= Diagnostics.Row("SYSTEM", has ? (Live.Get("enabled") = "1" ? "ON" : "OFF") : "-")
        t .= "`nDISPLAY`n"
        t .= Diagnostics.Row("RESOLUTION", Cfg.Get("game.resW") " × " Cfg.Get("game.resH") "  (screen " A_ScreenWidth " × " A_ScreenHeight ")")
        t .= Diagnostics.Row("WINDOWS SCALE", Round(A_ScreenDPI / 96 * 100) "%")
        t .= Diagnostics.Row("UI / HUD SCALE", Round(Cfg.Num("ui.scale", 1) * 100) "% / " Round(Cfg.Num("ui.hudScale", 1) * 100) "%  (" Cfg.Get("ui.hudSize") ")")
        t .= "`nCALIBRATION`n"
        for side in Db.Sides
            t .= Diagnostics.Row(StrUpper(Db.SideLabel(side)) " GRID", Calib.Long(side))
        t .= Diagnostics.Row("COORDINATE SPACE", Calib.SpaceText())
        ll := Calib.LuaLast
        t .= Diagnostics.Row("LAST LUA CLICK", !ll.Count ? "none yet (RSHIFT + left click a tile)"
            : (ll["agree"] ? "✓ agrees with this app" : "✗ DIFFERS: Lua row " ll["row"] " col " ll["col"] " vs app row " ll["ahkRow"] " col " ll["ahkCol"]))
        for side in Db.Sides
            if (Calib.HasCal(side) && !Calib.Exportable(Cfg.Data["calibration"][side]))
                t .= Diagnostics.Row(StrUpper(Db.SideLabel(side)) " EXPORT", "⚠ held back (captured here, space not verified)")
        t .= "`nLOADOUT`n"
        t .= Diagnostics.Row("PRIMARY", has ? Live.Get("primary", "-") : "-")
        t .= Diagnostics.Row("SECONDARY", has ? Live.Get("secondary", "-") : "-")
        t .= Diagnostics.Row("SCOPE", has ? Live.Get("scope", "-") : "-")
        t .= Diagnostics.Row("BARREL", has ? Live.Get("barrel", "-") : "-")
        t .= Diagnostics.Row("GRIP", has ? Live.Get("grip", "-") : "-")
        t .= Diagnostics.Row("NAMED LOADOUT", has ? Live.Get("loadout", "-") : "-")
        t .= "`nMODULE STATUS  (as reported by the Lua)`n"
        t .= Diagnostics.Modules()
        t .= "`nCONFIG`n"
        t .= Diagnostics.Row("CONFIG VERSION", App.CfgVersion)
        t .= Diagnostics.Row("CONFIG STATUS", (Cfg.Status = "VALID" || Cfg.Status = "NEW") ? "✓ " (Cfg.Status = "NEW" ? "NEW" : "VALID") : "⚠ " Cfg.StatusMsg)
        lc := Sync.LuaConfig()
        t .= Diagnostics.Row("LUA CONFIG", lc[1] = "OK" ? "✓ IN SYNC" : "⚠ " lc[2])
        t .= Diagnostics.Row("DATABASE", !has ? "-" : Live.Get("dbrev", "") = Db.Rev ? "✓ MATCHES LUA (" Db.Rev ")" : "⚠ MISMATCH (lua " Live.Get("dbrev", "?") " / app " Db.Rev ")")
        t .= Diagnostics.Row("APP VERSION", App.Version)
        t .= Diagnostics.Row("LAST ERROR", Diag.LastError != "" ? "⚠ " Diag.LastError " (" Diag.ErrCount "x)" : "none")
        return t
    }

    ; Discord-ready: fenced code block.
    static Report() => "``````" "`n" "SIEGE PROFILE MANAGER " App.Version " - DIAGNOSTICS`n`n" Diagnostics.Text() "``````"
}

; ------------------------------------------------------------------------------
; 20. QUICK SETUP  (3 screens; everything that can be detected is detected)
;   1 SETTINGS     read from Siege's own GameSettings.ini (sensitivity, FOV, resolution); you add the DPI
;   2 PREFERENCES  attachment defaults, HUD position, launch with Windows
;   3 INSTALL      the finished Lua script is copied for you; the screen turns green by itself as soon
;                  as G HUB reports that it loaded this exact config
;   Operator-grid calibration is NOT part of setup: the Lua ships presets, and the Home checklist tells
;   you (and fixes it in one click) if a tile ever detects wrongly.
; ------------------------------------------------------------------------------
class SiegeIni {
    ; Finds the newest %Documents%\My Games\Rainbow Six - Siege\<id>\GameSettings.ini and reads what it can.
    ; Returns a Map (possibly empty). Keys: path, res(WxH), sensH, sensV, fov, ads. Key names are matched
    ; loosely because Ubisoft has renamed them between seasons; anything not found is simply left out.
    static Detect() {
        out := Map()
        root := A_MyDocuments "\My Games\Rainbow Six - Siege"
        best := "", bestT := 0
        try {
            loop files, root "\*", "D" {
                p := A_LoopFileFullPath "\GameSettings.ini"
                if FileExist(p) {
                    t := FileGetTime(p, "M")
                    if (t > bestT)
                        bestT := t, best := p
                }
            }
        }
        if (best = "")
            return out
        try text := FileRead(best, "UTF-8")
        catch
            return out
        kv := Map(), w := 0, h := 0
        for line in StrSplit(text, "`n", "`r") {
            eq := InStr(line, "=")
            if (eq < 2 || SubStr(line, 1, 1) = "[")
                continue
            k := StrLower(Trim(SubStr(line, 1, eq - 1)))
            v := Trim(SubStr(line, eq + 1))
            if !IsNumber(v)
                continue
            kv[k] := v + 0
        }
        for k, v in kv {
            if (InStr(k, "yaw") && InStr(k, "sens") && !out.Has("sensH"))
                out["sensH"] := v
            else if (InStr(k, "pitch") && InStr(k, "sens") && !out.Has("sensV"))
                out["sensV"] := v
            else if ((k = "defaultfov" || k = "fov") && !out.Has("fov"))
                out["fov"] := Round(v, 1)
            else if (k = "resolutionwidth" || k = "resolution_width")
                w := v
            else if (k = "resolutionheight" || k = "resolution_height")
                h := v
            else if ((InStr(k, "ads") || InStr(k, "aimdownsight")) && InStr(k, "sens") && !InStr(k, "multiplier") && !out.Has("ads"))
                out["ads"] := v
        }
        if (w > 0 && h > 0)
            out["res"] := Integer(w) "x" Integer(h)
        if out.Count
            out["path"] := best
        return out
    }
}

class Startup {
    static Link := A_Startup "\SiegeProfileManager.lnk"
    static IsOn() => FileExist(Startup.Link) ? true : false
    static Set(on) {
        try {
            if on
                FileCreateShortcut(A_ScriptFullPath, Startup.Link, A_ScriptDir, "", "Siege Profile Manager")
            else if FileExist(Startup.Link)
                FileDelete(Startup.Link)
        } catch as e
            Diag.Err(e, "startup")
    }
}

class Wizard {
    static Gui := ""
    static Ctl := Map()
    static Page := 1
    static Visible := false
    static Pages := Map()
    static Installed := false
    static Ini := Map()
    static Tg := Map()

    static Start() {
        if IsObject(Wizard.Gui)
            try Wizard.Gui.Destroy()
        g := Gui("+AlwaysOnTop -DPIScale", "Siege Profile Manager - Quick setup")
        g.MarginX := 0, g.MarginY := 0
        g.BackColor := Clr.Bg
        Wizard.Gui := g
        Wizard.Pages := Map(1, [], 2, [], 3, [])
        Wizard.Installed := false
        Wizard.Tg := Map()
        c := Map()
        add := (pg, ctrl) => (Wizard.Pages[pg].Push(ctrl), ctrl)

        Ui.Rect(g, 0, 0, 640, 84, Clr.Panel)
        Ui.Gradient(g, 0, 83, 640, 3, Clr.Accent, Clr.Accent2, 40)
        Ui.Rect(g, 20, 10, 52, 44, Ui.Mix(Clr.Panel, Clr.Accent, 0.35))
        Ui.Txt(g, 24, 14, 44, 36, "SPM", 11, "Bold", Clr.Ink, Clr.Accent, "Center", "Segoe UI Black")
        Ui.Txt(g, 84, 10, 400, 30, "QUICK SETUP", 15, "Bold", Clr.Text, Clr.Panel, "", "Segoe UI Black")
        c["prog"] := Ui.Mono(g, 80, 44, 380, 22, "", 11, Clr.Accent, Clr.Panel)
        c["cnt"] := Ui.Txt(g, 480, 14, 136, 26, "", 11, "Bold", Clr.Dim, Clr.Panel, "Right")

        ; ---- page 1: settings -------------------------------------------------------
        add(1, c["t1"] := Ui.Txt(g, 24, 104, 592, 30, "", 15, "Bold", Clr.Text))
        add(1, c["src"] := Ui.Txt(g, 24, 136, 592, 22, "", 9, "Bold", Clr.Dim))
        fields := [["res", "Resolution", 24, 178], ["dpi", "Mouse DPI", 24, 222], ["ads", "ADS", 24, 266]
            , ["sh", "Horizontal sens", 328, 178], ["sv", "Vertical sens", 328, 222], ["fov", "FOV", 328, 266]]
        for f in fields {
            add(1, Ui.Txt(g, f[3], f[4] + 2, 150, 24, f[2], 9, "Bold", Clr.Dim))
            c["e_" f[1]] := add(1, Ui.Edit(g, f[3] + 150, f[4], 130, 28))
        }
        add(1, Ui.Txt(g, 24, 314, 592, 40, "DPI is your mouse DPI as set in G HUB. Everything here can be changed later in Settings.", 9, "Norm", Clr.Mute))
        c["t1b"] := add(1, Ui.Btn(g, 24, 366, 250, 32, "READ FROM SIEGE AGAIN", () => Wizard.ReadIni()))
        ; ---- page 2: preferences -----------------------------------------------------
        add(2, Ui.Txt(g, 24, 104, 592, 30, "Your defaults", 15, "Bold", Clr.Text))
        add(2, Ui.Txt(g, 24, 136, 592, 22, "Used the first time a weapon loads. The Lua only ever picks attachments the weapon can equip.", 9, "Norm", Clr.Mute))
        y := 176
        for row in [["scope", "Preferred sight", Db.AllScopes()], ["barrel", "Preferred barrel", LoadoutMgr.BarrelChain], ["grip", "Preferred grip", LoadoutMgr.GripChain]] {
            add(2, Ui.Txt(g, 24, y + 2, 170, 24, row[2], 9, "Bold", Clr.Dim))
            c["d_" row[1]] := add(2, Ui.Drop(g, 200, y, 250, row[3]))
            y += 44
        }
        add(2, Ui.Txt(g, 24, y + 2, 170, 24, "HUD position", 9, "Bold", Clr.Dim))
        c["d_hud"] := add(2, Ui.Drop(g, 200, y, 250, ["Top Left", "Top Right", "Bottom Left", "Bottom Right"]))
        Wizard.Tg["start"] := Toggle(g, 24, y + 52, 400, "Start automatically with Windows", true, (v) => 0)
        add(2, Wizard.Tg["start"].Ctl)
        ; ---- page 3: install ---------------------------------------------------------
        add(3, Ui.Txt(g, 24, 104, 592, 30, "Install into G HUB", 15, "Bold", Clr.Text))
        c["i1"] := add(3, Ui.Txt(g, 24, 148, 592, 30, "", 11, "Bold", Clr.Text))
        c["i2"] := add(3, Ui.Txt(g, 24, 182, 592, 30, "", 11, "Bold", Clr.Text))
        c["i3"] := add(3, Ui.Txt(g, 24, 216, 592, 30, "", 11, "Bold", Clr.Dim))
        c["i4"] := add(3, Ui.Txt(g, 24, 262, 592, 60, "", 9, "Norm", Clr.Mute))
        c["i4"].Opt("-0x200 -0x4000")
        c["i5"] := add(3, Ui.Btn(g, 24, 340, 250, 34, "COPY THE SCRIPT AGAIN", () => Wizard.Install(), "p"))
        ; ---- navigation ----------------------------------------------------------------
        c["back"] := Ui.Btn(g, 24, 444, 110, 36, "◂ BACK", () => Wizard.Go(-1))
        c["next"] := Ui.Btn(g, 486, 444, 130, 36, "NEXT ▸", () => Wizard.Go(1), "p")
        Wizard.Ctl := c
        g.OnEvent("Close", (*) => Wizard.Close())
        Wizard.Page := 1
        Wizard.Visible := true
        g.Show("w" Ui.S(640) " h" Ui.S(500))
        Ui.DarkTitle(g)
        Ui.Chrome(g, Clr.Panel, Clr.Accent, Clr.Text)
        Wizard.ReadIni(true)
        Wizard.Render()
    }

    static Close() {
        Wizard.Visible := false
        try Wizard.Gui.Hide()
    }

    ; Fills page 1 from what the app already knows: Siege's settings file first, then the Lua's report, then defaults.
    static ReadIni(quiet := false) {
        c := Wizard.Ctl
        ini := SiegeIni.Detect()
        Wizard.Ini := ini
        g := Cfg.Data["game"]
        pick := (iniKey, cfgKey) => ini.Has(iniKey) ? ini[iniKey] : g[cfgKey]
        c["e_res"].Text := ini.Has("res") ? ini["res"] : A_ScreenWidth "x" A_ScreenHeight
        c["e_dpi"].Text := g["dpi"]
        c["e_sh"].Text := pick("sensH", "sensH")
        c["e_sv"].Text := pick("sensV", "sensV")
        c["e_fov"].Text := pick("fov", "fov")
        c["e_ads"].Text := pick("ads", "ads")
        n := 0
        for k in ["res", "sensH", "sensV", "fov", "ads"]
            if ini.Has(k)
                n++
        if (n > 0) {
            SetText(c["src"], "✓ Read " n " value(s) from your Siege settings file. Check them, then add your DPI.")
            Ui.Paint(c["src"], Clr.Green)
        } else {
            SetText(c["src"], "Siege settings file not found - the resolution is your monitor's; fill in the rest.")
            Ui.Paint(c["src"], Clr.Amber)
        }
        if !quiet
            Toast.Show(n ? "ok" : "warn", n ? "✓ READ FROM SIEGE" : "⚠ SIEGE SETTINGS NOT FOUND", n ? n " value(s) filled in" : "Enter them by hand", "", "")
    }

    static Render() {
        c := Wizard.Ctl
        p := Wizard.Page
        for pg, list in Wizard.Pages
            for ctl in list
                ctl.Visible := (pg = p)
        SetText(c["prog"], "SETUP   " Wizard.Bar(p * 8, 24))
        SetText(c["cnt"], p " / 3")
        SetText(c["t1"], "Your game settings")
        c["back"].Visible := p > 1
        SetText(c["next"], p = 3 ? "FINISH ✓" : "NEXT ▸")
        if (p = 2) {
            pref := Cfg.Data["prefs"]
            for f, items in Map("scope", Db.AllScopes(), "barrel", LoadoutMgr.BarrelChain, "grip", LoadoutMgr.GripChain)
                c["d_" f].Choose(IndexOf(items, pref[f]) || 1)
            c["d_hud"].Choose(IndexOf(["Top Left", "Top Right", "Bottom Left", "Bottom Right"], Cfg.Get("ui.hudPos")) || 2)
            Wizard.Tg["start"].Set(Startup.IsOn() || !Cfg.Get("setup.done", 0))
        }
        if (p = 3 && !Wizard.Installed)
            Wizard.Install()
        Wizard.Refresh()
    }

    static Bar(filled, total) {
        s := ""
        loop total
            s .= (A_Index <= filled) ? "█" : "░"
        return s
    }

    ; Builds the full script (your Lua + your config) on the clipboard.
    static Install() {
        Cfg.SaveNow()
        r := LuaBlock.Copy()
        Wizard.Installed := true
        Wizard.Res := r
        LuaBlock.Announce(r)
        Wizard.Refresh()
    }
    static Res := ""

    ; Live status of page 3: turns green by itself when G HUB reports this config.
    static Refresh() {
        if (!Wizard.Visible || Wizard.Page != 3 || !Wizard.Installed)
            return
        c := Wizard.Ctl
        r := Wizard.Res
        full := IsObject(r) && r["full"]
        SetText(c["i1"], full ? "✓  1  Your whole script + settings is on the clipboard" : "⚠  1  Only the config block is on the clipboard")
        Ui.Paint(c["i1"], full ? Clr.Green : Clr.Amber)
        SetText(c["i2"], "▸  2  In G HUB: open the script, press Ctrl + A, paste, Save")
        Ui.Paint(c["i2"], Clr.Text)
        lc := Sync.LuaConfig()
        done := (lc[1] = "OK")
        SetText(c["i3"], done ? "✓  3  G HUB has loaded your config. You're done." : Live.Status = "LOST" || Live.Data.Count = 0 ? "…  3  Waiting for G HUB (press RALT + left click once after saving)" : "…  3  Waiting for G HUB to load it")
        Ui.Paint(c["i3"], done ? Clr.Green : Clr.Dim)
        SetText(c["i4"], (IsObject(r) && !r["full"] ? r["err"] "`n" : "") "Script used: " Cfg.Get("lua.path", "(not found)"))
    }

    static Go(dir) {
        p := Wizard.Page
        c := Wizard.Ctl
        if (dir > 0 && p = 1 && !Wizard.SaveSettings())
            return
        if (dir > 0 && p = 2)
            Wizard.SavePrefs()
        if (dir > 0 && p = 3) {
            Cfg.Set("setup.done", 1)
            Cfg.SaveNow()
            Wizard.Close()
            View.Changed()
            return
        }
        Wizard.Page := Clamp(p + dir, 1, 3)
        Wizard.Render()
    }

    static SaveSettings() {
        c := Wizard.Ctl
        if !RegExMatch(Trim(c["e_res"].Text), "i)^(\d{3,5})\s*[x×]\s*(\d{3,5})$", &m) {
            Toast.Show("warn", "⚠ RESOLUTION", "Use the form 3440x1440", "", "")
            return false
        }
        rules := [["e_dpi", "dpi", 50, 32000, "DPI"], ["e_sh", "sensH", 0.1, 100, "Horizontal sens"], ["e_sv", "sensV", 0.1, 100, "Vertical sens"]
            , ["e_fov", "fov", 40, 140, "FOV"], ["e_ads", "ads", 1, 200, "ADS"]]
        for r in rules {
            v := Trim(c[r[1]].Text)
            if !(IsNumber(v) && v + 0 >= r[3] && v + 0 <= r[4]) {
                Toast.Show("warn", "⚠ " StrUpper(r[5]), "Enter a number between " r[3] " and " r[4], "", "")
                return false
            }
        }
        for r in rules
            Cfg.Data["game"][r[2]] := Trim(c[r[1]].Text) + 0
        Cfg.Data["game"]["resW"] := Integer(m[1]), Cfg.Data["game"]["resH"] := Integer(m[2])
        Cfg.Dirty()
        return true
    }

    static SavePrefs() {
        c := Wizard.Ctl
        for f in ["scope", "barrel", "grip"]
            if (c["d_" f].Text != "")
                Cfg.Data["prefs"][f] := c["d_" f].Text
        if (c["d_hud"].Text != "") {
            Cfg.Set("ui.hudPos", c["d_hud"].Text)
            View.RebuildSoon()
        }
        Startup.Set(Wizard.Tg["start"].On)
        Cfg.Dirty()
    }
}

; Slow "live" pulse of the HUD dot while the G HUB link is healthy.
class Anim {
    static P := false
    static Tick() {
        Anim.P := !Anim.P
        if (Hud.Shown && Live.Status = "CONNECTED" && Hud.Ctl.Has("dot"))
            Ui.Paint(Hud.Ctl["dot"], Anim.P ? Clr.Green : Clr.GreenDim)
    }
}

; ------------------------------------------------------------------------------
; 21. WEAPON SLOT SYNC  (unchanged behaviour)
;     Pressing 1 / 2 in Siege selects primary / secondary. G HUB Lua cannot see number keys,
;     so this script watches them and sets a lock key the Lua CAN read:
;     ScrollLock OFF = primary, ON = secondary. The keys still reach the game (~ prefix).
;     Must match CONFIG.slotSync.lockKey in the Lua.
; ------------------------------------------------------------------------------
class SlotSync {
    static Exes := ["RainbowSix.exe", "RainbowSix_Vulkan.exe", "RainbowSix_BE.exe"]
    static Anywhere := false        ; true = react in any window (for testing)

    static SiegeActive() {
        if SlotSync.Anywhere
            return true
        try exe := WinGetProcessName("A")
        catch
            return false
        for name in SlotSync.Exes
            if (StrLower(exe) = StrLower(name))
                return true
        return false
    }

    static Set(which, refresh := true) {
        try SetScrollLockState(which = "SECONDARY" ? "On" : "Off")
        if (refresh && Live.Data.Count) {
            if (Live.Get("secondary") = "NONE" && which = "SECONDARY")
                return                              ; operator has no secondary: the Lua ignores it too
            Live.Data["slot"] := which              ; optimistic; the Lua's next snapshot is authoritative
            View.Changed()
        }
    }
}

; ------------------------------------------------------------------------------
; 22. UI CONTROLLER  (compact HUD <-> control centre, visibility, rebuilds)
; ------------------------------------------------------------------------------
class View {
    static Mode := "hud"
    static Hidden := false
    static Pending := false
    static RebuildFn := ""
    static FullRebuild := false

    ; Coalesces bursts of changes into a single redraw (keeps CPU near zero).
    static Changed() {
        if View.Pending
            return
        View.Pending := true
        SetTimer(() => View.RefreshNow(), -40)
    }

    static RefreshNow() {
        View.Pending := false
        if View.Hidden
            return
        if (View.Mode = "hud")
            Hud.Render()
        else
            Center.Refresh()
        if Wizard.Visible
            Wizard.Refresh()
    }

    static Apply() {
        if View.Hidden {
            Hud.Hide(), Center.Hide(), Toast.Hide()
            return
        }
        if (View.Mode = "center") {
            Hud.Hide()
            Center.Show()
        } else {
            Center.Hide()
            Hud.Show()
        }
        View.Changed()
    }

    static SetMode(m) {
        View.Mode := m
        View.Hidden := false
        Cfg.Set("ui.mode", m)
        View.Apply()
    }

    static ToggleMode() {
        View.SetMode(View.Hidden ? View.Mode : (View.Mode = "hud" ? "center" : "hud"))
    }

    static ToggleVisible() {
        View.Hidden := !View.Hidden
        View.Apply()
    }

    ; Rebuilds windows after scale / size / position changes (debounced: sliders fire continuously).
    static RebuildSoon(full := false) {
        View.FullRebuild := View.FullRebuild || full
        if !IsObject(View.RebuildFn)
            View.RebuildFn := ObjBindMethod(View, "DoRebuild")
        SetTimer(View.RebuildFn, -350)
    }

    static DoRebuild() {
        if View.FullRebuild
            View.Rebuild()
        else {
            Hud.Build()
            Hud.Shown := false
            View.Apply()
        }
        View.FullRebuild := false
    }

    static Rebuild() {
        wasCenter := Center.Visible
        Center.Hide()
        Ui.Recalc()
        Hud.Build()
        Toast.Build()
        Center.Build()
        Hud.Shown := false
        View.Apply()
    }

    static Start() {
        Ui.Recalc()
        Hud.Build()
        Toast.Build()
        Center.Build()
        launch := Cfg.Get("ui.launch", "hud")
        View.Mode := launch = "center" ? "center" : "hud"
        View.Hidden := (launch = "hidden")
        View.Apply()
    }
}

; ------------------------------------------------------------------------------
; 23. START-UP
; ------------------------------------------------------------------------------
Db.Init()
Cfg.Load()
Cfg.SeedStandard()
Ui.Recalc()
DbgListener.Init()
Hk.RegisterAll()
try Hotkey("F11", (*) => ScreenCoach.CalibratePx(), "On")
try Hotkey("F12", (*) => ScreenCoach.ToggleTraining(), "On")                   ; screen coach only works while TRAINING is on        ; measures px per mouse count for the screen coach
View.Start()
SlotSync.Set("PRIMARY", false)                       ; baseline: lock key OFF = primary
SetTimer(() => Live.Poll(), 15)                  ; receives packets (DBWIN handshake needs quick service)
SetTimer(() => Live.Tick(), 1000)                ; link health
SetTimer(() => Hud.KeepOnTop(), 2000)            ; borderless games can steal the Z-order
SetTimer(() => Anim.Tick(), 700)                 ; "live" pulse
SetTimer(() => AutoCal.Tick(), 8000)               ; finds the operator grid by itself while Siege is in front
SetTimer(() => (Center.Visible && (Center.Cur = "HOME" || Center.Cur = "DIAGNOSTICS") ? Center.RefreshPage() : 0), 1000)
OnExit((*) => Cfg.SaveNow())
if Cfg.Get("coach.on", 0)
    SetTimer(() => Recorder.Set(true, true), -1500)   ; resume watching after a restart
OnError(AppError)                                ; any other uncaught error: log it, no modal box, keep running

if (Cfg.Status = "RECOVERED" || Cfg.Status = "DAMAGED")
    SetTimer(() => Toast.Show("warn", "⚠ CONFIGURATION", Cfg.StatusMsg, "", ""), -800)
if !DbgListener.Ready
    Diag.Log("DBWIN listener failed to start")
else if DbgListener.Shared
    SetTimer(() => Toast.Show("warn", "⚠ DEBUG MONITOR RUNNING", "Close DebugView / other debug tools", "", ""), -1200)
if !Cfg.Get("setup.done", 0)
    SetTimer(() => Wizard.Start(), -600)

; 1 / 2 still go to the game (~). Only while Siege is the active window.
#HotIf SlotSync.SiegeActive()
~1::SlotSync.Set("PRIMARY")
~2::SlotSync.Set("SECONDARY")
#HotIf

AppError(e, mode) {
    try Diag.Err(e, "uncaught")
    return 1                                     ; 1 = handled: suppress the error dialog
}

; ------------------------------------------------------------------------------
; GENERATED DATA - operators, weapons, attachments, grids, grid presets.
; Produced from siege_profile_manager.lua (its own tables); DBREV is the Lua's checksum of them.
; Sections: [W] id|kind|scopeSet|barrelSet|gripSet   [OP side] name|primaries|secondaries|defP|defS|fav
;           [GRID side] one row per line   [PRESETS] res|side|tlx|tly|brx|bry|padx|pady   [SETS] shared lists
; ------------------------------------------------------------------------------
DbRaw() {
    return "
(
DBREV=2924023B
[W]
M4|primary|1|2|3
M249|primary|1|4|3
SR-25|primary|5|6|3
M590A1|primary|7|8|8
L85A2|primary|1|9|3
AR33|primary|1|9|3
PMR90A2|primary|10|8|3
G36C|primary|1|2|3
R4-C|primary|1|2|3
556XI|primary|1|9|3
M1014|primary|7|8|8
F2|primary|1|2|3
417|primary|5|6|3
SG-CQB|primary|7|8|11
OTS-03|primary|7|6|3
6P41|primary|1|9|3
AK-12|primary|1|9|3
AUG A2|primary|1|9|8
552 COMMANDO|primary|1|2|3
G8A1|primary|1|9|3
C8-SFW|primary|1|2|8
CAMRS|primary|5|6|3
MK17 CQB|primary|1|2|3
PARA-308|primary|1|2|3
TYPE-89|primary|1|9|3
SUPERNOVA|primary|7|12|11
C7E|primary|1|9|3
PDW9|primary|1|2|3
ITA12L|primary|7|8|8
T-95 LSW|primary|1|9|3
SIX12|primary|7|8|8
LMG-E|primary|1|9|3
M762|primary|1|9|3
XK23|primary|10|13|3
MK 14 EBR|primary|5|6|3
BOSG.12.2|primary|1|8|3
V308|primary|1|9|3
SPEAR .308|primary|1|2|3
SASG-12|primary|7|12|3
AR-15.50|primary|5|6|3
AK-74M|primary|1|9|3
ARX200|primary|1|9|3
F90|primary|1|2|3
M249 SAW|primary|1|4|3
FMG-9|primary|1|2|8
SIX12 SD|primary|7|8|8
CSRX 300|primary|14|8|8
SC3000K|primary|1|2|3
MP7|primary|1|2|8
POF-9|primary|1|2|3
COMMANDO 9|primary|7|2|3
M870|primary|7|8|8
TCSG12|primary|1|12|3
MP5K|primary|7|2|8
UMP45|primary|7|2|3
MP5|primary|7|2|3
P90|primary|1|2|8
9X19VSN|primary|7|2|3
DP27|primary|15|8|8
416-C|primary|7|2|3
SUPER 90|primary|7|8|8
9MM C1|primary|7|2|3
MPX|primary|7|2|3
SPAS-12|primary|7|8|8
M12|primary|7|2|3
SPAS-15|primary|7|8|8
MP5SD|primary|7|8|3
VECTOR .45 ACP|primary|7|2|3
T-5 SMG|primary|7|2|3
SCORPION EVO 3 A1|primary|7|9|3
FO-12|primary|7|16|3
K1A|primary|7|2|3
ALDA 5.56|primary|7|9|11
ACS12|primary|1|8|3
MX4 STORM|primary|7|2|3
AUG A3|primary|7|2|3
P10 RONI|primary|7|2|3
UZK50GI|primary|7|2|3
PCX-33|primary|7|2|3
GLAIVE-12|primary|7|8|3
5.7 USG|secondary|14|6|8
ITA12S|secondary|7|8|8
REAPER MK2|secondary|14|9|8
P226 MK 25|secondary|14|6|8
M45 MEUSOC|secondary|14|6|8
P9|secondary|14|6|8
LFP586|secondary|14|8|8
PMM|secondary|14|6|8
GONNE-6|secondary|14|8|8
BEARING 9|secondary|7|2|8
GSH-18|secondary|14|6|8
P12|secondary|14|6|8
MK1 9MM|secondary|14|6|8
PRB92|secondary|14|6|8
P229|secondary|14|6|8
USP40|secondary|14|6|8
Q-929|secondary|14|6|8
RG15|secondary|14|6|8
SMG-12|secondary|7|8|3
C75 AUTO|secondary|14|12|8
1911 TACOPS|secondary|14|6|8
.44 MAG SEMI-AUTO|secondary|14|8|8
SUPER SHORTY|secondary|7|8|8
SDP 9MM|secondary|14|8|8
D-50|secondary|14|8|8
SMG-11|secondary|7|2|3
SPSMG9|secondary|7|2|8
BAILIFF 410|secondary|14|8|8
.44 VENDETTA|secondary|14|8|8
TACIT .45|secondary|10|8|8
P-10C|secondary|14|6|8
KERATOS .357|secondary|14|6|8
LUISON|secondary|14|8|8
[OP attackers]
Striker|M4,M249,SR-25|5.7 USG,ITA12S|M4|5.7 USG|0
Sledge|M590A1,L85A2|REAPER MK2,P226 MK 25|L85A2|REAPER MK2|0
Thatcher|AR33,L85A2,PMR90A2,M590A1|P226 MK 25|AR33|P226 MK 25|0
Ash|G36C,R4-C|M45 MEUSOC,5.7 USG|R4-C|M45 MEUSOC|0
Thermite|556XI,M1014|M45 MEUSOC,5.7 USG,ITA12S|556XI|M45 MEUSOC|0
Twitch|F2,417,SG-CQB|P9,LFP586|F2|P9|1
Montagne||P9,LFP586||P9|0
Glaz|OTS-03|PMM,GONNE-6,BEARING 9|OTS-03|PMM|0
Fuze|6P41,AK-12|PMM,GSH-18|6P41|PMM|0
Blitz||P12||P12|0
IQ|AUG A2,552 COMMANDO,G8A1|P12|AUG A2|P12|0
Buck|C8-SFW,CAMRS|MK1 9MM|C8-SFW|MK1 9MM|1
Blackbeard|MK17 CQB,SR-25||MK17 CQB||0
Capitao|PARA-308,M249,PMR90A2|PRB92,GONNE-6|PARA-308|PRB92|0
Hibana|TYPE-89,SUPERNOVA,PMR90A2|P229,BEARING 9|TYPE-89|P229|0
Jackal|C7E,PDW9,ITA12L|USP40,ITA12S|C7E|USP40|0
Ying|T-95 LSW,SIX12|Q-929,REAPER MK2|T-95 LSW|Q-929|0
Zofia|LMG-E,M762|RG15|M762|RG15|0
Dokkaebi|XK23,MK 14 EBR,BOSG.12.2|SMG-12,C75 AUTO,GONNE-6|XK23|SMG-12|0
Lion|V308,417,SG-CQB|LFP586,P9|V308|LFP586|0
Finka|SPEAR .308,6P41,SASG-12|PMM,GSH-18|SPEAR .308|PMM|0
Maverick|AR-15.50,M4|1911 TACOPS,REAPER MK2|AR-15.50|1911 TACOPS|0
Nomad|AK-74M,ARX200|.44 MAG SEMI-AUTO,PRB92|AK-74M|.44 MAG SEMI-AUTO|0
Gridlock|F90,M249 SAW|SUPER SHORTY,SDP 9MM|F90|SUPER SHORTY|0
Nokk|FMG-9,SIX12 SD,PMR90A2|5.7 USG,D-50|FMG-9|5.7 USG|0
Amaru|G8A1,SUPERNOVA|SMG-11,ITA12S,GONNE-6|G8A1|SMG-11|0
Kali|CSRX 300|SPSMG9,C75 AUTO,P226 MK 25|CSRX 300|SPSMG9|0
Iana|ARX200,G36C|MK1 9MM,GONNE-6|ARX200|MK1 9MM|0
Ace|AK-12,M1014|P9|AK-12|P9|0
Zero|SC3000K,MP7|5.7 USG,GONNE-6|SC3000K|5.7 USG|0
Flores|AR33,SR-25,T-95 LSW|GSH-18|AR33|GSH-18|0
Osa|556XI,PDW9|PMM|556XI|PMM|0
Sens|POF-9,417,XK23|SDP 9MM|POF-9|SDP 9MM|0
Grim|552 COMMANDO,SG-CQB|P229,BAILIFF 410|552 COMMANDO|P229|0
Brava|PARA-308,CAMRS|SUPER SHORTY,USP40|PARA-308|SUPER SHORTY|0
Ram|R4-C,LMG-E|MK1 9MM|R4-C|MK1 9MM|0
Deimos|AK-74M,M590A1|.44 VENDETTA|AK-74M|.44 VENDETTA|0
Rauora|417,M249,XK23|REAPER MK2,GSH-18|417|REAPER MK2|0
Solid Snake|F2,PMR90A2|TACIT .45|F2|TACIT .45|0
[GRID attackers]
Striker,Sledge,Thatcher,Ash,Thermite,Twitch,Montagne
Glaz,Fuze,Blitz,IQ,Buck,Blackbeard,Capitao
Hibana,Jackal,Ying,Zofia,Dokkaebi,Lion,Finka
Maverick,Nomad,Gridlock,Nokk,Amaru,Kali,Iana
Ace,Zero,Flores,Osa,Sens,Grim,Brava
Ram,Deimos,Rauora,Solid Snake,,,
,,,,,,
[OP defenders]
Sentry|COMMANDO 9,M870,TCSG12|C75 AUTO,SUPER SHORTY|COMMANDO 9|C75 AUTO|0
Smoke|FMG-9,M590A1|P226 MK 25,SMG-11|FMG-9|P226 MK 25|0
Mute|MP5K,M590A1|P226 MK 25,SMG-11|M590A1|SMG-11|0
Castle|UMP45,M1014|5.7 USG,SUPER SHORTY,M45 MEUSOC|UMP45|5.7 USG|0
Pulse|M1014,UMP45|REAPER MK2,M45 MEUSOC,5.7 USG|UMP45|REAPER MK2|0
Doc|SG-CQB,MP5,P90|P9,LFP586,BAILIFF 410|MP5|P9|0
Rook|P90,MP5,SG-CQB|LFP586,P9,REAPER MK2|P90|LFP586|0
Kapkan|9X19VSN,SASG-12|PMM,GSH-18|9X19VSN|PMM|0
Tachanka|DP27,9X19VSN|GSH-18,PMM,BEARING 9|DP27|GSH-18|0
Jager|M870,416-C|P12,P-10C|416-C|P12|1
Bandit|MP7,M870|KERATOS .357,P12|MP7|KERATOS .357|0
Frost|SUPER 90,9MM C1|MK1 9MM,ITA12S|9MM C1|MK1 9MM|0
Valkyrie|MPX,SPAS-12|D-50|MPX|D-50|0
Caveira|M12,SPAS-15|LUISON|M12|LUISON|0
Echo|SUPERNOVA,MP5SD|P229,BEARING 9|MP5SD|P229|0
Mira|VECTOR .45 ACP,ITA12L|USP40,ITA12S|VECTOR .45 ACP|USP40|0
Lesion|SIX12 SD,T-5 SMG|Q-929|T-5 SMG|Q-929|0
Ela|SCORPION EVO 3 A1,FO-12|RG15|SCORPION EVO 3 A1|RG15|0
Vigil|K1A,BOSG.12.2|C75 AUTO,SMG-12|K1A|C75 AUTO|0
Maestro|ALDA 5.56,ACS12|BAILIFF 410,KERATOS .357|ALDA 5.56|BAILIFF 410|0
Alibi|MX4 STORM,ACS12|KERATOS .357,BAILIFF 410|MX4 STORM|KERATOS .357|0
Clash||SUPER SHORTY,SPSMG9,P-10C||SUPER SHORTY|0
Kaid|AUG A3,TCSG12|.44 MAG SEMI-AUTO,LFP586|AUG A3|.44 MAG SEMI-AUTO|0
Mozzie|COMMANDO 9,P10 RONI|SDP 9MM,SUPER SHORTY|COMMANDO 9|SDP 9MM|0
Warden|M590A1,MPX|P-10C,SMG-12|M590A1|SMG-12|0
Goyo|VECTOR .45 ACP,TCSG12|P229|VECTOR .45 ACP|P229|0
Wamai|AUG A2,MP5K|KERATOS .357,P12,SUPER SHORTY|AUG A2|KERATOS .357|0
Oryx|T-5 SMG,SPAS-12|BAILIFF 410,USP40,REAPER MK2|T-5 SMG|BAILIFF 410|0
Melusi|MP5,SUPER 90|RG15,ITA12S|MP5|RG15|0
Aruni|P10 RONI,MK 14 EBR|PRB92|P10 RONI|PRB92|0
Thunderbird|SPEAR .308,SPAS-15|Q-929,BEARING 9,ITA12S|SPEAR .308|Q-929|0
Thorn|UZK50GI,M870|1911 TACOPS,C75 AUTO|UZK50GI|1911 TACOPS|0
Azami|9X19VSN,ACS12|D-50|9X19VSN|D-50|0
Solis|P90,ITA12L|SMG-11|P90|SMG-11|0
Fenrir|MP7,SASG-12|5.7 USG|MP7|5.7 USG|0
Tubarao|MPX,AR-15.50|P226 MK 25|MPX|P226 MK 25|0
Skopos|PCX-33|P229|PCX-33|P229|0
Denari|SCORPION EVO 3 A1,FMG-9,GLAIVE-12|P226 MK 25|SCORPION EVO 3 A1|P226 MK 25|0
Noor|COMMANDO 9,ALDA 5.56|1911 TACOPS,BAILIFF 410|COMMANDO 9|1911 TACOPS|0
[GRID defenders]
Sentry,Smoke,Mute,Castle,Pulse,Doc,Rook
Kapkan,Tachanka,Jager,Bandit,Frost,Valkyrie,Caveira
Echo,Mira,Lesion,Ela,Vigil,Maestro,Alibi
Clash,Kaid,Mozzie,Warden,Goyo,Wamai,Oryx
Melusi,Aruni,Thunderbird,Thorn,Azami,Solis,Fenrir
Tubarao,Skopos,Denari,Noor,,,
,,,,,,
[PRESETS]
1920x1080|attackers|0.1160|0.1830|0.9260|0.7820|0.0040|0.0060
1920x1080|defenders|0.1160|0.1830|0.9260|0.7820|0.0040|0.0060
2560x1440|attackers|0.1160|0.1830|0.9260|0.7820|0.0040|0.0060
2560x1440|defenders|0.1160|0.1830|0.9260|0.7820|0.0040|0.0060
3440x1440|attackers|0.1399|0.2689|0.4225|0.8881|0.0030|0.0060
3440x1440|defenders|0.1399|0.2689|0.4225|0.8881|0.0030|0.0060
[SETS]
0=MAGNIFIED A,MAGNIFIED B,MAGNIFIED C,RED DOT A,RED DOT B,RED DOT C,HOLO A,HOLO B,HOLO C,HOLO D,REFLEX A,REFLEX B,REFLEX C,IRON SIGHT
1=FLASH HIDER,COMPENSATOR,MUZZLE BRAKE,SUPPRESSOR,EXTENDED BARREL,NONE
2=HORIZONTAL,VERTICAL,ANGLED
3=FLASH HIDER,COMPENSATOR,MUZZLE BRAKE,NONE
4=TELESCOPIC A,TELESCOPIC B,MAGNIFIED A,MAGNIFIED B,MAGNIFIED C,RED DOT A,RED DOT B,RED DOT C,HOLO A,HOLO B,HOLO C,HOLO D,REFLEX A,REFLEX B,REFLEX C,IRON SIGHT
5=MUZZLE BRAKE,SUPPRESSOR,NONE
6=RED DOT A,RED DOT B,RED DOT C,HOLO A,HOLO B,HOLO C,HOLO D,REFLEX A,REFLEX B,REFLEX C,IRON SIGHT
7=NONE
8=FLASH HIDER,COMPENSATOR,MUZZLE BRAKE,SUPPRESSOR,NONE
9=
10=HORIZONTAL,VERTICAL
11=SUPPRESSOR,NONE
12=EXTENDED BARREL,NONE
13=CUSTOM SIGHT
14=RED DOT A,RED DOT B,RED DOT C,HOLO A,HOLO B,HOLO C,HOLO D,REFLEX A,REFLEX B,REFLEX C,REFLEX D,IRON SIGHT
15=SUPPRESSOR,EXTENDED BARREL,NONE
)"
}
