namespace SPM.Core;

/// <summary>Operator names exactly as the Lua spells them (the Lua matches saved loadouts by this name).</summary>
public static class Operators
{
    public static readonly string[] Attackers = { "Striker", "Sledge", "Thatcher", "Ash", "Thermite", "Twitch", "Montagne", "Glaz", "Fuze", "Blitz", "IQ", "Buck", "Blackbeard", "Capitao", "Hibana", "Jackal", "Ying", "Zofia", "Dokkaebi", "Lion", "Finka", "Maverick", "Nomad", "Gridlock", "Nokk", "Amaru", "Kali", "Iana", "Ace", "Zero", "Flores", "Osa", "Sens", "Grim", "Brava", "Ram", "Deimos", "Rauora", "Solid Snake" };
    public static readonly string[] Defenders = { "Sentry", "Smoke", "Mute", "Castle", "Pulse", "Doc", "Rook", "Kapkan", "Tachanka", "Jager", "Bandit", "Frost", "Valkyrie", "Caveira", "Echo", "Mira", "Lesion", "Ela", "Vigil", "Maestro", "Alibi", "Clash", "Kaid", "Mozzie", "Warden", "Goyo", "Wamai", "Oryx", "Melusi", "Aruni", "Thunderbird", "Thorn", "Azami", "Solis", "Fenrir", "Tubarao", "Skopos", "Denari", "Noor" };

    /// <summary>"LESION" / "lesion" -> "Lesion", or null when unknown.</summary>
    public static string? Find(string name)
    {
        foreach (var n in Attackers) if (string.Equals(n, name, StringComparison.OrdinalIgnoreCase)) return n;
        foreach (var n in Defenders) if (string.Equals(n, name, StringComparison.OrdinalIgnoreCase)) return n;
        return null;
    }
}
