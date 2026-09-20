--[[
    SIEGE PROFILE MANAGER  -  Logitech G HUB Lua (single file)
    Operator click-detection, loadout manager, favorites, grid calibration.
    Vora recoil macro merged in (section 5b/14b): while ADS + firing, the
    selected operator's primary weapon applies its RECOIL_PROFILES pull-down.
    Operator selection, on/off (RALT+MB5) and loadout come from this manager.

    DEFAULT CONTROLS (modifier + mouse button; edit CONFIG.input.keybinds)
      RSHIFT + Left click on operator tile ... auto-detect operator
      RCTRL  + MB5 / MB4 / LMB ................ next / prev operator / toggle favorite
      LCTRL  + MB5 / MB4 / LMB ................ next / prev favorite / attacker-defender page
      LALT   + MB5 / MB4 / LMB ................ next primary / next secondary / next grip
      LSHIFT + MB5 / MB4 ...................... next scope / next barrel
      RALT   + MB5 / MB4 / LMB ................ system on-off / debug on-off / redraw
      LSHIFT + LMB ............................ recoil tune on-off
      RSHIFT + MB4 / MB5 ...................... start-cancel calibration / reset calibration
]]

EnablePrimaryMouseButtonEvents(true)

--=====================================================================
-- 1. CONFIGURATION  (everything you normally edit lives here)
--=====================================================================
local CONFIG = {
    dpi = 1600,

    sensitivity = {
        horizontal = 4,
        vertical   = 4,
    },

    fov = 84,

    ads = {
        default  = 52,
        perScope = {            -- optional per-scope overrides, keyed by sight name
            -- ["MAGNIFIED C"] = 52,
            -- ["TELESCOPIC A"] = 52,
        },
    },

    resolution  = { width = 3440, height = 1440 },
    aspectRatio = "21:9",

    -- Attachment preferences. For each field the FIRST entry the weapon can
    -- actually equip (see WEAPON_LIST) is used as the default; an operator's
    -- own `default` attachment (if the weapon offers it) wins over this. The
    -- chain never invents an attachment: entries a weapon does not offer are
    -- skipped, so a weapon with no suppressor falls back to the next barrel
    -- and a weapon with no grip slot ends up with NONE.
    attachments = {
        preferred = {
            barrel = { "COMPENSATOR", "SUPPRESSOR", "FLASH HIDER", "MUZZLE BRAKE",
                       "EXTENDED BARREL", "NONE" },   -- compensator first: the recoil macro needs it
            grip   = { "HORIZONTAL", "VERTICAL", "ANGLED", "NONE" },
            scope  = {},   -- empty = the first scope listed for the weapon
        },
    },

    startup = {
        enabled = true,
        debug   = false,
        side    = "attackers",  -- "attackers" or "defenders"
    },

    input = {
        selectModifier = "rshift",  -- hold this while left-clicking an operator tile
        selectButton   = 1,         -- 1 = left mouse button
        debounceMs     = 150,
        -- One modifier + one mouse button per action.
        -- Modifiers: lctrl rctrl lalt ralt lshift rshift
        -- Buttons as OnEvent reports them: 1 left, 2 RIGHT, 3 MIDDLE, 4 back, 5 forward.
        -- (The defaults below only use 1, 4 and 5.)
        keybinds = {
            nextOperator      = { mod = "rctrl",  button = 5 },
            prevOperator      = { mod = "rctrl",  button = 4 },
            toggleFavorite    = { mod = "rctrl",  button = 1 },
            nextFavorite      = { mod = "lctrl",  button = 5 },
            prevFavorite      = { mod = "lctrl",  button = 4 },
            toggleSide        = { mod = "lctrl",  button = 1 },
            nextPrimary       = { mod = "lalt",   button = 5 },
            nextSecondary     = { mod = "lalt",   button = 4 },
            nextGrip          = { mod = "lalt",   button = 1 },
            nextScope         = { mod = "lshift", button = 5 },
            nextBarrel        = { mod = "lshift", button = 4 },
            toggleSystem      = { mod = "ralt",   button = 5 },
            toggleDebug       = { mod = "ralt",   button = 4 },
            redraw            = { mod = "ralt",   button = 1 },
            toggleRecoilTune  = { mod = "lshift", button = 1 },
            toggleCalibration = { mod = "rshift", button = 4 },
            resetCalibration  = { mod = "rshift", button = 5 },
        },
        -- Keys used while recoil tuning is active (MB5 / MB4 alone = raise / lower).
        -- Letter keys such as Shift+P are impossible: G HUB Lua only sees modifier
        -- keys and mouse buttons.
        tune = {
            -- mod = "none" means the button alone. Any of lshift/rshift/lalt/ralt also works,
            -- e.g. up = { mod = "lshift", button = 5 } (the on-screen prompts keep saying MB5/MB4).
            up    = { mod = "none",   button = 5 },   -- raise the current value
            down  = { mod = "none",   button = 4 },   -- lower the current value
            next  = { mod = "lalt",   button = 5 },   -- next step (last step: finish)
            back  = { mod = "lalt",   button = 4 },   -- previous step
            reset = { mod = "lshift", button = 4 },   -- reset this weapon
        },
    },

    -- PHYSICAL grid geometry only, in NORMALIZED screen coordinates (0..1), per
    -- resolution and per side. Column/row counts and which operator sits in
    -- which tile live in OPERATOR_GRID below, not here.
    -- ALL VALUES BELOW ARE UNVERIFIED PLACEHOLDERS. Calibrate attackers and
    -- defenders separately (RSHIFT+MB4), then paste the printed numbers here.
    grid = {
        activePreset    = "auto",       -- "auto" = "<width>x<height>" from CONFIG.resolution
        fallbackPreset  = "1920x1080",
        -- Calibration always spans the WHOLE 7x7 physical grid, empty cells included:
        -- "corners": outer top-left corner of cell (1,1), then outer bottom-right
        --            corner of cell (7,7)
        -- "centers": centre of cell (1,1), then centre of cell (7,7)
        calibrationMode = "corners",
        presets = {
            ["1920x1080"] = {
                attackers = { padding = { x = 0.004, y = 0.006 },
                              topLeft = { x = 0.116, y = 0.183 }, bottomRight = { x = 0.926, y = 0.782 } },
                defenders = { padding = { x = 0.004, y = 0.006 },
                              topLeft = { x = 0.116, y = 0.183 }, bottomRight = { x = 0.926, y = 0.782 } },
            },
            ["2560x1440"] = {
                attackers = { padding = { x = 0.004, y = 0.006 },
                              topLeft = { x = 0.116, y = 0.183 }, bottomRight = { x = 0.926, y = 0.782 } },
                defenders = { padding = { x = 0.004, y = 0.006 },
                              topLeft = { x = 0.116, y = 0.183 }, bottomRight = { x = 0.926, y = 0.782 } },
            },
            ["3440x1440"] = {   -- attackers: measured with RSHIFT+MB4 calibration; defenders: estimate
                attackers = { padding = { x = 0.003, y = 0.006 },
                              topLeft = { x = 0.1399, y = 0.2689 }, bottomRight = { x = 0.4225, y = 0.8881 } },
                defenders = { padding = { x = 0.003, y = 0.006 },
                              topLeft = { x = 0.214, y = 0.183 }, bottomRight = { x = 0.817, y = 0.782 } },
            },
        },
    },

    recoil = {
        enabled       = true,
        aimButton     = 3,   -- hold to ADS (right mouse)
        fireButton    = 1,   -- left mouse (IsMouseButtonPressed number)
        aimEvent      = 2,   -- OnEvent number of the right mouse button press (starts the loop too)
        tickMs        = 7,
        -- Vora profiles were tuned for these settings; movement is rescaled so
        -- the in-game pull is the same at your dpi * sensitivity.
        reference     = { dpi = 800, horizontal = 11, vertical = 11 },
        requireBarrel = "COMPENSATOR",   -- profile only applies with this barrel (nil = any)
        gain          = 1.0,             -- overall pull strength multiplier (tune mode edits this)
    },

    -- Follows the weapon slot you pick in game with the 1 / 2 keys. G HUB Lua cannot see
    -- number keys, so SiegeOverlay.ahk watches them and sets a lock key: OFF = primary,
    -- ON = secondary. A manual slot change (LALT+MB5 / LALT+MB4) stays until the next 1 / 2.
    slotSync = {
        enabled = true,
        lockKey = "scrolllock",    -- capslock / numlock / scrolllock; must match SLOT_LOCK in the .ahk
    },

    -- Live state export for SiegeOverlay.ahk (display only, nothing is read back).
    -- G HUB Lua has no file access (io is blocked) and its console is not logged
    -- to disk, so the state goes out through OutputDebugMessage (Windows debug
    -- output), which SiegeOverlay.ahk listens to.
    overlay = {
        enabled = true,
    },

    ui = {
        unicode        = true, -- false = pure ASCII box drawing
        width          = 90,
        clearLog       = true,
        showControls   = true,
        showFavorites  = true,
        favoritesCols  = 3,
        debugLines     = 14,
    },
}

--=====================================================================
-- 2. CONSTANTS
--=====================================================================
local SIDE_ORDER = { "attackers", "defenders" }
local SIDE_LABEL = { attackers = "ATTACKER", defenders = "DEFENDER" }
local MODIFIERS  = { "lctrl", "rctrl", "lalt", "ralt", "lshift", "rshift" }
local RAW_COORD_MAX = 65535            -- G HUB absolute mouse range is 0..65535
local EVENT_MOUSE_PRESSED   = "MOUSE_BUTTON_PRESSED"
local EVENT_PROFILE_ACTIVE  = "PROFILE_ACTIVATED"
local SLOT_KINDS = { "primary", "secondary" }
local ATTACHMENT_FIELDS = { "scope", "barrel", "grip" }
local ATTACHMENT_KEY    = { scope = "scopes", barrel = "barrels", grip = "grips" }
-- Numbers as OnEvent reports them (seen in the RAW log): 1 left, 2 right, 3 middle, 4 back, 5 forward.
-- (IsMouseButtonPressed() numbers differ: 2 = middle, 3 = right.)
local BUTTON_NAME = { [1] = "LMB", [2] = "RMB", [3] = "MMB", [4] = "MB4", [5] = "MB5" }
local CELL_EMPTY   = "EMPTY"   -- also accepted as "empty": false or nil
local CELL_UNKNOWN = "?"       -- tile position not verified yet

-- Every attachment name allowed anywhere in this file. Startup validation
-- flags any name used in a class, weapon, operator, default, profile or
-- preference list that is not in here. Being listed here does NOT mean any
-- weapon can equip it; that comes from the weapon/class lists below.
local ATTACHMENT_CATALOGUE = {
    scope  = { "IRON SIGHT", "CUSTOM SIGHT",
               "RED DOT A", "RED DOT B", "RED DOT C",
               "HOLO A", "HOLO B", "HOLO C", "HOLO D",
               "REFLEX A", "REFLEX B", "REFLEX C", "REFLEX D",
               "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C",
               "TELESCOPIC A", "TELESCOPIC B" },
    barrel = { "NONE", "SUPPRESSOR", "COMPENSATOR", "FLASH HIDER", "MUZZLE BRAKE", "EXTENDED BARREL" },
    grip   = { "NONE", "VERTICAL", "ANGLED", "HORIZONTAL" },
}

local ACTION_ORDER = {
    { "nextOperator", "Next operator" },   { "prevOperator", "Prev operator" },
    { "nextFavorite", "Next favorite" },   { "prevFavorite", "Prev favorite" },
    { "toggleFavorite", "Fav on/off" },    { "toggleSide", "Atk/Def page" },
    { "nextPrimary", "Next primary" },     { "nextSecondary", "Next secondary" },
    { "nextScope", "Next scope" },         { "nextBarrel", "Next barrel" },
    { "nextGrip", "Next grip" },           { "toggleSystem", "System on/off" },
    { "toggleDebug", "Debug on/off" },     { "redraw", "Redraw" },
    { "toggleRecoilTune", "Recoil tune" }, { "toggleCalibration", "Calibrate" },  { "resetCalibration", "Reset calib." },
}

local SYMBOLS = {
    unicode = { tl = "╔", tr = "╗", bl = "╚", br = "╝", h = "═", v = "║", ml = "╠", mr = "╣",
                star = "★", check = "✓", cross = "✗", sel = ">", empty = "·", arrow = "→" },
    ascii   = { tl = "+", tr = "+", bl = "+", br = "+", h = "=", v = "|", ml = "+", mr = "+",
                star = "*", check = "+", cross = "x", sel = ">", empty = ".", arrow = "->" },
}

--=====================================================================
-- 3. WEAPON DATABASE  (explicit per-weapon attachment availability)
--   Every weapon lists exactly the scopes, barrels and grips it can equip.
--   There are NO shared class defaults: attachment sets differ between
--   weapons of the same type, so nothing is assumed.
--
--   Grips: HORIZONTAL is the game's "no grip" option and exists on every
--   weapon that has a grip slot, alongside VERTICAL and (on most) ANGLED.
--   A weapon with no grip slot lists only "NONE". Barrels always end with
--   "NONE" (no barrel attachment).
--
--   Data sources (checked 2026-09-19, game version Y11S3):
--   * hanslhansl/rainbow-six-siege-weapon-statistics (hand-measured, updated
--     through Aug 2026): angled-grip and extended-barrel availability for
--     each weapon, and every operator's weapon list.
--   * r6data.eu public weapons API: scopes, barrels, and which grips a weapon
--     has. It is older: it lacks PMR90A2, XK23 and TACIT .45.
--   * Ubisoft operator pages: primary/secondary split for shield operators,
--     SPSMG9, Skeleton Key.
--   CONFIRMED BY THE USER: this weapon/attachment list is the authoritative
--   data for the script. Nothing below is flagged as unverified. An empty
--   `scopes = {}` means the weapon has no selectable sights (PMR90A2, XK23,
--   TACIT .45); `barrels`/`grips` of { "NONE" } mean no attachment slot.
--   To correct a weapon later just edit its lists. Optional per-entry
--   `verified = false` still reports the weapon at startup if you want a
--   reminder to recheck something.
--=====================================================================
local WEAPON_LIST = {
    { id = "M4", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "M249", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "SR-25", kind = "primary",
      scopes  = { "TELESCOPIC A", "TELESCOPIC B", "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "M590A1", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "NONE" },
      grips   = { "NONE" } },
    { id = "L85A2", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "AR33", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "PMR90A2", kind = "primary",
      scopes  = {  },
      barrels = { "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "G36C", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "R4-C", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "556XI", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "M1014", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "NONE" },
      grips   = { "NONE" } },
    { id = "F2", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "417", kind = "primary",
      scopes  = { "TELESCOPIC A", "TELESCOPIC B", "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "SG-CQB", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL" } },
    { id = "OTS-03", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "6P41", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "AK-12", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "AUG A2", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "NONE" } },
    { id = "552 COMMANDO", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "G8A1", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "C8-SFW", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "NONE" } },
    { id = "CAMRS", kind = "primary",
      scopes  = { "TELESCOPIC A", "TELESCOPIC B", "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "MK17 CQB", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "PARA-308", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "TYPE-89", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "SUPERNOVA", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL" } },
    { id = "C7E", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "PDW9", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "ITA12L", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "NONE" },
      grips   = { "NONE" } },
    { id = "T-95 LSW", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "SIX12", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "NONE" },
      grips   = { "NONE" } },
    { id = "LMG-E", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "M762", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "XK23", kind = "primary",
      scopes  = {  },
      barrels = { "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "MK 14 EBR", kind = "primary",
      scopes  = { "TELESCOPIC A", "TELESCOPIC B", "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "BOSG.12.2", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "V308", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "SPEAR .308", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "SASG-12", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "AR-15.50", kind = "primary",
      scopes  = { "TELESCOPIC A", "TELESCOPIC B", "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "AK-74M", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "ARX200", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "F90", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "M249 SAW", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "FMG-9", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "NONE" } },
    { id = "SIX12 SD", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "NONE" },
      grips   = { "NONE" } },
    { id = "CSRX 300", kind = "primary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "NONE" },
      grips   = { "NONE" } },
    { id = "SC3000K", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "MP7", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "NONE" } },
    { id = "POF-9", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "COMMANDO 9", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "M870", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "NONE" },
      grips   = { "NONE" } },
    { id = "TCSG12", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "MP5K", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "NONE" } },
    { id = "UMP45", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "MP5", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "P90", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "NONE" } },
    { id = "9X19VSN", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "DP27", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "REFLEX D", "IRON SIGHT" },
      barrels = { "NONE" },
      grips   = { "NONE" } },
    { id = "416-C", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "SUPER 90", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "NONE" },
      grips   = { "NONE" } },
    { id = "9MM C1", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "MPX", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "SPAS-12", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "NONE" },
      grips   = { "NONE" } },
    { id = "M12", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "SPAS-15", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "NONE" },
      grips   = { "NONE" } },
    { id = "MP5SD", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "VECTOR .45 ACP", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "T-5 SMG", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "SCORPION EVO 3 A1", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "FO-12", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "K1A", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "ALDA 5.56", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL" } },
    { id = "ACS12", kind = "primary",
      scopes  = { "MAGNIFIED A", "MAGNIFIED B", "MAGNIFIED C", "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "MX4 STORM", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "AUG A3", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "P10 RONI", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "UZK50GI", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "PCX-33", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "GLAIVE-12", kind = "primary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "5.7 USG", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "NONE" } },
    { id = "ITA12S", kind = "secondary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "NONE" },
      grips   = { "NONE" } },
    { id = "REAPER MK2", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "NONE" } },
    { id = "P226 MK 25", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "NONE" } },
    { id = "M45 MEUSOC", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "NONE" } },
    { id = "P9", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "NONE" } },
    { id = "LFP586", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "NONE" },
      grips   = { "NONE" } },
    { id = "PMM", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "NONE" } },
    { id = "GONNE-6", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "NONE" },
      grips   = { "NONE" } },
    { id = "BEARING 9", kind = "secondary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "NONE" } },
    { id = "GSH-18", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "NONE" } },
    { id = "P12", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "NONE" } },
    { id = "MK1 9MM", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "NONE" } },
    { id = "PRB92", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "NONE" } },
    { id = "P229", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "NONE" } },
    { id = "USP40", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "NONE" } },
    { id = "Q-929", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "NONE" } },
    { id = "RG15", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "NONE" } },
    { id = "SMG-12", kind = "secondary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "C75 AUTO", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "SUPPRESSOR", "NONE" },
      grips   = { "NONE" } },
    { id = "1911 TACOPS", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "NONE" } },
    { id = ".44 MAG SEMI-AUTO", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "NONE" },
      grips   = { "NONE" } },
    { id = "SUPER SHORTY", kind = "secondary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "NONE" },
      grips   = { "NONE" } },
    { id = "SDP 9MM", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "NONE" },
      grips   = { "NONE" } },
    { id = "D-50", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "NONE" },
      grips   = { "NONE" } },
    { id = "SMG-11", kind = "secondary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "HORIZONTAL", "VERTICAL", "ANGLED" } },
    { id = "SPSMG9", kind = "secondary",
      scopes  = { "RED DOT A", "RED DOT B", "RED DOT C", "HOLO A", "HOLO B", "HOLO C", "HOLO D", "REFLEX A", "REFLEX B", "REFLEX C", "IRON SIGHT" },
      barrels = { "FLASH HIDER", "COMPENSATOR", "MUZZLE BRAKE", "SUPPRESSOR", "EXTENDED BARREL", "NONE" },
      grips   = { "NONE" } },
    { id = "BAILIFF 410", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "NONE" },
      grips   = { "NONE" } },
    { id = ".44 VENDETTA", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "NONE" },
      grips   = { "NONE" } },
    { id = "TACIT .45", kind = "secondary",
      scopes  = {  },
      barrels = { "NONE" },
      grips   = { "NONE" } },
    { id = "P-10C", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "NONE" } },
    { id = "KERATOS .357", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "MUZZLE BRAKE", "SUPPRESSOR", "NONE" },
      grips   = { "NONE" } },
    { id = "LUISON", kind = "secondary",
      scopes  = { "CUSTOM SIGHT" },
      barrels = { "NONE" },
      grips   = { "NONE" } },
}

-- id -> entry lookup. Duplicate ids are kept out of the map (first wins)
-- and recorded so ValidateDatabase() can warn about them.
local WEAPONS, WEAPON_DUPLICATES = {}, {}
for _, w in ipairs(WEAPON_LIST) do
    if WEAPONS[w.id] then
        WEAPON_DUPLICATES[#WEAPON_DUPLICATES + 1] = w.id
    else
        WEAPONS[w.id] = w
    end
end

--=====================================================================
-- 4. OPERATOR DATABASE  (operator IDENTITY + weapon lists + default loadout)
--   List order here has NO meaning for screen position (see OPERATOR_GRID).
--   Roster and weapon lists: 39 attackers + 39 defenders (Y11S3, Operation
--   Split Fire), from the same sources as the weapon database. Names are
--   ASCII (Jager, Capitao, Nokk, Tubarao, Skopos) and must match the names
--   used in OPERATOR_GRID.
--   Shield operators (Montagne, Blitz, Clash) have no primary weapon and
--   Blackbeard has no secondary: an empty list is valid.
--   Buck's Skeleton Key is a unique ability, not a weapon, so it is not listed.
--   `default` picks the starting weapon per slot only. Barrel and grip come
--   from CONFIG.attachments.preferred (Suppressor / Horizontal Grip, then
--   the fallback chain) unless you add barrel = "..." or grip = "..." to a
--   default to force something else for that operator. The default primary is
--   the first non-shotgun primary, except the choices you had before.
--   Optional per-operator scopes/barrels/grips lists restrict what a weapon
--   offers for that operator.
--=====================================================================
local OPERATORS = {
    attackers = {
        { name = "Striker",
          weapons = { primary = { "M4", "M249", "SR-25" }, secondary = { "5.7 USG", "ITA12S" } },
          default = { primary = { weapon = "M4" }, secondary = { weapon = "5.7 USG" } } },
        { name = "Sledge",
          weapons = { primary = { "M590A1", "L85A2" }, secondary = { "REAPER MK2", "P226 MK 25" } },
          default = { primary = { weapon = "L85A2" }, secondary = { weapon = "REAPER MK2" } } },
        { name = "Thatcher",
          weapons = { primary = { "AR33", "L85A2", "PMR90A2", "M590A1" }, secondary = { "P226 MK 25" } },
          default = { primary = { weapon = "AR33" }, secondary = { weapon = "P226 MK 25" } } },
        { name = "Ash",
          weapons = { primary = { "G36C", "R4-C" }, secondary = { "M45 MEUSOC", "5.7 USG" } },
          default = { primary = { weapon = "R4-C" }, secondary = { weapon = "M45 MEUSOC" } } },
        { name = "Thermite",
          weapons = { primary = { "556XI", "M1014" }, secondary = { "M45 MEUSOC", "5.7 USG", "ITA12S" } },
          default = { primary = { weapon = "556XI" }, secondary = { weapon = "M45 MEUSOC" } } },
        { name = "Twitch", favorite = true,
          weapons = { primary = { "F2", "417", "SG-CQB" }, secondary = { "P9", "LFP586" } },
          default = { primary = { weapon = "F2" }, secondary = { weapon = "P9" } } },
        { name = "Montagne",
          weapons = { primary = {  }, secondary = { "P9", "LFP586" } },
          default = { secondary = { weapon = "P9" } } },
        { name = "Glaz",
          weapons = { primary = { "OTS-03" }, secondary = { "PMM", "GONNE-6", "BEARING 9" } },
          default = { primary = { weapon = "OTS-03" }, secondary = { weapon = "PMM" } } },
        { name = "Fuze",
          weapons = { primary = { "6P41", "AK-12" }, secondary = { "PMM", "GSH-18" } },
          default = { primary = { weapon = "6P41" }, secondary = { weapon = "PMM" } } },
        { name = "Blitz",
          weapons = { primary = {  }, secondary = { "P12" } },
          default = { secondary = { weapon = "P12" } } },
        { name = "IQ",
          weapons = { primary = { "AUG A2", "552 COMMANDO", "G8A1" }, secondary = { "P12" } },
          default = { primary = { weapon = "AUG A2" }, secondary = { weapon = "P12" } } },
        { name = "Buck", favorite = true,
          weapons = { primary = { "C8-SFW", "CAMRS" }, secondary = { "MK1 9MM" } },
          default = { primary = { weapon = "C8-SFW" }, secondary = { weapon = "MK1 9MM" } } },
        { name = "Blackbeard",
          weapons = { primary = { "MK17 CQB", "SR-25" }, secondary = {  } },
          default = { primary = { weapon = "MK17 CQB" } } },
        { name = "Capitao",
          weapons = { primary = { "PARA-308", "M249", "PMR90A2" }, secondary = { "PRB92", "GONNE-6" } },
          default = { primary = { weapon = "PARA-308" }, secondary = { weapon = "PRB92" } } },
        { name = "Hibana",
          weapons = { primary = { "TYPE-89", "SUPERNOVA", "PMR90A2" }, secondary = { "P229", "BEARING 9" } },
          default = { primary = { weapon = "TYPE-89" }, secondary = { weapon = "P229" } } },
        { name = "Jackal",
          weapons = { primary = { "C7E", "PDW9", "ITA12L" }, secondary = { "USP40", "ITA12S" } },
          default = { primary = { weapon = "C7E" }, secondary = { weapon = "USP40" } } },
        { name = "Ying",
          weapons = { primary = { "T-95 LSW", "SIX12" }, secondary = { "Q-929", "REAPER MK2" } },
          default = { primary = { weapon = "T-95 LSW" }, secondary = { weapon = "Q-929" } } },
        { name = "Zofia",
          weapons = { primary = { "LMG-E", "M762" }, secondary = { "RG15" } },
          default = { primary = { weapon = "M762" }, secondary = { weapon = "RG15" } } },
        { name = "Dokkaebi",
          weapons = { primary = { "XK23", "MK 14 EBR", "BOSG.12.2" }, secondary = { "SMG-12", "C75 AUTO", "GONNE-6" } },
          default = { primary = { weapon = "XK23" }, secondary = { weapon = "SMG-12" } } },
        { name = "Lion",
          weapons = { primary = { "V308", "417", "SG-CQB" }, secondary = { "LFP586", "P9" } },
          default = { primary = { weapon = "V308" }, secondary = { weapon = "LFP586" } } },
        { name = "Finka",
          weapons = { primary = { "SPEAR .308", "6P41", "SASG-12" }, secondary = { "PMM", "GSH-18" } },
          default = { primary = { weapon = "SPEAR .308" }, secondary = { weapon = "PMM" } } },
        { name = "Maverick",
          weapons = { primary = { "AR-15.50", "M4" }, secondary = { "1911 TACOPS", "REAPER MK2" } },
          default = { primary = { weapon = "AR-15.50" }, secondary = { weapon = "1911 TACOPS" } } },
        { name = "Nomad",
          weapons = { primary = { "AK-74M", "ARX200" }, secondary = { ".44 MAG SEMI-AUTO", "PRB92" } },
          default = { primary = { weapon = "AK-74M" }, secondary = { weapon = ".44 MAG SEMI-AUTO" } } },
        { name = "Gridlock",
          weapons = { primary = { "F90", "M249 SAW" }, secondary = { "SUPER SHORTY", "SDP 9MM" } },
          default = { primary = { weapon = "F90" }, secondary = { weapon = "SUPER SHORTY" } } },
        { name = "Nokk",
          weapons = { primary = { "FMG-9", "SIX12 SD", "PMR90A2" }, secondary = { "5.7 USG", "D-50" } },
          default = { primary = { weapon = "FMG-9" }, secondary = { weapon = "5.7 USG" } } },
        { name = "Amaru",
          weapons = { primary = { "G8A1", "SUPERNOVA" }, secondary = { "SMG-11", "ITA12S", "GONNE-6" } },
          default = { primary = { weapon = "G8A1" }, secondary = { weapon = "SMG-11" } } },
        { name = "Kali",
          weapons = { primary = { "CSRX 300" }, secondary = { "SPSMG9", "C75 AUTO", "P226 MK 25" } },
          default = { primary = { weapon = "CSRX 300" }, secondary = { weapon = "SPSMG9" } } },
        { name = "Iana",
          weapons = { primary = { "ARX200", "G36C" }, secondary = { "MK1 9MM", "GONNE-6" } },
          default = { primary = { weapon = "ARX200" }, secondary = { weapon = "MK1 9MM" } } },
        { name = "Ace",
          weapons = { primary = { "AK-12", "M1014" }, secondary = { "P9" } },
          default = { primary = { weapon = "AK-12" }, secondary = { weapon = "P9" } } },
        { name = "Zero",
          weapons = { primary = { "SC3000K", "MP7" }, secondary = { "5.7 USG", "GONNE-6" } },
          default = { primary = { weapon = "SC3000K" }, secondary = { weapon = "5.7 USG" } } },
        { name = "Flores",
          weapons = { primary = { "AR33", "SR-25", "T-95 LSW" }, secondary = { "GSH-18" } },
          default = { primary = { weapon = "AR33" }, secondary = { weapon = "GSH-18" } } },
        { name = "Osa",
          weapons = { primary = { "556XI", "PDW9" }, secondary = { "PMM" } },
          default = { primary = { weapon = "556XI" }, secondary = { weapon = "PMM" } } },
        { name = "Sens",
          weapons = { primary = { "POF-9", "417", "XK23" }, secondary = { "SDP 9MM" } },
          default = { primary = { weapon = "POF-9" }, secondary = { weapon = "SDP 9MM" } } },
        { name = "Grim",
          weapons = { primary = { "552 COMMANDO", "SG-CQB" }, secondary = { "P229", "BAILIFF 410" } },
          default = { primary = { weapon = "552 COMMANDO" }, secondary = { weapon = "P229" } } },
        { name = "Brava",
          weapons = { primary = { "PARA-308", "CAMRS" }, secondary = { "SUPER SHORTY", "USP40" } },
          default = { primary = { weapon = "PARA-308" }, secondary = { weapon = "SUPER SHORTY" } } },
        { name = "Ram",
          weapons = { primary = { "R4-C", "LMG-E" }, secondary = { "MK1 9MM" } },
          default = { primary = { weapon = "R4-C" }, secondary = { weapon = "MK1 9MM" } } },
        { name = "Deimos",
          weapons = { primary = { "AK-74M", "M590A1" }, secondary = { ".44 VENDETTA" } },
          default = { primary = { weapon = "AK-74M" }, secondary = { weapon = ".44 VENDETTA" } } },
        { name = "Rauora",
          weapons = { primary = { "417", "M249", "XK23" }, secondary = { "REAPER MK2", "GSH-18" } },
          default = { primary = { weapon = "417" }, secondary = { weapon = "REAPER MK2" } } },
        { name = "Solid Snake",
          weapons = { primary = { "F2", "PMR90A2" }, secondary = { "TACIT .45" } },
          default = { primary = { weapon = "F2" }, secondary = { weapon = "TACIT .45" } } },
    },

    defenders = {
        { name = "Sentry",
          weapons = { primary = { "COMMANDO 9", "M870", "TCSG12" }, secondary = { "C75 AUTO", "SUPER SHORTY" } },
          default = { primary = { weapon = "COMMANDO 9" }, secondary = { weapon = "C75 AUTO" } } },
        { name = "Smoke",
          weapons = { primary = { "FMG-9", "M590A1" }, secondary = { "P226 MK 25", "SMG-11" } },
          default = { primary = { weapon = "FMG-9" }, secondary = { weapon = "P226 MK 25" } } },
        { name = "Mute",
          weapons = { primary = { "MP5K", "M590A1" }, secondary = { "P226 MK 25", "SMG-11" } },
          default = { primary = { weapon = "MP5K" }, secondary = { weapon = "P226 MK 25" } } },
        { name = "Castle",
          weapons = { primary = { "UMP45", "M1014" }, secondary = { "5.7 USG", "SUPER SHORTY", "M45 MEUSOC" } },
          default = { primary = { weapon = "UMP45" }, secondary = { weapon = "5.7 USG" } } },
        { name = "Pulse",
          weapons = { primary = { "M1014", "UMP45" }, secondary = { "REAPER MK2", "M45 MEUSOC", "5.7 USG" } },
          default = { primary = { weapon = "UMP45" }, secondary = { weapon = "REAPER MK2" } } },
        { name = "Doc",
          weapons = { primary = { "SG-CQB", "MP5", "P90" }, secondary = { "P9", "LFP586", "BAILIFF 410" } },
          default = { primary = { weapon = "MP5" }, secondary = { weapon = "P9" } } },
        { name = "Rook",
          weapons = { primary = { "P90", "MP5", "SG-CQB" }, secondary = { "LFP586", "P9", "REAPER MK2" } },
          default = { primary = { weapon = "P90" }, secondary = { weapon = "LFP586" } } },
        { name = "Kapkan",
          weapons = { primary = { "9X19VSN", "SASG-12" }, secondary = { "PMM", "GSH-18" } },
          default = { primary = { weapon = "9X19VSN" }, secondary = { weapon = "PMM" } } },
        { name = "Tachanka",
          weapons = { primary = { "DP27", "9X19VSN" }, secondary = { "GSH-18", "PMM", "BEARING 9" } },
          default = { primary = { weapon = "DP27" }, secondary = { weapon = "GSH-18" } } },
        { name = "Jager", favorite = true,
          weapons = { primary = { "M870", "416-C" }, secondary = { "P12", "P-10C" } },
          default = { primary = { weapon = "416-C" }, secondary = { weapon = "P12" } } },
        { name = "Bandit",
          weapons = { primary = { "MP7", "M870" }, secondary = { "KERATOS .357", "P12" } },
          default = { primary = { weapon = "MP7" }, secondary = { weapon = "KERATOS .357" } } },
        { name = "Frost",
          weapons = { primary = { "SUPER 90", "9MM C1" }, secondary = { "MK1 9MM", "ITA12S" } },
          default = { primary = { weapon = "9MM C1" }, secondary = { weapon = "MK1 9MM" } } },
        { name = "Valkyrie",
          weapons = { primary = { "MPX", "SPAS-12" }, secondary = { "D-50" } },
          default = { primary = { weapon = "MPX" }, secondary = { weapon = "D-50" } } },
        { name = "Caveira",
          weapons = { primary = { "M12", "SPAS-15" }, secondary = { "LUISON" } },
          default = { primary = { weapon = "M12" }, secondary = { weapon = "LUISON" } } },
        { name = "Echo",
          weapons = { primary = { "SUPERNOVA", "MP5SD" }, secondary = { "P229", "BEARING 9" } },
          default = { primary = { weapon = "MP5SD" }, secondary = { weapon = "P229" } } },
        { name = "Mira",
          weapons = { primary = { "VECTOR .45 ACP", "ITA12L" }, secondary = { "USP40", "ITA12S" } },
          default = { primary = { weapon = "VECTOR .45 ACP" }, secondary = { weapon = "USP40" } } },
        { name = "Lesion",
          weapons = { primary = { "SIX12 SD", "T-5 SMG" }, secondary = { "Q-929" } },
          default = { primary = { weapon = "T-5 SMG" }, secondary = { weapon = "Q-929" } } },
        { name = "Ela",
          weapons = { primary = { "SCORPION EVO 3 A1", "FO-12" }, secondary = { "RG15" } },
          default = { primary = { weapon = "SCORPION EVO 3 A1" }, secondary = { weapon = "RG15" } } },
        { name = "Vigil",
          weapons = { primary = { "K1A", "BOSG.12.2" }, secondary = { "C75 AUTO", "SMG-12" } },
          default = { primary = { weapon = "K1A" }, secondary = { weapon = "C75 AUTO" } } },
        { name = "Maestro",
          weapons = { primary = { "ALDA 5.56", "ACS12" }, secondary = { "BAILIFF 410", "KERATOS .357" } },
          default = { primary = { weapon = "ALDA 5.56" }, secondary = { weapon = "BAILIFF 410" } } },
        { name = "Alibi",
          weapons = { primary = { "MX4 STORM", "ACS12" }, secondary = { "KERATOS .357", "BAILIFF 410" } },
          default = { primary = { weapon = "MX4 STORM" }, secondary = { weapon = "KERATOS .357" } } },
        { name = "Clash",
          weapons = { primary = {  }, secondary = { "SUPER SHORTY", "SPSMG9", "P-10C" } },
          default = { secondary = { weapon = "SUPER SHORTY" } } },
        { name = "Kaid",
          weapons = { primary = { "AUG A3", "TCSG12" }, secondary = { ".44 MAG SEMI-AUTO", "LFP586" } },
          default = { primary = { weapon = "AUG A3" }, secondary = { weapon = ".44 MAG SEMI-AUTO" } } },
        { name = "Mozzie",
          weapons = { primary = { "COMMANDO 9", "P10 RONI" }, secondary = { "SDP 9MM", "SUPER SHORTY" } },
          default = { primary = { weapon = "COMMANDO 9" }, secondary = { weapon = "SDP 9MM" } } },
        { name = "Warden",
          weapons = { primary = { "M590A1", "MPX" }, secondary = { "P-10C", "SMG-12" } },
          default = { primary = { weapon = "MPX" }, secondary = { weapon = "P-10C" } } },
        { name = "Goyo",
          weapons = { primary = { "VECTOR .45 ACP", "TCSG12" }, secondary = { "P229" } },
          default = { primary = { weapon = "VECTOR .45 ACP" }, secondary = { weapon = "P229" } } },
        { name = "Wamai",
          weapons = { primary = { "AUG A2", "MP5K" }, secondary = { "KERATOS .357", "P12", "SUPER SHORTY" } },
          default = { primary = { weapon = "AUG A2" }, secondary = { weapon = "KERATOS .357" } } },
        { name = "Oryx",
          weapons = { primary = { "T-5 SMG", "SPAS-12" }, secondary = { "BAILIFF 410", "USP40", "REAPER MK2" } },
          default = { primary = { weapon = "T-5 SMG" }, secondary = { weapon = "BAILIFF 410" } } },
        { name = "Melusi",
          weapons = { primary = { "MP5", "SUPER 90" }, secondary = { "RG15", "ITA12S" } },
          default = { primary = { weapon = "MP5" }, secondary = { weapon = "RG15" } } },
        { name = "Aruni",
          weapons = { primary = { "P10 RONI", "MK 14 EBR" }, secondary = { "PRB92" } },
          default = { primary = { weapon = "P10 RONI" }, secondary = { weapon = "PRB92" } } },
        { name = "Thunderbird",
          weapons = { primary = { "SPEAR .308", "SPAS-15" }, secondary = { "Q-929", "BEARING 9", "ITA12S" } },
          default = { primary = { weapon = "SPEAR .308" }, secondary = { weapon = "Q-929" } } },
        { name = "Thorn",
          weapons = { primary = { "UZK50GI", "M870" }, secondary = { "1911 TACOPS", "C75 AUTO" } },
          default = { primary = { weapon = "UZK50GI" }, secondary = { weapon = "1911 TACOPS" } } },
        { name = "Azami",
          weapons = { primary = { "9X19VSN", "ACS12" }, secondary = { "D-50" } },
          default = { primary = { weapon = "9X19VSN" }, secondary = { weapon = "D-50" } } },
        { name = "Solis",
          weapons = { primary = { "P90", "ITA12L" }, secondary = { "SMG-11" } },
          default = { primary = { weapon = "P90" }, secondary = { weapon = "SMG-11" } } },
        { name = "Fenrir",
          weapons = { primary = { "MP7", "SASG-12" }, secondary = { "5.7 USG" } },
          default = { primary = { weapon = "MP7" }, secondary = { weapon = "5.7 USG" } } },
        { name = "Tubarao",
          weapons = { primary = { "MPX", "AR-15.50" }, secondary = { "P226 MK 25" } },
          default = { primary = { weapon = "MPX" }, secondary = { weapon = "P226 MK 25" } } },
        { name = "Skopos",
          weapons = { primary = { "PCX-33" }, secondary = { "P229" } },
          default = { primary = { weapon = "PCX-33" }, secondary = { weapon = "P229" } } },
        { name = "Denari",
          weapons = { primary = { "SCORPION EVO 3 A1", "FMG-9", "GLAIVE-12" }, secondary = { "P226 MK 25" } },
          default = { primary = { weapon = "SCORPION EVO 3 A1" }, secondary = { weapon = "P226 MK 25" } } },
        { name = "Noor",
          weapons = { primary = { "COMMANDO 9", "ALDA 5.56" }, secondary = { "1911 TACOPS", "BAILIFF 410" } },
          default = { primary = { weapon = "COMMANDO 9" }, secondary = { weapon = "1911 TACOPS" } } },
    },
}

--=====================================================================
-- 4b. OPERATOR GRID  (WHICH operator is in WHICH on-screen tile)
--   layout[row][column] = operator name exactly as written in OPERATORS.
--     "Name"              tile holds that operator
--     false / "EMPTY"     tile is intentionally empty (nothing shifts)
--     "?" (U below)       position NOT VERIFIED yet: clicking it reports
--                         the row/col so you can fill it in
--   Do not use nil inside a row. Every row must have exactly `columns`
--   entries and there must be exactly `rows` rows (checked at startup).
--   The grid is the PHYSICAL 7 x 7 = 49 cell selector. Cells and operators
--   are different things: empty cells still occupy a position, so write
--   `false` for them instead of leaving them out, or every later tile shifts.
--   Layout below: 7 x 7 = 49 cells per side, row-major. Cells 1-39 hold the
--   39 operators; cells 40-49 (row 6 cols 5-7 and all of row 7) are empty.
--   Tile order was supplied from the live selector, not from a public
--   source. If a future season reorders tiles, edit the names here. Use
--   U ("?") for any tile you have not checked yet: clicking it reports the
--   row/col to fill in.
--=====================================================================
local U = CELL_UNKNOWN
local X = false   -- empty physical cell (keeps its position)
local OPERATOR_GRID = {
    attackers = {
        columns = 7, rows = 7,
        layout = {
            { "Striker", "Sledge",   "Thatcher", "Ash",         "Thermite", "Twitch",     "Montagne" },
            { "Glaz",    "Fuze",     "Blitz",    "IQ",          "Buck",     "Blackbeard", "Capitao"  },
            { "Hibana",  "Jackal",   "Ying",     "Zofia",       "Dokkaebi", "Lion",       "Finka"    },
            { "Maverick","Nomad",    "Gridlock", "Nokk",        "Amaru",    "Kali",       "Iana"     },
            { "Ace",     "Zero",     "Flores",   "Osa",         "Sens",     "Grim",       "Brava"    },
            { "Ram",     "Deimos",   "Rauora",   "Solid Snake", X,          X,            X          },
            { X,         X,          X,          X,             X,          X,            X          },
        },
    },
    defenders = {
        columns = 7, rows = 7,
        layout = {
            { "Sentry",  "Smoke",    "Mute",        "Castle", "Pulse",  "Doc",      "Rook"   },
            { "Kapkan",  "Tachanka", "Jager",       "Bandit", "Frost",  "Valkyrie", "Caveira"},
            { "Echo",    "Mira",     "Lesion",      "Ela",    "Vigil",  "Maestro",  "Alibi"  },
            { "Clash",   "Kaid",     "Mozzie",      "Warden", "Goyo",   "Wamai",    "Oryx"   },
            { "Melusi",  "Aruni",    "Thunderbird", "Thorn",  "Azami",  "Solis",    "Fenrir" },
            { "Tubarao", "Skopos",   "Denari",      "Noor",   X,        X,          X        },
            { X,         X,          X,             X,        X,        X,          X        },
        },
    },
}

--=====================================================================
-- 5. PROFILE DATA  (stored reference-settings records, NOT user settings)
--   One profile per operator + weapon + barrel + grip combination. Its id is
--   always OPERATOR_WEAPON_BARREL_GRIP in caps with non-alphanumerics turned
--   into "_" (for example ZOFIA_M762_SUPPRESSOR_VERTICAL). The console shows
--   the id of the active combination, so you can copy it from there.
--
--   Lookup is EXACT: a combination with no entry shows PROFILE NOT
--   CALIBRATED. Nothing falls back to another weapon's or attachment's data.
--   To deliberately share one record between combinations, give the second
--   one `sameAs = "OTHER_ID"`.
--
--   Optional `scopes = { "MAGNIFIED C" }` limits a profile to those scopes (any
--   other scope shows NOT CALIBRATED with a scope note).
--
--   `reference` records the settings the profile was made under:
--   dpi, horizontal, vertical, ads, fov. "CALIBRATED" in this script means
--   only that such a record exists and is well-formed; the console compares
--   it with your CONFIG values as a rough guide. Nothing here is applied to
--   the mouse. This script stores no recoil curves and never moves the mouse.
--
--   Templates (copy, edit, remove the comment marks). Your default setup
--   (Suppressor + Horizontal Grip) gives ids like these:
--   { id = "ZOFIA_M762_SUPPRESSOR_HORIZONTAL",
--     operator = "Zofia", weapon = "M762", barrel = "SUPPRESSOR", grip = "HORIZONTAL",
--     scopes = { "MAGNIFIED C" },            -- optional
--     reference = { dpi = 1600, horizontal = 4, vertical = 4, ads = 52, fov = 84 },
--     notes = "free text" },
--   { id = "TWITCH_F2_SUPPRESSOR_HORIZONTAL",
--     operator = "Twitch", weapon = "F2", barrel = "SUPPRESSOR", grip = "HORIZONTAL",
--     reference = { dpi = 1600, horizontal = 4, vertical = 4, ads = 52, fov = 84 } },
--   Deliberate sharing between two combinations:
--   { id = "ZOFIA_M762_SUPPRESSOR_VERTICAL", sameAs = "ZOFIA_M762_SUPPRESSOR_HORIZONTAL",
--     operator = "Zofia", weapon = "M762", barrel = "SUPPRESSOR", grip = "VERTICAL" },
--
--   NOTE: BUCK_C8_SFW_SUPPRESSOR_HORIZONTAL is NOT a valid combination in the
--   data above: the C8-SFW has no grip slot (both sources agree), so Buck's
--   default is BUCK_C8_SFW_SUPPRESSOR_NONE. A profile listing a grip the
--   weapon cannot equip is reported at startup.
--=====================================================================
local PROFILE_LIST = {
}

--=====================================================================
-- 5b. RECOIL PROFILES  (from the Vora free script; keyed by weapon id)
--   r      = base vertical counts per tick (tickMs)
--   x1/tm1 = extra horizontal counts once the burst is tm1 ms old
--   x2/tm2 = further horizontal counts after tm2 ms (only after tm1)
--   y1/tym1, y2/tym2 = same, vertical
--=====================================================================
local RECOIL_PROFILES = {
    ["TYPE-89"]      = { operator = "Hibana", r = 14, x1 = -1, tm1 = 100,  x2 = 0, tm2 = 0,    y1 = 1,  tym1 = 500,  y2 = 1, tym2 = 900 },
    ["C8-SFW"]       = { operator = "Buck",   r = 16, x1 = -1, tm1 = 1100, x2 = 1, tm2 = 1500, y1 = 2,  tym1 = 1100, y2 = 1, tym2 = 1400 },
    ["T-5 SMG"]      = { operator = "Lesion", r = 6,  x1 = -1, tm1 = 500,  x2 = 1, tm2 = 800,  y1 = 1,  tym1 = 350,  y2 = 1, tym2 = 830 },
    ["COMMANDO 9"]   = { operator = "Mozzie", r = 6,  x1 = -1, tm1 = 150,  x2 = 1, tm2 = 250,  y1 = -1, tym1 = 40,   y2 = 1, tym2 = 550 },
    -- tuned with the tune mode. Keys are WEAPON:BARREL:GRIP, so each loadout has its own profile.
    ["M4:SUPPRESSOR:HORIZONTAL"] = { r = 8, x1 = 0, tm1 = 0, x2 = 0, tm2 = 0, y1 = 1, tym1 = 500, y2 = 1, tym2 = 900, strength = 3.90, side = -0.5, late = 1.00 },
}

-- Profiles are looked up per exact loadout first ("WEAPON:BARREL:GRIP"), then
-- "WEAPON:BARREL", then plain "WEAPON" (the built-in Vora profiles, which still
-- need CONFIG.recoil.requireBarrel). Barrel and grip change how a gun kicks.
local function RecoilKey(slot)
    return string.format("%s:%s:%s", tostring(slot.weapon), tostring(slot.barrel), tostring(slot.grip))
end

-- Returns profile, key, exact. exact = the profile belongs to this barrel (no barrel rule needed).
local function FindRecoilProfile(slot)
    if not slot or not slot.weapon then return nil end
    local k3 = RecoilKey(slot)
    if RECOIL_PROFILES[k3] then return RECOIL_PROFILES[k3], k3, true end
    local k2 = slot.weapon .. ":" .. tostring(slot.barrel)
    if RECOIL_PROFILES[k2] then return RECOIL_PROFILES[k2], k2, true end
    if RECOIL_PROFILES[slot.weapon] then return RECOIL_PROFILES[slot.weapon], slot.weapon, false end
    return nil
end

-- The exact line to paste into RECOIL_PROFILES for a profile (used by the console and the overlay).
local function PasteLine(weapon, p)
    return string.format("[\"%s\"] = { %sr = %d, x1 = %d, tm1 = %d, x2 = %d, tm2 = %d, y1 = %d, tym1 = %d, y2 = %d, tym2 = %d, strength = %.2f, side = %.1f, late = %.2f },",
        weapon,
        (p.operator and string.format("operator = \"%s\", ", p.operator) or "")
            .. (p.barrel and string.format("barrel = \"%s\", ", p.barrel) or ""),
        p.r, p.x1, p.tm1, p.x2, p.tm2, p.y1, p.tym1, p.y2, p.tym2,
        p.strength or 1, p.side or 0, p.late or 1)
end

-- Tune mode creates one of these for any primary that has no profile yet
-- (no `operator` key = usable by every operator that carries the weapon).
local STARTER_PROFILE = { r = 8, x1 = 0, tm1 = 0, x2 = 0, tm2 = 0, y1 = 1, tym1 = 500, y2 = 1, tym2 = 900 }

-- The three simple tune knobs. Every profile may carry them; missing = default.
--   strength  multiplies the whole vertical pull
--   side      constant sideways counts per tick (+ right, - left)
--   late      multiplies only the extra pull added late in the spray (y1/y2)
-- The raw timing numbers (r, x1, tm1 ...) stay editable in RECOIL_PROFILES.
-- Tuning is a 3-step guided check. `look` = what to watch for at that step,
-- `ask` = the two answers: MB5 raises the value, MB4 lowers it.
local TUNE_FIELDS = {
    { key = "strength", label = "VERTICAL", step = 0.10, def = 1, min = 0.1, fmt = "%.2f",
      look = "Aim at ONE spot on the wall, spray, and see where the holes go compared with that spot.",
      ask  = "Still UP: MB5 (pull more)    Sinks DOWN: MB4 (pull less)" },
    { key = "side",     label = "SIDEWAYS", step = 0.25,  def = 0, min = -5,  fmt = "%+.1f",
      look = "Same spray: do the holes wander LEFT or RIGHT of the spot?",
      ask  = "Holes drift LEFT: MB5    Holes drift RIGHT: MB4" },
    { key = "late",     label = "END OF SPRAY", step = 0.5, def = 1, min = 0, fmt = "%.2f",
      look = "Only the LAST bullets of a full magazine matter here.",
      ask  = "Last holes UP: MB5    Last holes DOWN: MB4" },
}

--=====================================================================
-- 6. RUNTIME STATE
--=====================================================================
local State = {
    enabled      = CONFIG.startup.enabled,
    debug        = CONFIG.startup.debug,
    side         = CONFIG.startup.side,
    opIndex      = { attackers = 1, defenders = 1 },
    loadout      = { primary = {}, secondary = {} },
    activeSlot   = "primary",
    saved        = {},        -- session-only per-operator loadouts (no file access in G HUB)
    favorites    = {},        -- name -> true
    operatorIndexByName = { attackers = {}, defenders = {} },  -- side -> name -> OPERATORS index
    profileById  = {},        -- profile id -> PROFILE_LIST entry
    gridStats    = {},        -- side -> { mapped, unknown, empty }
    bindIndex    = {},        -- "mod:button" -> action name
    -- Calibration stores geometry only, separately per side.
    calibration  = { active = false, side = nil, points = {}, override = {}, report = {} },
    warnings     = {},
    debugLog     = {},
    message      = "",
    lastFrame    = nil,
    lastEventKey = nil,
    lastEventMs  = -100000,
    tune         = { active = false, field = 1, lines = {}, orig = {}, starter = {}, touched = {}, wasStarter = {}, streak = 0, lastDir = 0, lastMs = -100000 },
    slotLock     = nil,   -- last seen state of the slot-sync lock key
    spray        = nil,   -- what the recoil loop did in the last burst {ms, n, x, y}   -- recoil tune mode
}

--=====================================================================
-- 7. UTILITY FUNCTIONS
--=====================================================================
local UTF8_CHAR = "[\0-\127\194-\244][\128-\191]*"

local function Clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

local function IndexOf(list, value)
    if list then
        for i = 1, #list do
            if list[i] == value then return i end
        end
    end
    return 0
end

local function CopyTable(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

local function CycleList(list, current, dir)
    local n, idx = #list, IndexOf(list, current)
    if n == 0 then return nil end
    if idx == 0 then return (dir > 0) and list[1] or list[n] end
    return list[((idx - 1 + dir) % n) + 1]
end

local function Ulen(s)
    local n = 0
    for _ in s:gmatch(UTF8_CHAR) do n = n + 1 end
    return n
end

local function USub(s, maxChars)
    local out, n = {}, 0
    for ch in s:gmatch(UTF8_CHAR) do
        if n >= maxChars then break end
        n = n + 1
        out[n] = ch
    end
    return table.concat(out)
end

local function Clip(s, maxChars)
    if Ulen(s) <= maxChars then return s end
    return USub(s, maxChars - 1) .. "."
end

local function PadRight(s, width)
    local len = Ulen(s)
    if len >= width then return s end
    return s .. string.rep(" ", width - len)
end

local function Center(s, width)
    local len = Ulen(s)
    if len >= width then return s end
    return string.rep(" ", math.floor((width - len) / 2)) .. s
end

local function Sym()
    return CONFIG.ui.unicode and SYMBOLS.unicode or SYMBOLS.ascii
end

local function Notify(text)
    State.message = text
end

local function Debug(tag, fmt, ...)
    if not State.debug then return end
    local line = string.format("[" .. tag .. "] " .. fmt, ...)
    local log = State.debugLog
    log[#log + 1] = line
    while #log > CONFIG.ui.debugLines do table.remove(log, 1) end
end

local function Warn(text)
    State.warnings[#State.warnings + 1] = text
end

local function CurrentOperator()
    return OPERATORS[State.side][State.opIndex[State.side]]
end

-- OPERATOR_WEAPON_BARREL_GRIP, caps, non-alphanumerics -> "_".
local function BuildProfileId(operatorName, weaponId, barrel, grip)
    local function part(s)
        return (string.upper(tostring(s or "NONE")):gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
    end
    return part(operatorName) .. "_" .. part(weaponId) .. "_" .. part(barrel) .. "_" .. part(grip)
end

local function BindText(bind)
    return string.upper(bind.mod) .. "+" .. (BUTTON_NAME[bind.button] or ("B" .. bind.button))
end

--=====================================================================
-- 8. COORDINATE / CALIBRATION ENGINE
--=====================================================================
local function GetSelectionPosition()
    if type(GetMousePosition) ~= "function" then return nil end
    local ok, x, y = pcall(GetMousePosition)
    if not ok or type(x) ~= "number" or type(y) ~= "number" then return nil end
    return x, y
end

local function NormalizeCoordinates(rawX, rawY)
    return Clamp(rawX / RAW_COORD_MAX, 0, 1), Clamp(rawY / RAW_COORD_MAX, 0, 1)
end

local function PresetName()
    local name = CONFIG.grid.activePreset
    if name == "auto" then
        name = string.format("%dx%d", CONFIG.resolution.width, CONFIG.resolution.height)
    end
    return name
end

-- Combines OPERATOR_GRID[side] (columns/rows/layout) with physical geometry
-- (preset for this resolution+side, or that side's calibration override).
local function GetGridSpec(side)
    side = side or State.side
    local def = OPERATOR_GRID[side]
    local grid = CONFIG.grid
    local name = PresetName()
    local preset = grid.presets[name]
    local label = name
    if not preset then
        preset = grid.presets[grid.fallbackPreset]
        label = grid.fallbackPreset .. " (fallback)"
    end
    local geo = preset[side]
    local spec = {
        side = side, columns = def.columns, rows = def.rows, layout = def.layout,
        padding = geo.padding, topLeft = geo.topLeft, bottomRight = geo.bottomRight,
    }
    local override = State.calibration.override[side]
    if override then
        spec.topLeft, spec.bottomRight = override.topLeft, override.bottomRight
        spec.padding = override.padding or geo.padding
        label = "CALIBRATED"
    end
    return spec, label
end

local function ComputeCellSize(spec)
    local w = (spec.bottomRight.x - spec.topLeft.x) - spec.padding.x * (spec.columns - 1)
    local h = (spec.bottomRight.y - spec.topLeft.y) - spec.padding.y * (spec.rows - 1)
    return w / spec.columns, h / spec.rows
end

-- Returns row, col (1-based) or nil, reason.
local function MapCoordinatesToOperatorGrid(nx, ny, spec)
    local tl, br = spec.topLeft, spec.bottomRight
    if nx < tl.x or ny < tl.y or nx > br.x or ny > br.y then return nil, "outside" end
    local cellW, cellH = ComputeCellSize(spec)
    local pitchX, pitchY = cellW + spec.padding.x, cellH + spec.padding.y
    local col = math.floor((nx - tl.x) / pitchX) + 1
    local row = math.floor((ny - tl.y) / pitchY) + 1
    if col > spec.columns or row > spec.rows then return nil, "outside" end
    local inX = (nx - tl.x) - (col - 1) * pitchX
    local inY = (ny - tl.y) - (row - 1) * pitchY
    if inX > cellW or inY > cellH then return nil, "gap" end
    return row, col
end

-- Builds PHYSICAL geometry (topLeft/bottomRight/padding) from two clicked
-- points, or nil if invalid. Columns/rows come from OPERATOR_GRID, never
-- from calibration, and operator order is never touched.
local function BuildGridFromPoints(a, b, base, mode)
    if b.x <= a.x or b.y <= a.y then return nil end
    local geo = { padding = { x = base.padding.x, y = base.padding.y } }
    if mode == "centers" and base.columns > 1 and base.rows > 1 then
        local cellW = (b.x - a.x) / (base.columns - 1) - base.padding.x
        local cellH = (b.y - a.y) / (base.rows - 1) - base.padding.y
        if cellW <= 0 or cellH <= 0 then return nil end
        geo.topLeft     = { x = a.x - cellW / 2, y = a.y - cellH / 2 }
        geo.bottomRight = { x = b.x + cellW / 2, y = b.y + cellH / 2 }
    else
        geo.topLeft     = { x = a.x, y = a.y }
        geo.bottomRight = { x = b.x, y = b.y }
    end
    return geo
end

local function BuildCalibrationReport(side, geo)
    local def = OPERATOR_GRID[side]
    return {
        "GRID CALIBRATION - " .. SIDE_LABEL[side],
        string.format("Top Left: %.3f, %.3f", geo.topLeft.x, geo.topLeft.y),
        string.format("Bottom Right: %.3f, %.3f", geo.bottomRight.x, geo.bottomRight.y),
        string.format("Columns: %d   Rows: %d", def.columns, def.rows),
        string.format("Paste: topLeft = { x = %.4f, y = %.4f }, bottomRight = { x = %.4f, y = %.4f }",
            geo.topLeft.x, geo.topLeft.y, geo.bottomRight.x, geo.bottomRight.y),
    }
end

local function RecordCalibrationPoint(nx, ny)
    local cal = State.calibration
    cal.points[#cal.points + 1] = { x = nx, y = ny }
    local centers = CONFIG.grid.calibrationMode == "centers"
    if #cal.points == 1 then
        local def = OPERATOR_GRID[cal.side]
        Notify(string.format("CAL 2/2 %s: hover %s, then RSHIFT+MB4", SIDE_LABEL[cal.side],
            centers and string.format("CENTER of tile (%d,%d)", def.rows, def.columns)
            or string.format("outer BOTTOM-RIGHT of tile (%d,%d)", def.rows, def.columns)))
        return
    end
    local side = cal.side
    local base = GetGridSpec(side)
    local geo = BuildGridFromPoints(cal.points[1], cal.points[2], base, CONFIG.grid.calibrationMode)
    cal.points = {}
    if not geo then
        Notify(Sym().cross .. " CALIBRATION FAILED: 2nd point must be right of and below the 1st. Start again (1/2).")
        return
    end
    cal.override[side], cal.active = geo, false
    cal.report[side] = BuildCalibrationReport(side, geo)
    Notify(Sym().check .. " " .. SIDE_LABEL[side] .. " GRID CALIBRATED")
end

--=====================================================================
-- 9. PROFILE MANAGER  (loadout state + base-profile / scaling logic)
--=====================================================================
local function GetADS(scope)
    return CONFIG.ads.perScope[scope] or CONFIG.ads.default
end

local function AttachmentOptions(op, weaponId, field)
    local key    = ATTACHMENT_KEY[field]
    local weapon = WEAPONS[weaponId] or {}
    local base   = weapon[key] or {}
    local restrict = op[key]
    if not restrict then return base end
    local out = {}
    for _, v in ipairs(base) do
        if IndexOf(restrict, v) > 0 then out[#out + 1] = v end
    end
    if #out == 0 then return base end
    return out
end

local function HasWeapons(op, kind)
    local list = op.weapons and op.weapons[kind]
    return list ~= nil and #list > 0
end

-- Configured = at least one weapon. Shield operators have no primary and
-- Blackbeard has no secondary, so either list may be empty. An operator with
-- no weapons at all is valid: its loadout is "not configured".
local function IsConfigured(op)
    return HasWeapons(op, "primary") or HasWeapons(op, "secondary")
end

-- Default attachment for one field: the operator's explicit default if the
-- weapon can equip it, else the first entry of CONFIG.attachments.preferred
-- the weapon can equip, else the weapon's first option. Never returns an
-- attachment that is not in `options`.
local function PickDefaultAttachment(options, explicit, field)
    if explicit and IndexOf(options, explicit) > 0 then return explicit end
    local chain = CONFIG.attachments.preferred[field]
    if chain then
        for _, name in ipairs(chain) do
            if IndexOf(options, name) > 0 then return name end
        end
    end
    return options[1]
end

local function ValidateSlot(op, kind, slot)
    local weapons = op.weapons and op.weapons[kind]
    if not weapons or #weapons == 0 then return end
    if IndexOf(weapons, slot.weapon) == 0 then slot.weapon = weapons[1] end
    local def = op.default and op.default[kind]
    if def and def.weapon ~= slot.weapon then def = nil end
    for _, field in ipairs(ATTACHMENT_FIELDS) do
        local options = AttachmentOptions(op, slot.weapon, field)
        if IndexOf(options, slot[field]) == 0 then
            slot[field] = PickDefaultAttachment(options, def and def[field], field)
        end
    end
end

local function FindOperatorByName(name)
    for _, side in ipairs(SIDE_ORDER) do
        local idx = State.operatorIndexByName[side][name]
        if idx then return OPERATORS[side][idx], side end
    end
    return nil
end

local function IsPositiveNumber(n)
    return type(n) == "number" and n == n and n > 0 and n < math.huge
end

local function IsValidReference(ref)
    if type(ref) ~= "table" then return false end
    for _, key in ipairs({ "dpi", "horizontal", "vertical", "ads", "fov" }) do
        if not IsPositiveNumber(ref[key]) then return false, key end
    end
    return true
end

-- Exact-match profile lookup for the active slot. Returns:
--   id       the id of this operator/weapon/barrel/grip combination
--   profile  the (alias-resolved) record when CALIBRATED, otherwise nil
--   note     why it is not calibrated, when there is more to say
-- Never falls back to another combination's data.
local function ResolveProfile(op, slot)
    local id = BuildProfileId(op.name, slot.weapon, slot.barrel, slot.grip)
    local profile = State.profileById[id]
    if not profile then return id, nil, nil end
    local seen = { [id] = true }
    while profile and profile.sameAs do
        if seen[profile.sameAs] then return id, nil, "sameAs loop" end
        seen[profile.sameAs] = true
        profile = State.profileById[profile.sameAs]
        if not profile then return id, nil, "sameAs target missing" end
    end
    if profile.scopes and IndexOf(profile.scopes, slot.scope) == 0 then
        return id, nil, "not stored for scope " .. tostring(slot.scope)
    end
    if not IsValidReference(profile.reference) then return id, nil, "reference data malformed" end
    return id, profile, nil
end

local function ProfileStatusText(profile, note)
    if profile then return "CALIBRATED" end
    return "PROFILE NOT CALIBRATED" .. (note and (" (" .. note .. ")") or "")
end

-- Debug lines for the active slot. `full` also prints the [LOADOUT] line.
local function ReportActive(op, full)
    if not State.debug then return end
    local slot = State.loadout[State.activeSlot]
    if full then
        Debug("LOADOUT", "%s / %s", op.name, tostring(slot.weapon))
    end
    Debug("ATTACH", "%s / %s (scope %s, %s)", tostring(slot.barrel), tostring(slot.grip),
        tostring(slot.scope), State.activeSlot)
    local id, profile, note = ResolveProfile(op, slot)
    Debug("PROFILE", "%s", id)
    Debug("PROFILE", "%s", ProfileStatusText(profile, note))
end

local function CommitLoadout()
    local op = CurrentOperator()
    if not IsConfigured(op) then return end
    State.saved[op.name] = {
        primary   = CopyTable(State.loadout.primary),
        secondary = CopyTable(State.loadout.secondary),
    }
end

local function LoadOperatorLoadout(op)
    local src = State.saved[op.name] or op.default or {}
    State.loadout = { primary = CopyTable(src.primary), secondary = CopyTable(src.secondary) }
    for _, kind in ipairs(SLOT_KINDS) do ValidateSlot(op, kind, State.loadout[kind]) end
    State.activeSlot = HasWeapons(op, "primary") and "primary" or "secondary"
    if IsConfigured(op) then
        ReportActive(op, true)
    else
        Debug("PROFILE", "Loaded %s (loadout not configured)", op.name)
    end
end

local function CycleWeapon(kind, dir)
    local op, slot = CurrentOperator(), State.loadout[kind]
    if not IsConfigured(op) then
        Notify(Sym().cross .. " LOADOUT NOT CONFIGURED: " .. string.upper(op.name))
        return
    end
    local list = op.weapons[kind]
    if not list or #list == 0 then
        Notify(Sym().cross .. " " .. string.upper(op.name) .. " HAS NO " .. string.upper(kind) .. " WEAPON")
        return
    end
    if #list <= 1 then
        State.activeSlot = kind
        Notify(Sym().cross .. " " .. string.upper(kind) .. ": only " .. tostring(slot.weapon) .. " available")
        return
    end
    slot.weapon = CycleList(list, slot.weapon, dir)
    for _, field in ipairs(ATTACHMENT_FIELDS) do slot[field] = nil end
    ValidateSlot(op, kind, slot)
    State.activeSlot = kind
    CommitLoadout()
    Debug("LOADOUT", "%s changed -> %s", kind, slot.weapon)
    ReportActive(op, false)
    Notify(Sym().arrow .. " " .. string.upper(kind) .. ": " .. slot.weapon)
end

local function CycleAttachment(field, dir)
    local op = CurrentOperator()
    if not IsConfigured(op) then
        Notify(Sym().cross .. " LOADOUT NOT CONFIGURED: " .. string.upper(op.name))
        return
    end
    local slot = State.loadout[State.activeSlot]
    local options = AttachmentOptions(op, slot.weapon, field)
    if #options <= 1 then
        Notify(Sym().cross .. " " .. string.upper(field) .. ": no alternatives for " .. tostring(slot.weapon))
        return
    end
    slot[field] = CycleList(options, slot[field], dir)
    CommitLoadout()
    Debug("LOADOUT", "%s changed -> %s", field, slot[field])
    ReportActive(op, false)
    local extra = (field == "scope") and ("  (ADS " .. GetADS(slot.scope) .. ")") or ""
    Notify(Sym().arrow .. " " .. string.upper(field) .. ": " .. slot[field] .. extra)
end

-- Scaling / comparison logic. Informational only: sensitivity, DPI and FOV
-- do not reduce to one exact multiplier in-game, so ratios are shown as
-- rough guidance and never applied to any input.
local function BuildUserProfile(scope)
    return { dpi = CONFIG.dpi, horizontal = CONFIG.sensitivity.horizontal,
             vertical = CONFIG.sensitivity.vertical, ads = GetADS(scope), fov = CONFIG.fov }
end

local function CompareProfiles(ref, user)
    local function ratio(a, b)
        if not a or not b or b == 0 then return nil end
        return a / b
    end
    local h = ratio(user.dpi * user.horizontal, ref.dpi * ref.horizontal)
    local v = ratio(user.dpi * user.vertical,   ref.dpi * ref.vertical)
    local ads = ratio(user.ads, ref.ads)
    local fovDelta = user.fov - ref.fov
    return { h = h, v = v, ads = ads, fovDelta = fovDelta,
             exact = (h == 1 and v == 1 and ads == 1 and fovDelta == 0) }
end

--=====================================================================
-- 10. OPERATOR DETECTION
--=====================================================================
-- Explicit tile lookup: OPERATOR_GRID layout[row][col] -> operator name.
-- Returns name, or nil plus "EMPTY" / "UNKNOWN".
local function GetOperatorNameFromGrid(spec, row, col)
    local rowDef = spec.layout[row]
    local cell = rowDef and rowDef[col]
    if not cell or cell == false or cell == CELL_EMPTY or cell == "empty" then return nil, "EMPTY" end
    if cell == CELL_UNKNOWN then return nil, "UNKNOWN" end
    return cell
end

-- name -> database index via operatorIndexByName.
-- Returns index, operator, name  or  nil, nil, name-or-nil, reason.
local function GetOperatorFromGrid(side, row, col, spec)
    local name, reason = GetOperatorNameFromGrid(spec, row, col)
    if not name then return nil, nil, nil, reason end
    local index = State.operatorIndexByName[side][name]
    if not index then return nil, nil, name, "MISSING" end
    return index, OPERATORS[side][index], name
end

local function SelectOperator(side, index, source)
    State.side = side
    State.opIndex[side] = index
    local op = OPERATORS[side][index]
    LoadOperatorLoadout(op)
    local name = string.upper(op.name)
    if source == "detect" then
        Notify(Sym().check .. " AUTO-DETECTED: " .. name)
    else
        Notify(Sym().arrow .. " OPERATOR: " .. name)
    end
end

local function HandleSelectionClick()
    local rawX, rawY = GetSelectionPosition()
    if not rawX then
        Notify(Sym().cross .. " GetMousePosition() unavailable - use the next/prev operator keybinds")
        return
    end
    Debug("MOUSE", "raw=%d,%d", math.floor(rawX), math.floor(rawY))
    local nx, ny = NormalizeCoordinates(rawX, rawY)
    Debug("MOUSE", "norm=%.4f,%.4f", nx, ny)

    if State.calibration.active then
        RecordCalibrationPoint(nx, ny)
        return
    end
    if not State.enabled then
        Notify(Sym().cross .. " SYSTEM IS OFF - turn it on with " .. BindText(CONFIG.input.keybinds.toggleSystem))
        return
    end

    local side = State.side
    local spec = GetGridSpec(side)
    Debug("GRID", "side=%s dimensions=%dx%d (cols x rows)", side, spec.columns, spec.rows)
    local row, col = MapCoordinatesToOperatorGrid(nx, ny, spec)
    if not row then
        Debug("GRID", (col == "gap") and "tile gap" or "outside operator grid")
        Notify(Sym().cross .. ((col == "gap") and " CLICK IN GAP BETWEEN TILES" or " CLICK OUTSIDE OPERATOR GRID"))
        return
    end
    Debug("GRID", "row=%d col=%d", row, col)
    local index, op, name, reason = GetOperatorFromGrid(side, row, col, spec)
    if reason == "EMPTY" then
        Debug("MAP", "row=%d col=%d -> EMPTY", row, col)
        Notify(string.format("TILE ROW %d COL %d IS EMPTY", row, col))
        return
    elseif reason == "UNKNOWN" then
        Debug("MAP", "row=%d col=%d -> UNMAPPED (?)", row, col)
        Notify(string.format("%s UNMAPPED TILE: set OPERATOR_GRID.%s.layout[%d][%d] = \"<name>\"",
            Sym().cross, side, row, col))
        return
    elseif reason == "MISSING" then
        Debug("MAP", "row=%d col=%d -> %s (NOT IN DATABASE)", row, col, name)
        Notify(string.format("%s GRID NAME '%s' IS NOT IN OPERATORS.%s", Sym().cross, name, side))
        return
    end
    Debug("MAP", "row=%d col=%d -> %s", row, col, name)
    Debug("DETECT", "%s", name)
    SelectOperator(side, index, "detect")
end

--=====================================================================
-- 11. FAVORITES MANAGER
--=====================================================================
local function IsFavorite(op)
    return State.favorites[op.name] == true
end

local function ToggleFavorite()
    local op = CurrentOperator()
    State.favorites[op.name] = (not State.favorites[op.name]) or nil
    Notify((State.favorites[op.name] and (Sym().star .. " FAVORITED: ") or "  UNFAVORITED: ") .. string.upper(op.name))
end

local function StepOperator(dir)
    local n = #OPERATORS[State.side]
    local idx = ((State.opIndex[State.side] - 1 + dir) % n) + 1
    SelectOperator(State.side, idx, "manual")
end

local function StepFavorite(dir)
    local list = OPERATORS[State.side]
    local n, idx = #list, State.opIndex[State.side]
    for step = 1, n do
        local cand = ((idx - 1 + dir * step) % n) + 1
        if IsFavorite(list[cand]) then
            SelectOperator(State.side, cand, "favorite")
            return
        end
    end
    Notify(Sym().cross .. " NO FAVORITES ON " .. SIDE_LABEL[State.side] .. " SIDE")
end

local function ToggleSide()
    local wasCalibrating = State.calibration.active
    State.calibration.active, State.calibration.points = false, {}
    State.side = (State.side == "attackers") and "defenders" or "attackers"
    LoadOperatorLoadout(CurrentOperator())
    Notify(Sym().arrow .. " SIDE: " .. SIDE_LABEL[State.side] ..
        (wasCalibrating and "  (calibration cancelled)" or ""))
end

--=====================================================================
-- 12. CONSOLE RENDERER
--=====================================================================
local function TuneValue(f, p)
    local v = p[f.key]
    if v == nil then v = f.def end
    return string.format(f.fmt, v)
end

-- One-line answer to "why isn't the recoil macro doing anything?"
local function RecoilStatus()
    local cfg = CONFIG.recoil
    if not cfg.enabled then return "OFF (CONFIG.recoil.enabled = false)" end
    if not State.enabled then return "OFF (system disabled, RALT+MB5)" end
    local slot = State.loadout.primary
    if State.activeSlot ~= "primary" or not slot or not slot.weapon then return "idle (primary weapon not active)" end
    local p, key, exact = FindRecoilProfile(slot)
    if not p then
        return string.format("no profile for %s + %s + %s", slot.weapon, tostring(slot.barrel), tostring(slot.grip))
    end
    if p.operator and p.operator ~= CurrentOperator().name then return "profile is for " .. p.operator end
    local need = (not exact) and (p.barrel or cfg.requireBarrel) or nil
    if need and slot.barrel ~= need then
        return "idle - needs " .. need .. " (have " .. tostring(slot.barrel) .. ", LSHIFT+MB4)"
    end
    return string.format("READY  %s%s", slot.weapon,
        State.tune.starter[key] and "  (starter values, tune me)" or "")
end

-- What the recoil loop did during the last burst (shows the macro is alive).
local function SprayText()
    local sp = State.spray
    if not sp then return "none yet (hold ADS + fire)" end
    return string.format("%.1fs, %d ticks, pulled %d down, %d %s", sp.ms / 1000, sp.n, sp.y,
        math.abs(sp.x), sp.x < 0 and "left" or "right")
end

-- The single most useful thing to do right now, in plain words.
local function NextHint()
    local kb = CONFIG.input.keybinds
    local cfg = CONFIG.recoil
    if not State.enabled then return "System is OFF. Turn it on: " .. BindText(kb.toggleSystem) end
    if State.calibration.active then
        return "Calibrating: hover the corner, press " .. BindText(kb.toggleCalibration)
            .. " (" .. BindText(kb.resetCalibration) .. " cancels)"
    end
    if State.tune.active then return "Tuning: spray at a wall, then answer with MB5 / MB4" end
    if not cfg.enabled then return "Recoil is disabled in CONFIG.recoil.enabled" end
    local slot = State.loadout.primary
    if State.activeSlot ~= "primary" or not slot or not slot.weapon then
        return "Recoil only works on a primary weapon: " .. BindText(kb.nextPrimary) .. " picks one"
    end
    local p, key, exact = FindRecoilProfile(slot)
    if not p then
        return "No profile for this exact loadout. Press " .. BindText(kb.toggleRecoilTune) .. " to create + tune one"
    end
    if p.operator and p.operator ~= CurrentOperator().name then return "This profile belongs to " .. p.operator end
    local need = (not exact) and (p.barrel or cfg.requireBarrel) or nil
    if need and slot.barrel ~= need then
        return "Switch barrel to " .. need .. " (" .. BindText(kb.nextBarrel) .. ")"
    end
    if State.tune.starter[key] then
        return "Starter profile: tune it with " .. BindText(kb.toggleRecoilTune) .. " in the range"
    end
    return "Ready. Hold ADS + fire. Keep the loadout above the same as your in-game one."
end

local function BuildFrame()
    local S = Sym()
    local inner = CONFIG.ui.width - 2
    local textW = inner - 2
    local out = {}
    local function add(s) out[#out + 1] = s end
    local function rule(l, r) add(l .. string.rep(S.h, inner) .. r) end
    local function row(text) add(S.v .. " " .. PadRight(USub(text, textW), textW) .. " " .. S.v) end
    local function kv(k, v) row(PadRight(k, 11) .. tostring(v)) end

    local op   = CurrentOperator()
    local slot = State.loadout[State.activeSlot]
    local spec, presetName = GetGridSpec()

    rule(S.tl, S.tr)
    row(Center("SIEGE PROFILE MANAGER", textW))
    rule(S.ml, S.mr)
    kv("SYSTEM", State.enabled and "[ ENABLED ]" or "[ DISABLED ]")
    kv("SIDE", SIDE_LABEL[State.side])
    kv("OPERATOR", (IsFavorite(op) and (S.star .. " ") or "") .. string.upper(op.name))
    local configured = IsConfigured(op)
    local profileId, profile, profileNote
    if configured then
        local function slotText(kind)
            if not HasWeapons(op, kind) then return "NONE" end
            local s = State.loadout[kind]
            return string.format("%s  (%s / %s / %s)", tostring(s.weapon), s.scope or "-",
                s.barrel or "-", s.grip or "-")
        end
        kv("PRIMARY", slotText("primary"))
        kv("SECONDARY", slotText("secondary"))
        kv("EDITING", string.upper(State.activeSlot) .. " - " .. tostring(slot.weapon))
        kv("SCOPE", slot.scope or "-")
        kv("BARREL", slot.barrel or "-")
        kv("GRIP", slot.grip or "-")
        profileId, profile, profileNote = ResolveProfile(op, slot)
        kv("PROFILE", profileId)
        kv("STATUS", ProfileStatusText(profile, profileNote))
    else
        kv("LOADOUT", "NOT CONFIGURED")
        kv("STATUS", "NOT CONFIGURED")
    end
    kv("DPI", CONFIG.dpi)
    kv("SENS", CONFIG.sensitivity.horizontal .. " / " .. CONFIG.sensitivity.vertical)
    kv("ADS", GetADS(slot.scope))
    kv("FOV", CONFIG.fov)
    kv("RECOIL", RecoilStatus())
    kv("LAST SPRAY", SprayText())
    kv("NEXT", NextHint())
    if CONFIG.overlay.enabled then
        kv("OVERLAY", State.exportOk and ("state sent #" .. tostring(State.exportSeq) .. " via OutputDebugMessage (SiegeOverlay.ahk listens)")
            or "OutputDebugMessage() unavailable - overlay cannot receive state")
    end
    kv("SCREEN", string.format("%dx%d (%s)  grid: %s", CONFIG.resolution.width,
        CONFIG.resolution.height, CONFIG.aspectRatio, presetName))

    if not configured then
        kv("REFERENCE", "n/a (loadout not configured)")
    elseif profile then
        local c = CompareProfiles(profile.reference, BuildUserProfile(slot.scope))
        if c.exact then
            kv("REFERENCE", "matches your current settings")
        else
            local function fmt(x) return x and string.format("x%.2f", x) or "n/a" end
            kv("REFERENCE", string.format("eDPI H %s V %s | ADS %s | FOV %+d  (rough guide)",
                fmt(c.h), fmt(c.v), fmt(c.ads), c.fovDelta))
        end
    else
        kv("REFERENCE", "none stored for this exact combination")
    end

    if State.tune.active then
        rule(S.ml, S.mr)
        local tp = FindRecoilProfile(State.loadout.primary)
        if tp then
            local tf = TUNE_FIELDS[State.tune.field]
            local last = (State.tune.field == #TUNE_FIELDS)
            row(string.format("RECOIL TUNE - %s   STEP %d of %d: %s   (now %s)",
                tostring(State.loadout.primary.weapon), State.tune.field, #TUNE_FIELDS,
                tf.label, TuneValue(tf, tp)))
            row("HOW: hold RIGHT mouse (ADS) + LEFT mouse (fire) at a wall, then look at the holes.")
            row(tf.look)
            row(tf.ask)
            local tk = CONFIG.input.tune
            row("Looks good?  " .. BindText(tk.next) .. " = " .. (last and "FINISH" or "next step")
                .. "    " .. BindText(tk.back) .. " = back    " .. BindText(tk.reset) .. " = reset")
        else
            row("RECOIL TUNE - no primary weapon to tune (switch operator/primary)")
        end
    end

    rule(S.ml, S.mr)
    local stats = State.gridStats[State.side]
    row(string.format("OPERATOR GRID - %s   [%d cols x %d rows]   mapped %d / unverified %d / empty %d",
        SIDE_LABEL[State.side], spec.columns, spec.rows, stats.mapped, stats.unknown, stats.empty))
    local list = OPERATORS[State.side]
    local cellW = math.floor(textW / spec.columns)
    for r = 1, spec.rows do
        local cells = {}
        for c = 1, spec.columns do
            local name, reason = GetOperatorNameFromGrid(spec, r, c)
            local cell
            if name then
                local idx = State.operatorIndexByName[State.side][name]
                local o = idx and list[idx]
                local selected = (name == op.name)
                local mark = selected and S.sel or ((o and IsFavorite(o)) and S.star or " ")
                cell = mark .. Clip(selected and string.upper(name) or name, cellW - 1)
            elseif reason == "UNKNOWN" then
                cell = " " .. CELL_UNKNOWN
            else
                cell = " " .. S.empty
            end
            cells[#cells + 1] = PadRight(cell, cellW)
        end
        row(table.concat(cells))
    end

    if CONFIG.ui.showFavorites then
        rule(S.ml, S.mr)
        row("FAVORITES  (" .. S.star .. " = favorite, " .. S.sel .. " = current)")
        local cols = CONFIG.ui.favoritesCols
        local fw = math.floor(textW / cols)
        local cells = {}
        for i, o in ipairs(list) do
            local current = (i == State.opIndex[State.side])
            if IsFavorite(o) or current then
                local mark = (IsFavorite(o) and S.star or " ") .. (current and S.sel or " ")
                cells[#cells + 1] = PadRight(mark .. " " .. string.upper(o.name), fw)
                if #cells == cols then row(table.concat(cells)) cells = {} end
            end
        end
        if #cells > 0 then row(table.concat(cells)) end
    end

    if CONFIG.ui.showControls then
        rule(S.ml, S.mr)
        row("CONTROLS   (RSHIFT + left click on a tile = detect operator)")
        local half = math.floor(textW / 2)
        local cells = {}
        for _, entry in ipairs(ACTION_ORDER) do
            local bind = CONFIG.input.keybinds[entry[1]]
            if bind then
                cells[#cells + 1] = PadRight(BindText(bind) .. " " .. entry[2], half)
                if #cells == 2 then row(table.concat(cells)) cells = {} end
            end
        end
        if #cells > 0 then row(table.concat(cells)) end
    end

    local report = State.calibration.report[State.side]
    if report then
        rule(S.ml, S.mr)
        for _, line in ipairs(report) do row(line) end
    end

    if State.debug then
        rule(S.ml, S.mr)
        row("DEBUG LOG")
        for _, line in ipairs(State.debugLog) do row(line) end
    end

    if #State.warnings > 0 then
        rule(S.ml, S.mr)
        for _, w in ipairs(State.warnings) do row("! " .. w) end
    end

    rule(S.ml, S.mr)
    row(State.message ~= "" and State.message or "Ready.")
    rule(S.bl, S.br)
    return out
end

-- Publishes the same state the console shows, for SiegeOverlay.ahk.
-- Only rewritten when something changed. Returns the state line (or nil).
local function ExportState()
    local cfg = CONFIG.overlay
    if not cfg or not cfg.enabled then return nil end
    local function clean(v)
        return (tostring(v == nil and "-" or v):gsub("[\r\n|]", " "))
    end
    local op   = CurrentOperator()
    local slot = State.loadout[State.activeSlot] or {}
    local prim, sec = State.loadout.primary or {}, State.loadout.secondary or {}
    -- The overlay shows the RECOIL profile state (the old reference-profile list
    -- PROFILE_LIST is empty, so its "not calibrated" text would always show).
    local profileText = "NOT CONFIGURED"
    if IsConfigured(op) then
        if State.activeSlot ~= "primary" then
            profileText = "N/A (secondary)"
        elseif FindRecoilProfile(slot) then
            local _, fk = FindRecoilProfile(slot)
            profileText = State.tune.starter[fk] and "STARTER - tune it" or "TUNED"
        else
            profileText = "NONE - " .. BindText(CONFIG.input.keybinds.toggleRecoilTune) .. " to create"
        end
    end
    local _, gridLabel = GetGridSpec(State.side)
    local cal = State.calibration
    local calText
    if cal.active then
        calText = string.format("ACTIVE %d/2 (%s)", #cal.points + 1, SIDE_LABEL[cal.side or State.side])
    elseif cal.override[State.side] then
        calText = "CALIBRATED"
    else
        calText = "PRESET " .. tostring(gridLabel)
    end
    local fields = {
        { "v", 1 },
        { "enabled", State.enabled and 1 or 0 },
        { "side", SIDE_LABEL[State.side] },
        { "operator", string.upper(op.name) },
        { "slot", string.upper(State.activeSlot) },
        { "primary", HasWeapons(op, "primary") and prim.weapon or "NONE" },
        { "secondary", HasWeapons(op, "secondary") and sec.weapon or "NONE" },
        { "weapon", slot.weapon },
        { "scope", slot.scope },
        { "barrel", slot.barrel },
        { "grip", slot.grip },
        -- the full loadout of BOTH slots, so the overlay can show everything equipped
        { "primary_scope", prim.scope },
        { "primary_barrel", prim.barrel },
        { "primary_grip", prim.grip },
        { "secondary_scope", sec.scope },
        { "secondary_barrel", sec.barrel },
        { "secondary_grip", sec.grip },
        { "profile", profileText },
        { "calibration", calText },
        { "recoil", RecoilStatus() },
        { "next", NextHint() },
        { "spray", SprayText() },
        { "paste", (function()
            local tp, k = FindRecoilProfile(State.loadout.primary)
            return (tp and State.tune.touched[k]) and PasteLine(k, tp) or "-"
        end)() },
        { "tune", State.tune.active and 1 or 0 },
        { "tune_step", State.tune.active and (State.tune.field .. "/" .. #TUNE_FIELDS) or "-" },
        { "tune_name", State.tune.active and TUNE_FIELDS[State.tune.field].label or "-" },
        { "tune_val", State.tune.active and (function()
            local tp, k = FindRecoilProfile(State.loadout.primary)
            if not tp then return "-" end
            local f = TUNE_FIELDS[State.tune.field]
            local o = State.tune.orig[k]
            local base = o and o[f.key]
            if base == nil then base = f.def end
            local delta = (tp[f.key] == nil and f.def or tp[f.key]) - base
            return TuneValue(f, tp) .. (math.abs(delta) > 1e-9 and string.format("  (%+.2f)", delta) or "")
        end)() or "-" },
        { "tune_look", State.tune.active and TUNE_FIELDS[State.tune.field].look or "-" },
        { "tune_ask", State.tune.active and TUNE_FIELDS[State.tune.field].ask or "-" },
        { "tune_next", BindText(CONFIG.input.tune.next) .. " = " ..
            ((State.tune.active and State.tune.field >= #TUNE_FIELDS) and "FINISH" or "next step") },
        { "tune_reset", BindText(CONFIG.input.tune.reset) .. " = reset" },
        { "debug", State.debug and 1 or 0 },
    }
    local parts = {}
    for _, f in ipairs(fields) do parts[#parts + 1] = f[1] .. "=" .. clean(f[2]) end
    local line = table.concat(parts, "|")
    if line == State.exportLast then return line end
    State.exportLast = line
    State.exportSeq = (State.exportSeq or 0) + 1

    State.exportOk = false
    if type(OutputDebugMessage) == "function" then
        -- '%' is stripped elsewhere; the payload never contains one
        State.exportOk = pcall(OutputDebugMessage, "SPMSTATE#" .. State.exportSeq .. "|" .. line .. "\n")
    end
    return line
end

local function Render(force)
    local exportLine = ExportState()
    local lines = BuildFrame()
    local frame = table.concat(lines, "\n")
    if not force and frame == State.lastFrame then return end
    State.lastFrame = frame
    local cleared = false
    if CONFIG.ui.clearLog and type(ClearLog) == "function" then
        cleared = pcall(ClearLog)
    end
    if not cleared then OutputLogMessage(string.rep("\n", 40)) end
    for _, line in ipairs(lines) do
        OutputLogMessage((line:gsub("%%", "")) .. "\n")   -- '%' stripped: OutputLogMessage may treat it as a format code
    end
    for _, line in ipairs(State.tune.lines) do
        OutputLogMessage((line:gsub("%%", "")) .. "\n")
    end
end

--=====================================================================
-- 13. INPUT HANDLER
--=====================================================================
-- RSHIFT+MB5: while calibrating it only cancels; otherwise it resets the
-- saved calibration for this side back to the preset.
local function ResetCalibration()
    local cal = State.calibration
    if cal.active then
        cal.active, cal.points = false, {}
        Notify(Sym().cross .. " CALIBRATION CANCELLED")
        return
    end
    cal.override[State.side], cal.report[State.side] = nil, nil
    Notify(Sym().arrow .. " " .. SIDE_LABEL[State.side] .. " CALIBRATION RESET - using preset again")
end

-- RSHIFT+MB4: first press starts. While calibrating, each further press sets
-- the next corner at the cursor (same as RSHIFT+left click). It no longer cancels.
local function ToggleCalibration()
    local cal = State.calibration
    if cal.active then
        HandleSelectionClick()
        return
    end
    cal.active, cal.points, cal.side = true, {}, State.side
    Notify(string.format("CAL 1/2 %s: hover %s, then RSHIFT+MB4 (RSHIFT+MB5 cancels)", SIDE_LABEL[cal.side],
        CONFIG.grid.calibrationMode == "centers" and "CENTER of tile (1,1)"
        or "outer TOP-LEFT of tile (1,1)"))
end

-- RECOIL TUNE MODE
--   LSHIFT+LMB toggles (CONFIG.input.keybinds.toggleRecoilTune). While active:
--     3 steps: VERTICAL, SIDEWAYS, END OF SPRAY. Watch the bullet holes,
--     MB5 / MB4 (no modifier) answer the question shown
--     next / back / reset keys are CONFIG.input.tune (default LALT+MB5 / LALT+MB4 / LSHIFT+MB4)
--   Edits apply live to the current primary weapon's profile: fire in the
--   range and adjust. A weapon with no profile gets a STARTER_PROFILE.
--   The knobs and live values are shown in the frame; the paste-ready
--   line is printed under it and stays after leaving tune mode.

-- Returns profile, key for the CURRENT exact loadout. create = make one when missing:
-- a copy of the closest existing profile for this weapon (so tuning starts from what
-- works), else a fresh starter.
local function TuneProfile(create)
    local slot = State.loadout.primary
    if not slot or not slot.weapon then return nil end
    local key = RecoilKey(slot)
    local p = RECOIL_PROFILES[key]
    if not p and create then
        local base, baseKey = FindRecoilProfile(slot)
        if base then
            p = CopyTable(base)
            p.barrel = nil                       -- the key already says which loadout this is for
            State.tune.starter[key] = State.tune.starter[baseKey] or nil
        else
            p = CopyTable(STARTER_PROFILE)
            State.tune.starter[key] = true
        end
        State.tune.wasStarter[key] = State.tune.starter[key]
        RECOIL_PROFILES[key] = p
    end
    if p and not State.tune.orig[key] then State.tune.orig[key] = CopyTable(p) end
    return p, key
end

local function TuneRefresh()
    local t = State.tune
    local p, weapon = TuneProfile(true)
    if not p then
        t.lines = {}
        Notify("Recoil tune: no primary weapon to tune")
        return
    end
    local f = TUNE_FIELDS[t.field]
    Notify(string.format("TUNE STEP %d/%d %s = %s  -  %s", t.field, #TUNE_FIELDS, f.label, TuneValue(f, p), f.ask))
    t.lines = { " " .. PasteLine(weapon, p) }
end

local function TuneReset()
    local p, weapon = TuneProfile()
    if not p then return end
    for _, f in ipairs(TUNE_FIELDS) do p[f.key] = nil end
    for k, v in pairs(State.tune.orig[weapon]) do p[k] = v end
    State.tune.starter[weapon] = State.tune.wasStarter[weapon]
    State.tune.touched[weapon] = nil
    TuneRefresh()
    Notify("TUNE " .. weapon .. ": reset to the values you started with")
end

local function TuneAdjust(dir)
    local p, key = TuneProfile(true)
    if not p then TuneRefresh() return end
    local f = TUNE_FIELDS[State.tune.field]
    local cur = p[f.key]
    if cur == nil then cur = f.def end
    -- Tapping the same direction repeatedly speeds up: x1 for presses 1-3, x2 for 4-6, x3, then x4
    local t = State.tune
    local now = GetRunningTime()
    if dir == t.lastDir and (now - t.lastMs) < 1500 then t.streak = t.streak + 1 else t.streak = 0 end
    t.lastDir, t.lastMs = dir, now
    local mult = math.min(4, 1 + math.floor(t.streak / 3))
    local v = math.floor((cur + dir * f.step * mult) * 100 + 0.5) / 100
    p[f.key] = math.max(f.min, v)
    State.tune.starter[key] = nil   -- you've tuned it: no longer a raw starter
    State.tune.touched[key] = true
    TuneRefresh()
end

local function ToggleRecoilTune()
    local t = State.tune
    t.active = not t.active
    if t.active then
        t.field = 1
        TuneProfile(true)
        TuneRefresh()
    else
        Notify(Sym().check .. " TUNING DONE - copy the line under the box into RECOIL_PROFILES to keep it")
        -- t.lines is kept so the final values stay visible
    end
end

-- Returns true when the click was consumed by tune mode.
-- MB5 = +, MB4 = -   |   CONFIG.input.tune: next step (last: finish) / back / reset
local function HandleTuneButton(button, held)
    local t = State.tune
    if not t.active then return false end
    local tk = CONFIG.input.tune
    local function is(bind)
        if bind.mod == "none" then return #held == 0 and button == bind.button end
        return #held == 1 and held[1] == bind.mod and button == bind.button
    end
    if is(tk.up) then
        TuneAdjust(1)
    elseif is(tk.down) then
        TuneAdjust(-1)
    elseif is(tk.next) then
        if t.field >= #TUNE_FIELDS then
            ToggleRecoilTune()          -- last step: finish
        else
            t.field = t.field + 1
            TuneRefresh()
        end
    elseif is(tk.back) then
        t.field = math.max(1, t.field - 1)
        TuneRefresh()
    elseif is(tk.reset) then
        TuneReset()
    else
        return false
    end
    return true
end

-- always = true: still works while the system is disabled.
local ACTIONS = {
    toggleRecoilTune  = { always = true, run = ToggleRecoilTune },
    nextOperator      = { run = function() StepOperator(1) end },
    prevOperator      = { run = function() StepOperator(-1) end },
    nextFavorite      = { run = function() StepFavorite(1) end },
    prevFavorite      = { run = function() StepFavorite(-1) end },
    toggleFavorite    = { run = ToggleFavorite },
    toggleSide        = { run = ToggleSide },
    nextPrimary       = { run = function() CycleWeapon("primary", 1) end },
    nextSecondary     = { run = function() CycleWeapon("secondary", 1) end },
    nextScope         = { run = function() CycleAttachment("scope", 1) end },
    nextBarrel        = { run = function() CycleAttachment("barrel", 1) end },
    nextGrip          = { run = function() CycleAttachment("grip", 1) end },
    toggleSystem      = { always = true, run = function()
        State.enabled = not State.enabled
        Notify(Sym().arrow .. " SYSTEM " .. (State.enabled and "ENABLED" or "DISABLED"))
    end },
    toggleDebug       = { always = true, run = function()
        State.debug = not State.debug
        State.debugLog = {}
        Notify(Sym().arrow .. " DEBUG " .. (State.debug and "ON" or "OFF"))
    end },
    redraw            = { always = true, run = function()
        State.exportLast = nil          -- force the overlay state to be sent again
        Notify("Redrawn. Overlay state resent.")
    end },
    toggleCalibration = { always = true, run = ToggleCalibration },
    resetCalibration  = { always = true, run = ResetCalibration },
}

local function RunAction(name)
    local action = ACTIONS[name]
    if not action then return end
    if not State.enabled and not action.always then return end
    action.run()
end

local function HeldModifiers()
    local held = {}
    for _, m in ipairs(MODIFIERS) do
        if IsModifierPressed(m) then held[#held + 1] = m end
    end
    return held
end

local function BuildBindingIndex()
    local sel = CONFIG.input.selectModifier .. ":" .. CONFIG.input.selectButton
    for action, bind in pairs(CONFIG.input.keybinds) do
        local key = bind.mod .. ":" .. bind.button
        if not ACTIONS[action] then
            Warn("Unknown action in keybinds: " .. action)
        elseif key == sel then
            Warn("Keybind " .. action .. " clashes with the operator-select click")
        elseif State.bindIndex[key] then
            Warn("Keybind clash: " .. action .. " / " .. State.bindIndex[key])
        else
            State.bindIndex[key] = action
        end
    end
end

local function HandleMouseButton(button)
    local held = HeldModifiers()
    if HandleTuneButton(button, held) then return true end
    if #held > 1 and button == CONFIG.input.selectButton then
        -- e.g. Right Shift + another modifier: say so instead of doing nothing
        for _, m in ipairs(held) do
            if m == CONFIG.input.selectModifier then
                Notify(Sym().cross .. " HOLD ONLY " .. string.upper(m) .. " (also held: "
                    .. table.concat(held, "+") .. ")")
                return true
            end
        end
    end
    if #held ~= 1 then return false end
    local mod = held[1]
    local key = mod .. ":" .. button

    local now = GetRunningTime()
    if key == State.lastEventKey and (now - State.lastEventMs) < CONFIG.input.debounceMs then
        return false
    end
    State.lastEventKey, State.lastEventMs = key, now
    Debug("EVENT", "%s button=%d", mod, button)

    if key == (CONFIG.input.selectModifier .. ":" .. CONFIG.input.selectButton) then
        HandleSelectionClick()
        return true
    end
    local action = State.bindIndex[key]
    if action then
        RunAction(action)
        return true
    end
    return false
end

--=====================================================================
-- 13b. RECOIL COMPENSATION  (merged Vora loop)
--=====================================================================
-- Returns the profile for the active operator/weapon, or nil when the
-- macro should stay idle.
local function ActiveRecoilProfile()
    local cfg = CONFIG.recoil
    if not cfg.enabled or not State.enabled or State.calibration.active then return nil end
    if State.activeSlot ~= "primary" then return nil end
    local slot, op = State.loadout.primary, CurrentOperator()
    local p, _, exact = FindRecoilProfile(slot)
    if not p or (p.operator and p.operator ~= op.name) then return nil end
    local need = (not exact) and (p.barrel or cfg.requireBarrel) or nil
    if need and slot.barrel ~= need then return nil end
    return p
end

-- Applies a change of the slot-sync lock key (set by SiegeOverlay.ahk on 1 / 2).
-- Edge-triggered so manual slot changes are not undone. Returns true when the slot changed.
local function SyncSlotFromKeyboard()
    local cfg = CONFIG.slotSync
    if not cfg or not cfg.enabled or type(IsKeyLockOn) ~= "function" then return false end
    local ok, on = pcall(IsKeyLockOn, cfg.lockKey)
    if not ok then return false end
    on = on and true or false
    if State.slotLock == nil then State.slotLock = on return false end   -- first read = baseline
    if on == State.slotLock then return false end
    State.slotLock = on
    local want = on and "secondary" or "primary"
    if State.activeSlot ~= want and HasWeapons(CurrentOperator(), want) then
        State.activeSlot = want
        Debug("SLOT", "keyboard 1/2 -> %s", want)
        return true
    end
    return false
end

-- Blocks (like the original macro) while aim + fire are held.
local function RunRecoil()
    local cfg = CONFIG.recoil
    local p = ActiveRecoilProfile()
    if not p then return end
    local ref = cfg.reference
    local sx = cfg.gain * (ref.dpi * ref.horizontal) / (CONFIG.dpi * CONFIG.sensitivity.horizontal)
    local sy = cfg.gain * (ref.dpi * ref.vertical)   / (CONFIG.dpi * CONFIG.sensitivity.vertical)
    Debug("RECOIL", "%s scale %.3f/%.3f", tostring(State.loadout.primary.weapon), sx, sy)
    while IsMouseButtonPressed(cfg.aimButton) do
        if IsMouseButtonPressed(cfg.fireButton) then
            local start, remX, remY = GetRunningTime(), 0, 0
            local sumX, sumY, ticks = 0, 0, 0
            local strength, side, late = p.strength or 1, p.side or 0, p.late or 1
            while IsMouseButtonPressed(cfg.fireButton) and IsMouseButtonPressed(cfg.aimButton) do
                local t = GetRunningTime() - start
                local mx, my = side, p.r
                if t >= p.tm1 then
                    mx = mx + p.x1
                    if t >= p.tm2 then mx = mx + p.x2 end
                end
                if t >= p.tym1 then
                    my = my + p.y1 * late
                    if t >= p.tym2 then my = my + p.y2 * late end
                end
                my = my * strength
                -- carry the fractional part so the rescale doesn't drift
                local fx, fy = mx * sx + remX, my * sy + remY
                local ix = fx >= 0 and math.floor(fx) or math.ceil(fx)
                local iy = fy >= 0 and math.floor(fy) or math.ceil(fy)
                remX, remY = fx - ix, fy - iy
                MoveMouseRelative(ix, iy)
                sumX, sumY, ticks = sumX + ix, sumY + iy, ticks + 1
                Sleep(cfg.tickMs)
            end
            -- proof for the overlay/console that the macro really fired, and how much it pulled
            State.spray = { ms = GetRunningTime() - start, n = ticks, x = sumX, y = sumY }
            Render()
        else
            Sleep(1)
        end
    end
end

--=====================================================================
-- 14. DATABASE VALIDATION + INITIALISATION
--=====================================================================
-- Warns when `list` contains a name outside the attachment catalogue.
local function CheckAttachmentNames(label, field, list)
    if type(list) ~= "table" then return end
    for _, name in ipairs(list) do
        if IndexOf(ATTACHMENT_CATALOGUE[field], name) == 0 then
            Warn(string.format("%s: invalid %s name '%s'", label, field, tostring(name)))
        end
    end
end

local function ValidateDatabase()
    for _, id in ipairs(WEAPON_DUPLICATES) do
        Warn("duplicate weapon entry: " .. id)
    end
    local incomplete, disputed = {}, {}
    for _, w in ipairs(WEAPON_LIST) do
        if w.kind ~= "primary" and w.kind ~= "secondary" then
            Warn("weapon " .. tostring(w.id) .. ": kind must be primary or secondary")
        end
        for _, field in ipairs(ATTACHMENT_FIELDS) do
            local key = ATTACHMENT_KEY[field]
            CheckAttachmentNames("weapon " .. tostring(w.id), field, w[key])
            if type(w[key]) ~= "table" then
                Warn("weapon " .. tostring(w.id) .. ": " .. key .. " list missing (use {} for none)")
            end
        end
        if w.verified == false then
            incomplete[#incomplete + 1] = w.id
        elseif w.note then
            disputed[#disputed + 1] = w.id
        end
    end
    if #incomplete > 0 then
        Warn("weapons marked verified = false: " .. table.concat(incomplete, ", "))
    end
    if #disputed > 0 then
        Warn("weapons carrying a note: " .. table.concat(disputed, ", "))
    end
    for _, field in ipairs(ATTACHMENT_FIELDS) do
        CheckAttachmentNames("CONFIG.attachments.preferred", field, CONFIG.attachments.preferred[field])
    end

    for _, side in ipairs(SIDE_ORDER) do
        for i, op in ipairs(OPERATORS[side]) do
            local label = side .. "[" .. i .. "] " .. tostring(op.name)
            if not op.name then Warn(label .. ": missing name") end
            for _, field in ipairs(ATTACHMENT_FIELDS) do
                CheckAttachmentNames(label, field, op[ATTACHMENT_KEY[field]])
            end
            if op.weapons and not IsConfigured(op) then
                Warn(label .. ": weapons table has no primary or secondary weapons")
            end
            for _, kind in ipairs(SLOT_KINDS) do
                local list = op.weapons and op.weapons[kind]
                if not list or #list == 0 then
                    -- empty is valid: shield operators have no primary, Blackbeard no secondary
                else
                    local seenWeapon = {}
                    for _, id in ipairs(list) do
                        local w = WEAPONS[id]
                        if seenWeapon[id] then
                            Warn(label .. ": duplicate " .. kind .. " weapon " .. id)
                        end
                        seenWeapon[id] = true
                        if not w then
                            Warn(label .. ": unknown weapon " .. id)
                        elseif w.kind ~= kind then
                            Warn(label .. ": " .. id .. " is a " .. w.kind .. " weapon")
                        end
                    end
                    local def = op.default and op.default[kind]
                    if not def or not def.weapon then
                        Warn(label .. ": no default " .. kind .. " loadout (first weapon will be used)")
                    else
                        if IndexOf(list, def.weapon) == 0 then
                            Warn(label .. ": default " .. kind .. " " .. tostring(def.weapon) .. " is not in its weapon list")
                        end
                        for _, field in ipairs(ATTACHMENT_FIELDS) do
                            local want = def[field]
                            if want ~= nil then
                                if IndexOf(ATTACHMENT_CATALOGUE[field], want) == 0 then
                                    Warn(string.format("%s: default %s %s '%s' is not a valid name",
                                        label, kind, field, tostring(want)))
                                elseif IndexOf(AttachmentOptions(op, def.weapon, field), want) == 0 then
                                    Warn(string.format("%s: default %s %s '%s' is not available on %s",
                                        label, kind, field, want, tostring(def.weapon)))
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Builds State.profileById from PROFILE_LIST and checks every entry.
-- A bad entry is reported, never fatal: lookups just fall back to
-- PROFILE NOT CALIBRATED.
local function BuildProfileIndex()
    for i, p in ipairs(PROFILE_LIST) do
        local label = "profile #" .. i
        if type(p) ~= "table" or type(p.id) ~= "string" or p.id == "" then
            Warn(label .. ": missing id")
        elseif State.profileById[p.id] then
            Warn("duplicate profile id " .. p.id)
        else
            State.profileById[p.id] = p
        end
    end
end

local function ValidateProfiles()
    for i, p in ipairs(PROFILE_LIST) do
        if type(p) == "table" and type(p.id) == "string" and State.profileById[p.id] == p then
            local label = "profile " .. p.id
            local op = FindOperatorByName(p.operator)
            local w = WEAPONS[p.weapon]
            if not op then
                Warn(label .. ": unknown operator " .. tostring(p.operator))
            elseif not w then
                Warn(label .. ": unknown weapon " .. tostring(p.weapon))
            else
                if op.weapons then
                    local list = op.weapons[w.kind]
                    if IndexOf(list, p.weapon) == 0 then
                        Warn(label .. ": " .. p.weapon .. " is not a " .. w.kind .. " weapon of " .. op.name)
                    end
                else
                    Warn(label .. ": " .. op.name .. " has no configured loadout")
                end
                for _, field in ipairs({ "barrel", "grip" }) do
                    local options = AttachmentOptions(op, p.weapon, field)
                    if p[field] == nil then
                        Warn(label .. ": missing " .. field)
                    elseif IndexOf(ATTACHMENT_CATALOGUE[field], p[field]) == 0 then
                        Warn(label .. ": invalid " .. field .. " name '" .. tostring(p[field]) .. "'")
                    elseif IndexOf(options, p[field]) == 0 then
                        Warn(label .. ": " .. p.weapon .. " cannot equip " .. field .. " " .. p[field])
                    end
                end
                if p.scopes ~= nil then
                    if type(p.scopes) ~= "table" then
                        Warn(label .. ": scopes must be a list")
                    else
                        local options = AttachmentOptions(op, p.weapon, "scope")
                        for _, s in ipairs(p.scopes) do
                            if IndexOf(options, s) == 0 then
                                Warn(label .. ": " .. p.weapon .. " cannot equip scope " .. tostring(s))
                            end
                        end
                    end
                end
                local expected = BuildProfileId(p.operator, p.weapon, p.barrel, p.grip)
                if expected ~= p.id then
                    Warn(label .. ": id should be " .. expected .. " for this combination")
                end
            end
            if p.sameAs ~= nil then
                if not State.profileById[p.sameAs] then
                    Warn(label .. ": sameAs " .. tostring(p.sameAs) .. " does not exist")
                elseif p.reference ~= nil then
                    Warn(label .. ": has both sameAs and its own reference (sameAs wins)")
                else
                    local seen, cur = { [p.id] = true }, p.sameAs
                    while cur do
                        if seen[cur] then Warn(label .. ": sameAs loop") break end
                        seen[cur] = true
                        local nxt = State.profileById[cur]
                        cur = nxt and nxt.sameAs or nil
                        if nxt and nxt.sameAs and not State.profileById[nxt.sameAs] then
                            Warn(label .. ": sameAs chain reaches missing " .. nxt.sameAs)
                            break
                        end
                    end
                end
            else
                local ok, badKey = IsValidReference(p.reference)
                if not ok then
                    Warn(label .. ": malformed reference (" .. (badKey and (badKey .. " must be a positive number")
                        or "needs dpi/horizontal/vertical/ads/fov") .. ")")
                end
            end
        end
    end
end

-- name -> OPERATORS index, per side. Screen position is never derived from this.
local function BuildOperatorIndex()
    for _, side in ipairs(SIDE_ORDER) do
        local index = {}
        for i, op in ipairs(OPERATORS[side]) do
            if type(op.name) ~= "string" then
                Warn(side .. "[" .. i .. "]: operator has no name")
            elseif index[op.name] then
                Warn(side .. ": duplicate operator name " .. op.name)
            else
                index[op.name] = i
            end
        end
        State.operatorIndexByName[side] = index
    end
end

local function IsPositiveInt(n)
    return type(n) == "number" and n >= 1 and n == math.floor(n)
end

local function ValidateGrids()
    for _, side in ipairs(SIDE_ORDER) do
        local def = OPERATOR_GRID[side]
        local stats = { mapped = 0, unknown = 0, empty = 0 }
        State.gridStats[side] = stats
        if not def or type(def.layout) ~= "table" then
            Warn(side .. ": OPERATOR_GRID entry missing")
            OPERATOR_GRID[side] = { columns = 1, rows = 1, layout = { { false } } }
            def = OPERATOR_GRID[side]
        end
        if not IsPositiveInt(def.columns) or not IsPositiveInt(def.rows) then
            Warn(side .. ": invalid columns/rows in OPERATOR_GRID")
            def.columns, def.rows = 1, 1
            def.layout = { { false } }
        end
        if #def.layout ~= def.rows then
            Warn(string.format("%s: layout has %d rows but rows=%d", side, #def.layout, def.rows))
        end
        local seen = {}
        for r = 1, def.rows do
            local rowDef = def.layout[r]
            if type(rowDef) ~= "table" then
                Warn(string.format("%s: layout row %d missing", side, r))
                rowDef = {}
            else
                local maxKey = 0
                for k in pairs(rowDef) do
                    if type(k) == "number" and k > maxKey then maxKey = k end
                end
                if #rowDef ~= def.columns or maxKey ~= #rowDef then
                    Warn(string.format("%s: invalid row length in row %d (need %d entries, no nil)",
                        side, r, def.columns))
                end
            end
            for c = 1, def.columns do
                local cell = rowDef[c]
                if not cell or cell == CELL_EMPTY or cell == "empty" then
                    stats.empty = stats.empty + 1
                elseif cell == CELL_UNKNOWN then
                    stats.unknown = stats.unknown + 1
                elseif type(cell) ~= "string" then
                    Warn(string.format("%s: bad cell type at row %d col %d", side, r, c))
                elseif not State.operatorIndexByName[side][cell] then
                    Warn(string.format("%s: grid operator '%s' (row %d col %d) not in database", side, cell, r, c))
                elseif seen[cell] then
                    Warn(string.format("%s: duplicate mapping '%s' at row %d col %d and row %d col %d",
                        side, cell, seen[cell][1], seen[cell][2], r, c))
                else
                    seen[cell] = { r, c }
                    stats.mapped = stats.mapped + 1
                end
            end
        end
        local unmappedOps = 0
        for _, op in ipairs(OPERATORS[side]) do
            if op.name and not seen[op.name] then unmappedOps = unmappedOps + 1 end
        end
        if unmappedOps > 0 then
            Warn(string.format("%s: %d of %d operators have no verified tile yet (edit OPERATOR_GRID)",
                side, unmappedOps, #OPERATORS[side]))
        end
    end

    for name, preset in pairs(CONFIG.grid.presets) do
        for _, side in ipairs(SIDE_ORDER) do
            local geo = preset[side]
            local def = OPERATOR_GRID[side]
            if not geo or not geo.topLeft or not geo.bottomRight or not geo.padding then
                Warn(string.format("preset %s: %s geometry incomplete", name, side))
            else
                local w = (geo.bottomRight.x - geo.topLeft.x) - geo.padding.x * (def.columns - 1)
                local h = (geo.bottomRight.y - geo.topLeft.y) - geo.padding.y * (def.rows - 1)
                if geo.bottomRight.x <= geo.topLeft.x or geo.bottomRight.y <= geo.topLeft.y
                    or w <= 0 or h <= 0 then
                    Warn(string.format("preset %s: invalid %s geometry (corners/padding)", name, side))
                end
            end
        end
    end
    if not CONFIG.grid.presets[PresetName()] then
        Warn("no grid preset for " .. PresetName() .. ": using " .. CONFIG.grid.fallbackPreset)
    end
end

local function Init()
    BuildOperatorIndex()
    ValidateDatabase()
    BuildProfileIndex()
    ValidateProfiles()
    ValidateGrids()
    BuildBindingIndex()
    for _, side in ipairs(SIDE_ORDER) do
        for _, op in ipairs(OPERATORS[side]) do
            if op.favorite then State.favorites[op.name] = true end
        end
    end
    if not OPERATORS[State.side] then State.side = "attackers" end
    if type(GetMousePosition) ~= "function" then
        Warn("GetMousePosition() missing in this G HUB build: click detection off")
    end
    LoadOperatorLoadout(CurrentOperator())
    SyncSlotFromKeyboard()          -- records the lock key's current state as the baseline
    Notify("Loaded. Enable debug (" .. BindText(CONFIG.input.keybinds.toggleDebug) .. ") to test clicks.")
    Render(true)
end

Init()

--=====================================================================
-- 15. OnEvent  (G HUB entry point)
--=====================================================================
function OnEvent(event, arg, family)
    if event == EVENT_PROFILE_ACTIVE then
        Render(true)
        return
    end
    if State.debug then
        -- Shows EVERY event G HUB delivers, so you can see which number a button reports.
        local held = HeldModifiers()
        Debug("RAW", "%s arg=%s mods=%s", tostring(event), tostring(arg),
            #held > 0 and table.concat(held, "+") or "none")
        if event ~= EVENT_MOUSE_PRESSED or (#held > 0 and not State.bindIndex[held[1] .. ":" .. tostring(arg)]) then
            Render()
        end
    end
    if SyncSlotFromKeyboard() then Render() end
    if event ~= EVENT_MOUSE_PRESSED then return end
    if HandleMouseButton(arg) then Render() return end
    -- No modifier held (menu clicks / binds use one): start recoil control
    if #HeldModifiers() == 0 and (arg == CONFIG.recoil.fireButton or arg == CONFIG.recoil.aimEvent) then
        RunRecoil()
    end
end
