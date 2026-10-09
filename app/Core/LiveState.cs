namespace SPM.Core;

public enum LinkStatus { Waiting, Connected, Idle, Lost, Mismatch }

public sealed class LogEntry
{
    public DateTime Time { get; init; } = DateTime.Now;
    public string Text { get; init; } = "";
    public override string ToString() => Time.ToString("HH:mm:ss") + "  " + Text;
}

/// <summary>What the Lua last told us. Thread-safe enough for one writer (the listener) and one reader (the UI).</summary>
public sealed class LiveState
{
    private readonly object _gate = new();
    private Dictionary<string, string> _data = new();
    public string Session { get; private set; } = "";
    public long Seq { get; private set; }
    public int Ok { get; private set; }
    public int Rejected { get; private set; }
    public int Duplicates { get; private set; }
    public int Restarts { get; private set; }
    public int Protocol { get; private set; }
    public DateTime LastPacketUtc { get; private set; } = DateTime.MinValue;
    public List<LogEntry> Recent { get; } = new();
    public List<LogEntry> Log { get; } = new();

    public event Action<Packet>? EventReceived;
    public event Action? StateReceived;

    public string Get(string key, string def = "")
    {
        lock (_gate) return _data.TryGetValue(key, out var v) ? v : def;
    }

    public bool HasData { get { lock (_gate) return _data.Count > 0; } }

    public Dictionary<string, string> Snapshot() { lock (_gate) return new(_data); }

    public double AgeSeconds => LastPacketUtc == DateTime.MinValue ? -1 : (DateTime.UtcNow - LastPacketUtc).TotalSeconds;

    public LinkStatus Status
    {
        get
        {
            if (Protocol != 0 && Protocol != PacketParser.ProtocolVersion) return LinkStatus.Mismatch;
            var age = AgeSeconds;
            if (age < 0) return LinkStatus.Waiting;
            if (age <= 8) return LinkStatus.Connected;
            if (age <= 900) return LinkStatus.Idle;     // the Lua only talks when something happens: silence is normal
            return LinkStatus.Lost;
        }
    }

    public void AddLog(string text)
    {
        lock (_gate)
        {
            Log.Add(new LogEntry { Text = text });
            while (Log.Count > 200) Log.RemoveAt(0);
        }
    }

    public void AddRecent(string text)
    {
        lock (_gate)
        {
            Recent.Add(new LogEntry { Text = text });
            while (Recent.Count > 40) Recent.RemoveAt(0);
        }
    }

    public void Ingest(string text)
    {
        foreach (var p in PacketParser.Parse(text, why => { Rejected++; AddLog("packet rejected: " + why); }))
            Ingest(p);
    }

    public void Ingest(Packet p)
    {
        if (p.Protocol != PacketParser.ProtocolVersion)
        {
            Protocol = p.Protocol;
            Rejected++;
            AddLog($"protocol {p.Protocol} not understood");
            return;
        }
        Protocol = p.Protocol;
        if (p.Session != Session)
        {
            if (Session != "") { Restarts++; AddLog("G HUB script restarted (new session)"); }
            Session = p.Session;
            Seq = 0;
        }
        if (p.Seq <= Seq && p.Seq != 0) { Duplicates++; return; }
        Seq = p.Seq;
        Ok++;
        LastPacketUtc = DateTime.UtcNow;
        switch (p.Kind)
        {
            case "SPMSTATE":
                lock (_gate) _data = new Dictionary<string, string>(p.F);
                StateReceived?.Invoke();
                break;
            case "SPMEVENT":
                EventReceived?.Invoke(p);
                break;
        }
    }
}
