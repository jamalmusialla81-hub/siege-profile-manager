namespace SPM.Core;

public sealed class Packet
{
    public string Kind { get; set; } = "";
    public long Seq { get; set; }
    public int Protocol { get; set; }
    public string Session { get; set; } = "";
    public Dictionary<string, string> F { get; } = new(StringComparer.Ordinal);
    public string Get(string key, string def = "") => F.TryGetValue(key, out var v) ? v : def;
}

/// <summary>
/// Lua -> OutputDebugMessage lines:  KIND#seq|protocol=2|session=ID|key=value|...|end=1
/// A line without the end=1 terminator was cut off and is dropped.
/// </summary>
public static class PacketParser
{
    public const int ProtocolVersion = 2;

    public static IEnumerable<Packet> Parse(string text, Action<string>? reject = null)
    {
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim('\r', ' ', '\0');
            if (line.Length == 0) continue;
            if (!line.StartsWith("SPM")) continue;                   // somebody else's debug output
            var parts = line.Split('|');
            var head = parts[0];
            int hash = head.IndexOf('#');
            if (hash < 0) { reject?.Invoke("no sequence: " + head); continue; }
            var p = new Packet { Kind = head[..hash] };
            if (!long.TryParse(head[(hash + 1)..], out var seq)) { reject?.Invoke("bad sequence"); continue; }
            p.Seq = seq;
            bool ended = false;
            for (int i = 1; i < parts.Length; i++)
            {
                int eq = parts[i].IndexOf('=');
                if (eq <= 0) continue;
                var k = parts[i][..eq];
                var v = parts[i][(eq + 1)..];
                if (k == "end") { ended = v == "1"; continue; }
                if (k == "protocol") { int.TryParse(v, out var pv); p.Protocol = pv; continue; }
                if (k == "session") { p.Session = v; continue; }
                p.F[k] = v;
            }
            if (!ended) { reject?.Invoke("cut off: " + head); continue; }
            yield return p;
        }
    }
}
