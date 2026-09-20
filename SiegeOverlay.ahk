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
    static Bg := "14161A", Panel := "1B1E24", Panel2 := "23272E", Line := "2E333B"
    static Text := "E8E8E8", Dim := "A9ADB5", Mute := "6F747D"
    static Green := "3DDC84", Amber := "F0B429", Red := "FF5C5C", Blue := "5AA9FF"
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
            , "resW", A_ScreenWidth, "resH", A_ScreenHeight)
        d["prefs"] := Map("scope", "AUTO", "barrel", "SUPPRESSOR", "grip", "HORIZONTAL")
        d["state"] := Map("side", "attackers", "operator", "")
        d["favorites"] := []
        d["favInit"] := 0
        d["saved"] := Map()
        d["loadouts"] := Map()
        d["calibration"] := Map()
        d["luaKeybinds"] := Map()
        d["ui"] := Map("scale", 1.0, "mode", "hud", "hudSize", "Normal", "hudPos", "Top Right"
            , "hudX", 40, "hudY", 40, "hudScale", 1.0, "opacity", 235, "notifications", 1
            , "launch", "hud", "rememberPos", 1, "centerX", "", "centerY", "", "page", "HOME"
            , "sections", Cfg.DefaultSections())
        d["hotkeys"] := Map("mode", "F8", "visible", "F9", "capture", "F7", "profiles", "F10")
        d["setup"] := Map("done", 0)
        d["sync"] := Map("baseline", "", "copiedRev", "")
        return d
    }

    static DefaultSections() => Map("operator", 1, "weapon", 1, "attachments", 1
        , "connection", 1, "calibration", 0, "debug", 0)

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
    static Dirty() {
        Cfg.Ver++
        if !IsObject(Cfg.Fn)
            Cfg.Fn := ObjBindMethod(Cfg, "SaveNow")
        SetTimer(Cfg.Fn, -800)
    }

    ; The part of the config the Lua consumes. Changes to it can make the Lua's copy outdated.
    static LuaPart() {
        m := Map()
        for k in ["game", "prefs", "state", "favorites", "saved", "loadouts", "calibration", "luaKeybinds"]
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
        for sec in ["game", "prefs", "state", "ui", "hotkeys", "setup", "sync"] {
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
                        , "bry", c["bry"] + 0, "res", c.Get("res", ""))
            }
        out["luaKeybinds"] := Map()
        if (data.Has("luaKeybinds") && Type(data["luaKeybinds"]) = "Map")
            for act, b in data["luaKeybinds"]
                if (Type(b) = "Map" && b.Has("mod") && b.Has("button") && IndexOf(Hk.Mods, b["mod"])
                    && IsInteger(b["button"]) && b["button"] >= 1 && b["button"] <= 5)
                    out["luaKeybinds"][act] := Map("mod", StrLower(b["mod"]), "button", Integer(b["button"]))
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
        t .= "    calibration = {`n"
        for side, c in Cfg.Data["calibration"]
            t .= "        " side " = { tlx = " LuaBlock.N(c["tlx"]) ", tly = " LuaBlock.N(c["tly"]) ", brx = " LuaBlock.N(c["brx"]) ", bry = " LuaBlock.N(c["bry"]) " },`n"
        t .= "    },`n"
        t .= "    keybinds = {`n"
        for act, b in Cfg.Data["luaKeybinds"]
            t .= "        " act " = { mod = " LuaBlock.Q(b["mod"]) ", button = " b["button"] " },`n"
        t .= "    },`n"
        t .= "}`n"
        t .= "-- <<< SPM_USER END <<<`n"
        return t
    }

    ; Copies the block to the clipboard (and to a file) and marks the config as handed over.
    static Copy() {
        rev := A_Now
        text := LuaBlock.Build(rev)
        A_Clipboard := text
        try {
            f := FileOpen(App.Dir "\spm_user_block.lua", "w", "UTF-8-RAW")
            f.Write(text)
            f.Close()
        }
        Cfg.Data["sync"]["copiedRev"] := rev
        Cfg.Rebase()
        return rev
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
    static DbWarned := false

    static Poll() {
        for line in DbgListener.Drain()
            Live.Ingest(line)
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
        Cfg.FromLua(() => Sync.Record(side, opName, lo))
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
            Cfg.FromLua(() => Sync.AdoptFavorites(d["favorites"]))
        }
        ; grid overrides the Lua already has (e.g. calibrated in game before this script existed)
        for side2 in Db.Sides {
            key := "cal_" side2
            if (d.Has(key) && d[key] != "-" && !Cfg.Data["calibration"].Has(side2))
                Cfg.FromLua(() => Sync.AdoptCal(side2, d[key]))
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
                , "res", Cfg.Data["game"]["resW"] "x" Cfg.Data["game"]["resH"])
        else
            return false
        return true
    }

    static FromEvent(evt, e) {
        switch evt {
            case "favourite_changed":
                name := e.Get("operator", "")
                on := e.Get("on", "0") = "1"
                Cfg.FromLua(() => Sync.SetFav(name, on))
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
            return ["NONE", "Lua uses its built-in defaults (no SPM_USER block pasted yet)"]
        if (rev != copied)
            return ["OLD", "Lua has an older config block (rev " rev ") - copy + paste the current one"]
        if Cfg.Pending()
            return ["PENDING", "changes not yet in the Lua - copy + paste the config block"]
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
    static Txt(g, x, y, w, h, text, size := 9, style := "Norm", color := "E8E8E8", bg := "14161A", opts := "") {
        g.SetFont("s" Ui.Pt(size) " " style " c" color, "Segoe UI")
        return g.AddText("x" Ui.S(x) " y" Ui.S(y) " w" Ui.S(w) " h" Ui.S(h) " +0x200 +0x4000 Background" bg " " opts, text)
    }

    static Mono(g, x, y, w, h, text, size := 9, color := "E8E8E8", bg := "14161A") {
        g.SetFont("s" Ui.Pt(size) " Norm c" color, "Consolas")
        return g.AddText("x" Ui.S(x) " y" Ui.S(y) " w" Ui.S(w) " h" Ui.S(h) " +0x4000 Background" bg, text)
    }

    static Rect(g, x, y, w, h, color) {
        return g.AddText("x" Ui.S(x) " y" Ui.S(y) " w" Ui.S(w) " h" Ui.S(h) " Background" color, "")
    }

    ; Clickable flat button. kind: n normal, p primary (green), d danger.
    static Btn(g, x, y, w, h, text, cb, kind := "n") {
        bg := kind = "p" ? Clr.Green : kind = "d" ? "3A2226" : Clr.Panel2
        fg := kind = "p" ? "0B1A10" : kind = "d" ? Clr.Red : Clr.Text
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
            Ui.Paint(t, i = this.Sel ? Clr.Green : Clr.Dim, i = this.Sel ? "1F3B2C" : Clr.Panel2)
    }
    Show(v) {
        for t in this.Btns
            t.Visible := v
    }
}

; Clickable checkbox drawn as text ("☑ label" / "☐ label").
class Toggle {
    __New(g, x, y, w, label, on, cb, bg := "14161A") {
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
        Ui.Paint(this.Ctl, this.On ? Clr.Green : Clr.Dim)
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
        Toast.Gui := g
        Toast.Ctl := c
        g.Show("Hide w" Ui.S(Toast.W) " h" Ui.S(110))
    }

    ; kind: ok | info | warn | error
    static Show(kind, title, l1 := "", l2 := "", l3 := "") {
        if (!Cfg.Get("ui.notifications", 1) || View.Hidden || !IsObject(Toast.Gui))
            return
        key := kind "|" title "|" l1 "|" l2 "|" l3
        if (key = Toast.Last && A_TickCount - Toast.LastMs < 1500)
            return                              ; identical toast just shown: do not spam
        Toast.Last := key, Toast.LastMs := A_TickCount
        col := kind = "ok" ? Clr.Green : kind = "warn" ? Clr.Amber : kind = "error" ? Clr.Red : Clr.Blue
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
        WinSetTransparent(245, "ahk_id " Toast.Gui.Hwnd)
        if !IsObject(Toast.Fn)
            Toast.Fn := ObjBindMethod(Toast, "Hide")
        SetTimer(Toast.Fn, -(kind = "warn" || kind = "error" ? 4200 : 2600))
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
        c["op"] := Ui.Txt(g, 16, 30, pw - 28, f(28), "", f(15), "Bold", Clr.Text, Clr.Panel)
        c["weapon"] := Ui.Txt(g, 16, 60, pw - 28, f(20), "", f(10.5), "Bold", Clr.Text, Clr.Panel)
        c["scope"] := Ui.Txt(g, 16, 82, pw - 28, f(18), "", f(9), "Norm", Clr.Dim, Clr.Panel)
        c["att"] := Ui.Txt(g, 16, 100, pw - 28, f(18), "", f(9), "Norm", Clr.Dim, Clr.Panel)
        c["cal"] := Ui.Txt(g, 16, 120, pw - 28, f(18), "", f(8.5), "Norm", Clr.Mute, Clr.Panel)
        c["dbg"] := Ui.Txt(g, 16, 138, pw - 28, f(18), "", f(8), "Norm", Clr.Mute, Clr.Panel)
        c["status"] := Ui.Txt(g, 16, 160, pw - 28, f(22), "", f(9.5), "Bold", Clr.Green, Clr.Panel)
        Hud.Gui := g
        Hud.Ctl := c
        Hud.PW := pw
        g.Show("Hide w" Ui.S(pw) " h" Ui.S(100))
        WinSetTransparent(Cfg.Num("ui.opacity", 235), "ahk_id " g.Hwnd)
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
        if (statusText != "")
            rows.Push([c["status"], statusText, statusCol, 22])

        ; --- layout ---------------------------------------------------------------
        for n in ["op", "weapon", "scope", "att", "cal", "dbg", "status"]
            c[n].Visible := false
        y := 30
        pw := Hud.PW
        for r in rows {
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
    static Names := ["HOME", "OPERATORS", "LOADOUTS", "CALIBRATION", "HUD", "SETTINGS", "HOTKEYS", "DIAGNOSTICS"]
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
        add(Ui.Txt(g, x + 14, y + 8, w - 28, 18, title, 8, "Bold", Clr.Mute, Clr.Panel))
    }

    static Build() {
        if IsObject(Center.Gui)
            try Center.Gui.Destroy()
        g := Gui("-DPIScale", App.Name)
        g.MarginX := 0, g.MarginY := 0
        g.BackColor := Clr.Bg
        Center.Gui := g
        Center.Ctl := Map(), Center.Pages := Map(), Center.Nav := Map(), Center.Segs := Map(), Center.Toggles := Map()
        Center.Cur := Cfg.Get("ui.page", "HOME")
        if !IndexOf(Center.Names, Center.Cur)
            Center.Cur := "HOME"
        Center.OpSide := Cfg.Get("state.side", "attackers")
        if (Center.Op = "")
            Center.Op := Cfg.Get("state.operator", "")

        ; --- header ---------------------------------------------------------------
        Ui.Rect(g, 0, 0, Center.W, 60, Clr.Panel)
        Ui.Txt(g, 20, 14, 420, 32, "SIEGE PROFILE MANAGER", 13, "Bold", Clr.Text, Clr.Panel)
        Ui.Txt(g, 330, 18, 90, 24, "V" App.Version, 9, "Norm", Clr.Mute, Clr.Panel)
        Center.Ctl["pill"] := Ui.Txt(g, 470, 18, 300, 26, "", 10, "Bold", Clr.Green, Clr.Panel, "Right")
        Ui.Btn(g, 790, 14, 170, 32, "◂  COMPACT HUD", () => View.SetMode("hud"))
        Ui.Rect(g, 0, 60, Center.W, 1, Clr.Line)
        ; --- sidebar --------------------------------------------------------------
        Ui.Rect(g, 0, 61, 176, Center.H - 61, Clr.Panel)
        y := 78
        for name in Center.Names {
            t := Ui.Txt(g, 10, y, 156, 38, "   " name, 10, "Bold", Clr.Dim, Clr.Panel, "+0x100")
            t.OnEvent("Click", Center.OpenPage.Bind(Center, name))
            Center.Nav[name] := t
            y += 42
        }
        Ui.Txt(g, 14, Center.H - 96, 150, 16, "LUA CONFIG", 8, "Bold", Clr.Mute, Clr.Panel)
        Center.Ctl["sync"] := Ui.Txt(g, 14, Center.H - 78, 152, 62, "", 8, "Norm", Clr.Dim, Clr.Panel, "")
        Center.Ctl["sync"].Opt("-0x200 -0x4000")

        Center.BuildHome(g)
        Center.BuildOperators(g)
        Center.BuildLoadouts(g)
        Center.BuildCalibration(g)
        Center.BuildHud(g)
        Center.BuildSettings(g)
        Center.BuildHotkeys(g)
        Center.BuildDiagnostics(g)

        g.OnEvent("Close", (*) => View.SetMode("hud"))
        g.Show("Hide w" Ui.S(Center.W) " h" Ui.S(Center.H))
        Ui.DarkTitle(g)
        Center.OpenPage(Center.Cur)
    }

    static OpenPage(name, *) {
        Center.Cur := name
        for pname, list in Center.Pages
            for c in list
                c.Visible := (pname = name)
        for n, t in Center.Nav
            Ui.Paint(t, n = name ? Clr.Green : Clr.Dim, n = name ? "1F3B2C" : Clr.Panel)
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
        SetText(c["sync"], short "`n" (lc[1] = "OK" ? "" : "Settings > COPY LUA BLOCK"))
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
        Center.Card(add, g, 196, 76, 244, 112, "CONNECTION")
        c["h_conn"] := add(Ui.Txt(g, 210, 100, 216, 26, "", 12, "Bold", Clr.Green, Clr.Panel))
        c["h_c1"] := add(Ui.Txt(g, 210, 130, 216, 18, "", 9, "Norm", Clr.Dim, Clr.Panel))
        c["h_c2"] := add(Ui.Txt(g, 210, 148, 216, 18, "", 9, "Norm", Clr.Dim, Clr.Panel))
        c["h_c3"] := add(Ui.Txt(g, 210, 166, 216, 18, "", 9, "Norm", Clr.Dim, Clr.Panel))
        Center.Card(add, g, 456, 76, 244, 112, "OPERATOR")
        c["h_side"] := add(Ui.Txt(g, 470, 100, 216, 18, "", 9, "Bold", Clr.Dim, Clr.Panel))
        c["h_op"] := add(Ui.Txt(g, 470, 120, 216, 32, "", 16, "Bold", Clr.Text, Clr.Panel))
        c["h_lo"] := add(Ui.Txt(g, 470, 156, 216, 22, "", 9, "Norm", Clr.Dim, Clr.Panel))
        Center.Card(add, g, 716, 76, 244, 112, "CALIBRATION")
        c["h_cal1"] := add(Ui.Txt(g, 730, 104, 216, 20, "", 10, "Bold", Clr.Text, Clr.Panel))
        c["h_cal2"] := add(Ui.Txt(g, 730, 128, 216, 20, "", 10, "Bold", Clr.Text, Clr.Panel))
        c["h_cal3"] := add(Ui.Txt(g, 730, 156, 216, 20, "", 9, "Norm", Clr.Dim, Clr.Panel))
        Center.Card(add, g, 196, 204, 764, 150, "LOADOUT")
        c["h_p1"] := add(Ui.Txt(g, 210, 232, 400, 26, "", 13, "Bold", Clr.Text, Clr.Panel))
        c["h_p2"] := add(Ui.Txt(g, 232, 258, 500, 20, "", 9, "Norm", Clr.Dim, Clr.Panel))
        c["h_s1"] := add(Ui.Txt(g, 210, 290, 400, 26, "", 13, "Bold", Clr.Text, Clr.Panel))
        c["h_s2"] := add(Ui.Txt(g, 232, 316, 500, 20, "", 9, "Norm", Clr.Dim, Clr.Panel))
        c["h_r1"] := add(Ui.Txt(g, 700, 232, 246, 22, "", 9, "Bold", Clr.Dim, Clr.Panel, "Right"))
        c["h_r2"] := add(Ui.Txt(g, 700, 256, 246, 22, "", 9, "Norm", Clr.Dim, Clr.Panel, "Right"))
        Center.Card(add, g, 196, 370, 374, 254, "RECENT CHANGES")
        c["h_recent"] := add(Ui.List(g, 208, 396, 350, 216, ["When", "What"]))
        c["h_recent"].ModifyCol(1, Ui.S(70)), c["h_recent"].ModifyCol(2, Ui.S(266))
        Center.Card(add, g, 586, 370, 374, 254, "QUICK ACTIONS")
        add(Ui.Btn(g, 600, 398, 346, 32, "COPY LUA CONFIG BLOCK", () => Center.CopyBlock(), "p"))
        add(Ui.Btn(g, 600, 436, 346, 32, "TEST GRID DETECTION", () => Center.StartTest()))
        add(Ui.Btn(g, 600, 474, 346, 32, "COPY DIAGNOSTIC REPORT", () => Center.CopyReport()))
        add(Ui.Btn(g, 600, 512, 346, 32, "RUN SETUP WIZARD", () => Wizard.Start()))
        c["h_sync"] := add(Ui.Txt(g, 600, 554, 346, 60, "", 9, "Norm", Clr.Dim, Clr.Panel))
        c["h_sync"].Opt("-0x200 -0x4000")
    }

    static RefreshHome() {
        c := Center.Ctl
        st := Live.Status
        ok := (st = "CONNECTED" || st = "IDLE")
        SetText(c["h_conn"], st = "CONNECTED" ? "● CONNECTED" : st = "IDLE" ? "● CONNECTED (idle)" : st = "LOST" ? "● SIGNAL LOST"
            : st = "MISMATCH" ? "● PROTOCOL MISMATCH" : "● WAITING")
        Ui.Paint(c["h_conn"], ok ? Clr.Green : st = "LOST" ? Clr.Red : Clr.Amber)
        age := Live.AgeMs()
        SetText(c["h_c1"], "Last packet   " (age >= 0 ? Round(age / 1000, 1) " s ago" : "never"))
        SetText(c["h_c2"], "Session   " (Live.Session != "" ? SubStr(Live.Session, 1, 8) : "-") "   #" Live.Seq)
        SetText(c["h_c3"], Live.StatusWhy != "" ? Live.StatusWhy : "Protocol v" (Live.Protocol ? Live.Protocol : "-"))
        has := Live.Data.Count > 0
        fav := has && IndexOf(Cfg.Get("favorites"), Live.OpName()) ? "★ " : ""
        SetText(c["h_side"], has ? Db.SideLabel(Live.Side()) " SIDE" : "-")
        SetText(c["h_op"], has ? fav StrUpper(Live.OpName()) : "-")
        SetText(c["h_lo"], has ? "Loadout  " Live.Get("loadout", "-") : "")
        for side, n in Map("attackers", "h_cal1", "defenders", "h_cal2") {
            SetText(c[n], Db.SideLabel(side) "   " Calib.Long(side))
            Ui.Paint(c[n], Calib.Color(side))
        }
        SetText(c["h_cal3"], Cfg.Get("game.resW") "×" Cfg.Get("game.resH") "  ·  " Calib.Mode())
        active := Live.Slot()
        for kind, ids in Map("primary", ["h_p1", "h_p2"], "secondary", ["h_s1", "h_s2"]) {
            w := Live.Get(kind, "-")
            isA := (active = kind)
            SetText(c[ids[1]], has ? (isA ? "►  " : "    ") StrUpper(kind) "   " w : "")
            Ui.Paint(c[ids[1]], isA ? Clr.Text : Clr.Dim)
            if (has && w != "NONE" && w != "-")
                SetText(c[ids[2]], "Sight " Center.A(Live.Att(kind, "scope")) "   ·   Barrel " Center.A(Live.Att(kind, "barrel"))
                    . "   ·   Grip " Center.A(Live.Att(kind, "grip")))
            else
                SetText(c[ids[2]], "")
        }
        SetText(c["h_r1"], has ? "ACTIVE SLOT  " StrUpper(active) : "")
        SetText(c["h_r2"], has ? (Live.Get("enabled") = "1" ? "System ON" : "System OFF") : "")
        Ui.Paint(c["h_r2"], Live.Get("enabled") = "1" ? Clr.Green : Clr.Red)
        lv := c["h_recent"]
        lv.Delete()
        loop Live.Recent.Length {
            e := Live.Recent[Live.Recent.Length - A_Index + 1]
            lv.Add("", e["t"], e["text"])
        }
        lc := Sync.LuaConfig()
        SetText(c["h_sync"], lc[2])
        Ui.Paint(c["h_sync"], lc[1] = "OK" ? Clr.Green : lc[1] = "UNKNOWN" ? Clr.Dim : Clr.Amber)
    }

    static A(v) => v = "" ? "n/a" : v = "NONE" ? "none" : v

    static CopyBlock() {
        Center.Gui.Opt("+OwnDialogs")
        rev := LuaBlock.Copy()
        Toast.Show("ok", "✓ CONFIGURATION SAVED", "Lua config block copied", "Paste it over the SPM_USER block", "in the G HUB script")
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
            msg := same ? "● Matches the loadout the game is using." : "● Differs from the game: use the in-game hotkeys, RALT+RMB, or paste the config block."
            Ui.Paint(c["o_sync"], same ? Clr.Green : Clr.Amber)
        } else {
            msg := "Changes are saved here and reach the game through the config block (Settings)."
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
        Toast.Show("ok", "STARTING OPERATOR", StrUpper(f["op"]["name"]), "Applies when the config block is loaded", "")
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
            , ["connection", "Connection status"], ["calibration", "Calibration"], ["debug", "Debug information"]] {
            tg := Toggle(g, 196 + Mod(i - 1, 2) * 260, 354 + ((i - 1) // 2) * 30, 250, pair[2], false, Center.SecSet.Bind(Center, pair[1]))
            Center.Toggles["s_" pair[1]] := tg
            add(tg.Ctl)
        }
        Center.Toggles["h_notif"] := Toggle(g, 196, 460, 300, "Show notifications", true, (v) => (Cfg.Set("ui.notifications", v), View.Changed()))
        add(Center.Toggles["h_notif"].Ctl)
        add(Ui.Btn(g, 196, 504, 200, 32, "TEST NOTIFICATION", () => Toast.Show("ok", "✓ OPERATOR DETECTED", "ZOFIA", "M762", "SUPPRESSOR • HORIZONTAL"), "p"))
        add(Ui.Btn(g, 406, 504, 200, 32, "RESET HUD SETTINGS", () => Center.HudReset()))
        add(Ui.Txt(g, 196, 552, 700, 40, "The compact HUD is click-through and never takes focus. Custom position: enter screen pixels and press APPLY.", 9, "Norm", Clr.Mute))
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
        for key in ["operator", "weapon", "attachments", "connection", "calibration", "debug"]
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
        add(Ui.Btn(g, 744, 248, 216, 32, "START CALIBRATION", () => Calib.Start(Calib.Side), "p"))
        add(Ui.Btn(g, 744, 286, 216, 30, "CANCEL", () => Calib.Cancel()))
        add(Ui.Btn(g, 744, 322, 216, 30, "RESET TO PRESET", () => Calib.ResetSide(Calib.Side), "d"))
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
            : (Calib.Err != "" ? "⚠ " Calib.Err : "Open the operator selector in Siege, press START, then capture the two corners."))
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
        SetText(c["t7"], "Click a tile in Siege with RSHIFT + left click. If both readings agree the grid is calibrated correctly.")
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
            Ui.Paint(Center.Cells[idx], Clr.Green, "1F3B2C")
    }

    ; ==========================================================================
    ; SETTINGS
    ; ==========================================================================
    static BuildSettings(g) {
        add := Center.Reg.Bind(Center, "SETTINGS")
        c := Center.Ctl
        add(Ui.Txt(g, 196, 76, 300, 20, "GAME PROFILE", 8, "Bold", Clr.Mute))
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
        Center.Toggles["s_not"] := Toggle(g, 596, 168, 300, "Show notifications", true, (v) => (Center.Guard ? 0 : (Cfg.Set("ui.notifications", v), View.Changed())))
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
        add(Ui.Btn(g, 212, 574, 300, 34, "COPY LUA CONFIG BLOCK", () => Center.CopyBlock(), "p"))
        add(Ui.Txt(g, 526, 574, 424, 34, "G HUB → script → select everything between the SPM_USER markers → paste.", 8, "Norm", Clr.Mute, Clr.Panel))
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
        Center.Toggles["s_not"].Set(Cfg.Get("ui.notifications", 1))
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
        SetText(c["s_lua2"], "The G HUB Lua cannot read files, so your saved settings reach it as a small config block. "
            . "Paste it once; it is stored in the script and survives G HUB / Windows restarts. Copy a new one after changing settings here.")
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
        SetText(c["k_msg"], lua ? "Manager hotkeys are read by the G HUB Lua: a change is sent with the config block (Settings > COPY LUA CONFIG BLOCK) and takes effect when the script reloads."
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
            Toast.Show("ok", "✓ BINDING CHANGED", r["label"], StrUpper(md) " + " Hk.Btns[btn], "Copy the Lua block to apply")
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
        c["d_text"] := add(Ui.Mono(g, 196, 76, 764, 352, "", 9, Clr.Text, Clr.Bg))
        add(Ui.Btn(g, 196, 438, 220, 32, "COPY DIAGNOSTIC REPORT", () => Center.CopyReport(), "p"))
        add(Ui.Btn(g, 424, 438, 150, 32, "CLEAR LOG", () => (Diag.Lines := [], Center.RefreshDiag())))
        add(Ui.Txt(g, 586, 442, 374, 24, "Report contains no paths or personal data.", 8, "Norm", Clr.Mute))
        add(Ui.Txt(g, 196, 480, 300, 16, "EVENT LOG", 8, "Bold", Clr.Mute))
        c["d_log"] := add(Ui.List(g, 196, 498, 764, 126, ["Log"]))
        c["d_log"].ModifyCol(1, Ui.S(740))
    }

    static RefreshDiag() {
        c := Center.Ctl
        SetText(c["d_text"], Diagnostics.Text())
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
    static Geometry(side) {
        pre := Db.Presets.Has(Calib.PresetName() "|" side) ? Db.Presets[Calib.PresetName() "|" side] : Db.Presets["1920x1080|" side]
        g := Map("padx", pre["padx"], "pady", pre["pady"])
        src := Calib.HasCal(side) ? Cfg.Get("calibration")[side] : pre
        for k in ["tlx", "tly", "brx", "bry"]
            g[k] := src[k]
        return g
    }

    static Status(side) {
        if (Calib.Active && Calib.Side = side)
            return "CALIBRATING"
        if (Calib.Err != "" && Calib.Side = side)
            return "ERROR"
        return Calib.HasCal(side) ? "CALIBRATED" : "NOT CALIBRATED (PRESET)"
    }
    static Short(side) {
        s := Calib.Status(side)
        return s = "CALIBRATED" ? "✓" : s = "CALIBRATING" ? "…" : s = "ERROR" ? "✗" : "⚠"
    }
    static Long(side) {
        s := Calib.Status(side)
        return s = "CALIBRATED" ? "✓ CALIBRATED" : s = "CALIBRATING" ? "… CALIBRATING" : s = "ERROR" ? "✗ ERROR" : "⚠ PRESET"
    }
    static Color(side) {
        s := Calib.Status(side)
        return s = "CALIBRATED" ? Clr.Green : s = "ERROR" ? Clr.Red : Clr.Amber
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
        Calib.AddPoint(x / A_ScreenWidth, y / A_ScreenHeight)
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
        Calib.Store(Calib.Side, a[1], a[2], b[1], b[2])
        Cfg.Dirty()
        Toast.Show("ok", "✓ CALIBRATION COMPLETE", Db.SideLabel(Calib.Side) " GRID", "Copy the Lua block to use it in game", "")
    }

    static Store(side, tlx, tly, brx, bry) {
        Cfg.Data["calibration"][side] := Map("tlx", tlx, "tly", tly, "brx", brx, "bry", bry, "res", Calib.PresetName())
        return true
    }

    static ResetSide(side) {
        Cfg.Data["calibration"].Delete(side)
        Cfg.Dirty()
        Calib.Err := ""
        Toast.Show("info", "CALIBRATION RESET", Db.SideLabel(side) " grid uses the preset", "Copy the Lua block to apply", "")
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
        Calib.Pts.Push([x, y])
        Calib.Step := Min(2, step + 1)
        View.Changed()
    }
    static OnLuaComplete(sideLabel, tlx, tly, brx, bry) {
        side := Db.SideFromLua(sideLabel)
        Calib.Side := side
        Calib.Active := false, Calib.Pts := [], Calib.Err := ""
        Cfg.FromLua(() => Calib.Store(side, tlx, tly, brx, bry))
        View.Changed()
    }
    static OnLuaFailed(sideLabel, reason) {
        Calib.Active := false, Calib.Pts := []
        Calib.Err := (reason = "cancelled") ? "" : reason
        View.Changed()
    }
    static OnLuaReset(sideLabel) {
        side := Db.SideFromLua(sideLabel)
        Cfg.FromLua(() => Calib.DropCal(side))
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
        Calib.Testing := on ? true : false
        if !IsObject(Calib.Fn)
            Calib.Fn := ObjBindMethod(Calib, "Tick")
        SetTimer(Calib.Fn, Calib.Testing ? 60 : "Off")
        if !Calib.Testing
            Calib.Live := Map()
        View.Changed()
    }

    static Tick() {
        MouseGetPos(&x, &y)
        nx := x / A_ScreenWidth, ny := y / A_ScreenHeight
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
        ["ATTACHMENTS", "nextGrip", "Next grip", "lalt", 1],
        ["CALIBRATION", "toggleCalibration", "Calibrate: start / set corner", "rshift", 4], ["CALIBRATION", "resetCalibration", "Cancel / reset calibration", "rshift", 5],
        ["SYSTEM", "toggleSystem", "System on/off", "ralt", 5], ["SYSTEM", "toggleDebug", "Debug on/off", "ralt", 4],
        ["SYSTEM", "redraw", "Redraw / resend state", "ralt", 1], ["SYSTEM", "toggleRecoilTune", "Recoil tune on/off", "lshift", 1]
    ]
    static AhkDefaults := Map("mode", "F8", "visible", "F9", "capture", "F7", "profiles", "F10")
    static AhkLabels := Map("mode", "Compact HUD / Control centre", "visible", "Show / hide everything"
        , "capture", "Capture calibration point", "profiles", "Copy tuned recoil profiles")
    static AhkGroups := Map("mode", "HUD", "visible", "HUD", "capture", "CALIBRATION", "profiles", "SYSTEM")
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
        for id in ["mode", "visible", "capture", "profiles"] {
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
            , "capture", (*) => Calib.Capture(), "profiles", (*) => Profiles.Copy())
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
; 19. DIAGNOSTICS REPORT  (no paths, no user names, nothing private)
; ------------------------------------------------------------------------------
class Diagnostics {
    static Row(label, value) => Format("{:-22s}{}", label, value) "`n"

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
        t .= "`nLOADOUT`n"
        t .= Diagnostics.Row("PRIMARY", has ? Live.Get("primary", "-") : "-")
        t .= Diagnostics.Row("SECONDARY", has ? Live.Get("secondary", "-") : "-")
        t .= Diagnostics.Row("SCOPE", has ? Live.Get("scope", "-") : "-")
        t .= Diagnostics.Row("BARREL", has ? Live.Get("barrel", "-") : "-")
        t .= Diagnostics.Row("GRIP", has ? Live.Get("grip", "-") : "-")
        t .= Diagnostics.Row("NAMED LOADOUT", has ? Live.Get("loadout", "-") : "-")
        t .= "`nCONFIG`n"
        t .= Diagnostics.Row("CONFIG VERSION", App.CfgVersion)
        t .= Diagnostics.Row("CONFIG STATUS", (Cfg.Status = "VALID" || Cfg.Status = "NEW") ? "✓ " (Cfg.Status = "NEW" ? "NEW" : "VALID") : "⚠ " Cfg.StatusMsg)
        lc := Sync.LuaConfig()
        t .= Diagnostics.Row("LUA CONFIG", lc[1] = "OK" ? "✓ IN SYNC" : "⚠ " lc[2])
        t .= Diagnostics.Row("DATABASE", !has ? "-" : Live.Get("dbrev", "") = Db.Rev ? "✓ MATCHES LUA (" Db.Rev ")" : "⚠ MISMATCH (lua " Live.Get("dbrev", "?") " / app " Db.Rev ")")
        t .= Diagnostics.Row("APP VERSION", App.Version)
        return t
    }

    ; Discord-ready: fenced code block.
    static Report() => "``````" "`n" "SIEGE PROFILE MANAGER " App.Version " - DIAGNOSTICS`n`n" Diagnostics.Text() "``````"
}

; ------------------------------------------------------------------------------
; 20. FIRST-RUN SETUP WIZARD  (16 steps; every value is validated before it is saved)
; ------------------------------------------------------------------------------
class Wizard {
    static Gui := ""
    static Ctl := Map()
    static Step := 1
    static Visible := false
    static Steps := []

    static Init() {
        Wizard.Steps := [
            Map("t", "Welcome", "k", "info", "b", "This wizard sets up Siege Profile Manager once.`n`nYour answers are stored on this PC and survive restarts. You can re-run it any time from HOME > RUN SETUP WIZARD."),
            Map("t", "Resolution", "k", "res", "b", "Your in-game resolution (width x height). Press AUTO to use this monitor."),
            Map("t", "Mouse DPI", "k", "num", "p", "game.dpi", "lo", 50, "hi", 32000, "b", "The DPI of your mouse (as set in G HUB)."),
            Map("t", "Horizontal sensitivity", "k", "num", "p", "game.sensH", "lo", 0.1, "hi", 100, "b", "Siege horizontal mouse sensitivity."),
            Map("t", "Vertical sensitivity", "k", "num", "p", "game.sensV", "lo", 0.1, "hi", 100, "b", "Siege vertical mouse sensitivity."),
            Map("t", "Field of view", "k", "num", "p", "game.fov", "lo", 40, "hi", 140, "b", "Siege FOV (60 - 90)."),
            Map("t", "ADS sensitivity", "k", "num", "p", "game.ads", "lo", 1, "hi", 200, "b", "Siege ADS mouse sensitivity modifier."),
            Map("t", "Preferred scope", "k", "pref", "p", "scope", "b", "Used whenever a weapon is loaded for the first time. AUTO = the first sight the weapon offers."),
            Map("t", "Preferred barrel", "k", "pref", "p", "barrel", "b", "Used when the weapon can equip it; otherwise the next best barrel is chosen."),
            Map("t", "Preferred grip", "k", "pref", "p", "grip", "b", "Used when the weapon can equip it."),
            Map("t", "Attacker calibration", "k", "cal", "side", "attackers", "b", "Open the ATTACKER operator selector in Siege. Press START, then hover the OUTER top-left corner of the first tile and press the capture key, then the OUTER bottom-right corner of the last tile (row 7, column 7) and press it again."),
            Map("t", "Defender calibration", "k", "cal", "side", "defenders", "b", "Same as before, on the DEFENDER selector."),
            Map("t", "Detection test", "k", "test", "b", "Move the cursor over the operator selector. The name below must match the tile under the cursor. Use the side button to test the other grid."),
            Map("t", "HUD position", "k", "hud", "b", "Where the compact HUD sits on screen. You can fine-tune everything later on the HUD page."),
            Map("t", "Save configuration", "k", "save", "b", "Everything is saved on this PC automatically. To use it inside G HUB, copy the Lua config block and paste it over the SPM_USER block in the script."),
            Map("t", "Finished", "k", "done", "b", "You are ready. F8 switches between the compact HUD and the control centre, F9 hides everything.")
        ]
    }

    static Start() {
        if !Wizard.Steps.Length
            Wizard.Init()
        if IsObject(Wizard.Gui)
            try Wizard.Gui.Destroy()
        g := Gui("+AlwaysOnTop -DPIScale", "Siege Profile Manager - Setup")
        g.MarginX := 0, g.MarginY := 0
        g.BackColor := Clr.Bg
        Wizard.Gui := g
        c := Map()
        Ui.Rect(g, 0, 0, 640, 84, Clr.Panel)
        c["prog"] := Ui.Mono(g, 24, 14, 592, 20, "", 11, Clr.Green, Clr.Panel)
        c["cnt"] := Ui.Txt(g, 24, 42, 592, 24, "", 10, "Bold", Clr.Dim, Clr.Panel)
        c["title"] := Ui.Txt(g, 24, 100, 592, 34, "", 16, "Bold", Clr.Text, Clr.Bg)
        c["body"] := Ui.Txt(g, 24, 140, 592, 100, "", 10, "Norm", Clr.Dim, Clr.Bg)
        c["body"].Opt("-0x200 -0x4000")
        c["in"] := Ui.Edit(g, 24, 252, 240, 28)
        c["dd"] := Ui.Drop(g, 24, 252, 300, [])
        c["b1"] := Ui.Btn(g, 24, 296, 260, 34, "", () => Wizard.Action(), "p")
        c["ex"] := Ui.Mono(g, 24, 344, 592, 76, "", 10, Clr.Text, Clr.Bg)
        c["back"] := Ui.Btn(g, 24, 430, 110, 34, "◂ BACK", () => Wizard.Go(-1))
        c["skip"] := Ui.Btn(g, 380, 430, 110, 34, "SKIP", () => Wizard.Go(1, true))
        c["next"] := Ui.Btn(g, 506, 430, 110, 34, "NEXT ▸", () => Wizard.Go(1), "p")
        Wizard.Ctl := c
        g.OnEvent("Close", (*) => Wizard.Close())
        Wizard.Step := 1
        Wizard.Visible := true
        g.Show("w" Ui.S(640) " h" Ui.S(480))
        Ui.DarkTitle(g)
        Wizard.Render()
    }

    static Close() {
        Calib.SetTesting(false)
        Wizard.Visible := false
        try Wizard.Gui.Hide()
    }

    static Render() {
        c := Wizard.Ctl
        st := Wizard.Steps[Wizard.Step]
        n := Wizard.Steps.Length
        filled := Round(Wizard.Step / n * 24)
        SetText(c["prog"], "SETUP   " Wizard.Bar(filled, 24))
        SetText(c["cnt"], Wizard.Step " / " n)
        SetText(c["title"], st["t"])
        SetText(c["body"], st["b"])
        k := st["k"]
        c["in"].Visible := (k = "num" || k = "res")
        c["dd"].Visible := (k = "pref" || k = "hud")
        c["b1"].Visible := (k = "cal" || k = "save" || k = "res")
        c["skip"].Visible := (k = "cal" || k = "test")
        c["back"].Visible := Wizard.Step > 1
        SetText(c["next"], Wizard.Step = n ? "FINISH ✓" : "NEXT ▸")
        Calib.SetTesting(k = "test")
        if (k = "num")
            c["in"].Text := Cfg.Get(st["p"])
        else if (k = "res") {
            c["in"].Text := Cfg.Get("game.resW") "x" Cfg.Get("game.resH")
            SetText(c["b1"], "AUTO (THIS MONITOR)")
        } else if (k = "pref") {
            items := st["p"] = "scope" ? Db.AllScopes() : st["p"] = "barrel" ? LoadoutMgr.BarrelChain : LoadoutMgr.GripChain
            c["dd"].Delete(), c["dd"].Add(items)
            c["dd"].Choose(IndexOf(items, Cfg.Get("prefs." st["p"])) || 1)
        } else if (k = "hud") {
            items := ["Top Left", "Top Right", "Bottom Left", "Bottom Right"]
            c["dd"].Delete(), c["dd"].Add(items)
            c["dd"].Choose(IndexOf(items, Cfg.Get("ui.hudPos")) || 2)
        } else if (k = "cal") {
            Calib.Side := st["side"]
            SetText(c["b1"], "START CALIBRATION")
        } else if (k = "save")
            SetText(c["b1"], "COPY LUA CONFIG BLOCK")
        Wizard.Refresh()
    }

    static Bar(filled, total) {
        s := ""
        loop total
            s .= (A_Index <= filled) ? "█" : "░"
        return s
    }

    ; Live parts of a step (calibration status, detection readout).
    static Refresh() {
        if !Wizard.Visible
            return
        c := Wizard.Ctl
        st := Wizard.Steps[Wizard.Step]
        k := st["k"]
        if (k = "cal") {
            side := st["side"]
            pts := ""
            for i, p in Calib.Pts
                pts .= (i = 1 ? "TOP LEFT      " : "BOTTOM RIGHT  ") Format("{:.4f}, {:.4f}", p[1], p[2]) "`n"
            SetText(c["ex"], "STATUS  " Calib.Long(side) "`n" pts (Calib.Err != "" ? "⚠ " Calib.Err : "Capture key: " Cfg.Get("hotkeys.capture")))
        } else if (k = "test") {
            d := Calib.Live
            if (!d.Count)
                SetText(c["ex"], "Move the cursor over the operator selector...")
            else
                SetText(c["ex"], Format("ROW {}   COLUMN {}`nDETECTED  {}`n{}", d["row"] ? d["row"] : "-", d["col"] ? d["col"] : "-"
                    , d["name"] != "" ? StrUpper(d["name"]) : "-", d["name"] != "" ? "✓ GRID MATCH" : "no tile here"))
        } else if (k = "save") {
            lc := Sync.LuaConfig()
            SetText(c["ex"], "Lua: " lc[2])
        } else
            SetText(c["ex"], "")
    }

    static Action() {
        k := Wizard.Steps[Wizard.Step]["k"]
        if (k = "cal")
            Calib.Start(Wizard.Steps[Wizard.Step]["side"])
        else if (k = "res") {
            Wizard.Ctl["in"].Text := A_ScreenWidth "x" A_ScreenHeight
        } else if (k = "save") {
            Cfg.SaveNow()
            LuaBlock.Copy()
            Toast.Show("ok", "✓ CONFIGURATION SAVED", "Lua config block copied", "Paste it into the G HUB script", "")
            Wizard.Refresh()
        }
    }

    ; dir +1/-1. Going forward validates and stores the current step first (unless skipping).
    static Go(dir, skipping := false) {
        st := Wizard.Steps[Wizard.Step]
        c := Wizard.Ctl
        if (dir > 0 && !skipping) {
            k := st["k"]
            if (k = "num") {
                v := Trim(c["in"].Text)
                if !(IsNumber(v) && v + 0 >= st["lo"] && v + 0 <= st["hi"]) {
                    Toast.Show("warn", "⚠ INVALID VALUE", "Enter a number between " st["lo"] " and " st["hi"], "", "")
                    return
                }
                Cfg.Set(st["p"], v + 0)
            } else if (k = "res") {
                if !RegExMatch(Trim(c["in"].Text), "i)^(\d{3,5})\s*[x×]\s*(\d{3,5})$", &m) {
                    Toast.Show("warn", "⚠ INVALID RESOLUTION", "Use the form 3440x1440", "", "")
                    return
                }
                Cfg.Set("game.resW", Integer(m[1])), Cfg.Set("game.resH", Integer(m[2]))
            } else if (k = "pref")
                Cfg.Set("prefs." st["p"], c["dd"].Text)
            else if (k = "hud") {
                Cfg.Set("ui.hudPos", c["dd"].Text)
                View.RebuildSoon()
            } else if (k = "cal" && Calib.Active)
                Calib.Cancel()
        }
        if (dir > 0 && Wizard.Step = Wizard.Steps.Length) {
            Cfg.Set("setup.done", 1)
            Cfg.SaveNow()
            Wizard.Close()
            View.Changed()
            return
        }
        Wizard.Step := Clamp(Wizard.Step + dir, 1, Wizard.Steps.Length)
        Wizard.Render()
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
            View.RebuildFn := ObjBindMethod(UI, "DoRebuild")
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
Ui.Recalc()
DbgListener.Init()
Hk.RegisterAll()
View.Start()
SlotSync.Set("PRIMARY", false)                       ; baseline: lock key OFF = primary
SetTimer(() => Live.Poll(), 15)                  ; receives packets (DBWIN handshake needs quick service)
SetTimer(() => Live.Tick(), 1000)                ; link health
SetTimer(() => Hud.KeepOnTop(), 2000)            ; borderless games can steal the Z-order
SetTimer(() => (Center.Visible && (Center.Cur = "HOME" || Center.Cur = "DIAGNOSTICS") ? Center.RefreshPage() : 0), 1000)
OnExit((*) => Cfg.SaveNow())

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
Mute|MP5K,M590A1|P226 MK 25,SMG-11|MP5K|P226 MK 25|0
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
Warden|M590A1,MPX|P-10C,SMG-12|MPX|P-10C|0
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
3440x1440|defenders|0.2140|0.1830|0.8170|0.7820|0.0030|0.0060
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
