using System.Text.Json.Serialization;

namespace SPM.Core;

/// <summary>One weapon slot as the Lua reports it. Empty strings mean "pick the default" (the Lua validates every field).</summary>
public sealed class Slot
{
    public string Weapon { get; set; } = "";
    public string Scope { get; set; } = "";
    public string Barrel { get; set; } = "";
    public string Grip { get; set; } = "";
    public Slot Clone() => new() { Weapon = Weapon, Scope = Scope, Barrel = Barrel, Grip = Grip };
    public bool Same(Slot? o) => o != null && Weapon == o.Weapon && Scope == o.Scope && Barrel == o.Barrel && Grip == o.Grip;
}

public sealed class Loadout
{
    public Slot? Primary { get; set; }
    public Slot? Secondary { get; set; }
    public Loadout Clone() => new() { Primary = Primary?.Clone(), Secondary = Secondary?.Clone() };
    public bool Same(Loadout? o) => o != null && (Primary == null ? o.Primary == null : Primary.Same(o.Primary))
        && (Secondary == null ? o.Secondary == null : Secondary.Same(o.Secondary));
}

public sealed class NamedLoadout
{
    public string Name { get; set; } = "";
    public Loadout Loadout { get; set; } = new();
}

public sealed class NamedLoadoutSet
{
    public string Active { get; set; } = "";
    public List<NamedLoadout> List { get; set; } = new();
}

/// <summary>A recoil profile learned for one exact loadout key "WEAPON:BARREL:GRIP".</summary>
public sealed class LearnedProfile
{
    public double R { get; set; }
    public double Y1 { get; set; }
    public double Y2 { get; set; }
    public double Tym1 { get; set; } = 500;
    public double Tym2 { get; set; } = 900;
    public double Side { get; set; }
    public double Strength { get; set; } = 1;
    public double Late { get; set; } = 1;
}

public sealed class Calibration
{
    public double Tlx { get; set; }
    public double Tly { get; set; }
    public double Brx { get; set; }
    public double Bry { get; set; }
    public string Src { get; set; } = "lua";
}

public sealed class KeyBind
{
    public string Mod { get; set; } = "";
    public int Button { get; set; }
}

/// <summary>What the coach has seen and learned for one exact loadout key.</summary>
public sealed class CoachEntry
{
    public string Sig { get; set; } = "";
    public int N { get; set; }
    public double A { get; set; }
    public double B { get; set; }
    public double C { get; set; }
    public double X { get; set; }
    public double Pa { get; set; }
    public double Pb { get; set; }
    public double Pc { get; set; }
    public double Px { get; set; }
    public double T1 { get; set; } = 450;
    public double T2 { get; set; } = 900;
    public double BaseA { get; set; } = -1;
    public double BaseB { get; set; }
    public double BaseC { get; set; }
    public double BaseX { get; set; }
    public List<int> Acc { get; set; } = new();
    public bool Locked { get; set; }
    public string Updated { get; set; } = "";
}

public sealed class CoachSettings
{
    public double PxY { get; set; }          // screen pixels the view moves per mouse count, vertical (0 = not calibrated)
    public double PxX { get; set; }
    public Dictionary<string, CoachEntry> Hist { get; set; } = new();
}

public sealed class GameSettings
{
    public double Dpi { get; set; } = 1600;
    public double SensH { get; set; } = 4;
    public double SensV { get; set; } = 4;
    public double Fov { get; set; } = 84;
    public double Ads { get; set; } = 52;
    public int ResW { get; set; } = 1920;
    public int ResH { get; set; } = 1080;
}

public sealed class Prefs
{
    public string Scope { get; set; } = "AUTO";
    public string Barrel { get; set; } = "SUPPRESSOR";
    public string Grip { get; set; } = "HORIZONTAL";
}

/// <summary>Everything the app remembers. Saved as JSON in %AppData%\SiegeProfileManager\app-config.json.</summary>
public sealed class AppConfig
{
    public int Version { get; set; } = 1;
    public GameSettings Game { get; set; } = new();
    public Prefs Prefs { get; set; } = new();
    public string Side { get; set; } = "attackers";
    public string Operator { get; set; } = "";
    /// <summary>Operator picked in the app: written as the Lua's starting operator (the live operator still comes from the Lua).</summary>
    public string StartOperator { get; set; } = "";
    public string StartSide { get; set; } = "attackers";
    public List<string> Favorites { get; set; } = new();
    public Dictionary<string, Loadout> Saved { get; set; } = new();
    public Dictionary<string, NamedLoadoutSet> Loadouts { get; set; } = new();
    public Dictionary<string, LearnedProfile> Learned { get; set; } = new();
    public Dictionary<string, Calibration> Calibration { get; set; } = new();
    public Dictionary<string, KeyBind> LuaKeybinds { get; set; } = new();
    public CoachSettings Coach { get; set; } = new();
    public string LuaPath { get; set; } = "";
    public string CopiedRev { get; set; } = "";
    public string Baseline { get; set; } = "";
    public bool SeededStandard { get; set; }
    public bool HudVisible { get; set; } = true;
    public bool CoachInMatch { get; set; } = true;
    public bool SlotSyncEnabled { get; set; } = true;
    public bool SlotSyncAnywhere { get; set; }
    public bool AutoWriteLua { get; set; } = true;
    public double HudOpacity { get; set; } = 0.92;
}
