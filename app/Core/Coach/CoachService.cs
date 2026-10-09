using System.Diagnostics;

namespace SPM.Core.Coach;

/// <summary>Physical mouse counts (Windows raw input). Used only to measure how many screen pixels one count moves the view.</summary>
public interface IRawMouse
{
    /// <summary>Calibration: counts of the physical mouse between Begin and End.</summary>
    void BeginCapture();
    (long Dx, long Dy) EndCapture();
    /// <summary>A spray: every raw movement during it, with the device that made it.</summary>
    void BeginBurst();
    List<RawSample> EndBurst();
    /// <summary>Devices that moved while you were NOT firing = your real mouse (the macro's own movement is a different device).</summary>
    HashSet<long> PhysicalDevices();
}

/// <summary>Movement keys (W A S D, crouch, lean, jump...) seen by the keyboard hook.</summary>
public interface IMoveKeys
{
    /// <summary>True when a movement key was pressed, held or released at or after this clock time.</summary>
    bool ActivitySince(long clockMs);
}

/// <summary>
/// The screen coach: while a spray runs it takes a picture of the top-left of the screen every 250 ms, measures how far
/// the picture moved between neighbours (recoil minus the macro's pull = the error of that part of the spray), and feeds
/// <see cref="CoachBook"/>. Training only: in a match the picture changes for other reasons.
/// </summary>
public sealed class CoachService
{
    readonly ConfigStore _store;
    readonly LiveState _live;
    readonly SynchronizationContext? _ui;
    readonly object _gate = new();
    readonly List<(long T, Frame F)> _frames = new();
    System.Threading.Timer? _timer;
    bool _recording, _busy;
    (long T, Frame F)? _calA;

    public Func<(int W, int H)> ScreenSize { get; set; } = () => (1920, 1080);
    public Func<int, int, int, int, Frame?>? Grab { get; set; }
    public Func<bool> Allowed { get; set; } = () => true;
    public IRawMouse? Raw { get; set; }
    public IMoveKeys? Keys { get; set; }
    long _burstStart;
    public bool Matching { get; private set; }                  // the current/last spray was measured in match mode

    /// <summary>Also learn while playing a match (careful mode: skips sprays where you moved, subtracts your own mouse, learns slower).</summary>
    public bool InMatch { get => _store.Config.CoachInMatch; set { _store.Config.CoachInMatch = value; _store.Touch(); Changed?.Invoke(); } }
    public bool Training { get; private set; }
    DateTime _trainUntil = DateTime.MinValue;
    public string Status { get; private set; } = "Training is off";
    public string Last { get; private set; } = "no spray measured yet";
    public SprayResult? LastResult { get; private set; }
    public int Measured { get; private set; }
    public int Skipped { get; private set; }
    public event Action? Changed;

    public CoachService(ConfigStore store, LiveState live)
    {
        _store = store; _live = live;
        _ui = SynchronizationContext.Current;
        live.EventReceived += OnEvent;
    }

    AppConfig C => _store.Config;
    double PxY => C.Coach.PxY > 0 ? C.Coach.PxY : 0.4;
    double PxX => C.Coach.PxX > 0 ? C.Coach.PxX : 0.4;
    public bool Calibrated => C.Coach.PxY > 0 && C.Coach.PxX > 0;

    public void SetTraining(bool on)
    {
        Training = on;
        _trainUntil = on ? DateTime.UtcNow.AddMinutes(20) : DateTime.MinValue;
        Status = on ? "Training is ON (switches itself off after 20 minutes)" : (InMatch ? "Training off: learning carefully during matches" : "Training is off");
        Changed?.Invoke();
    }

    void Post(Action a) { if (_ui != null) _ui.Post(_ => a(), null); else a(); }

    /// <summary>Why the coach is not measuring right now ("" = it is).</summary>
    public string Why()
    {
        if (Training && DateTime.UtcNow > _trainUntil) { Training = false; }
        if (!Training && !InMatch) return "Training is off and match learning is off";
        if (!_live.HasData) return "no live data from G HUB";
        if (!Allowed()) return "Siege is not the active window";
        if (Grab == null) return "screen capture unavailable";
        return "";
    }

    (int X, int Y, int W, int H) Region()
    {
        var (w, h) = ScreenSize();
        return ((int)Math.Round(w * 0.05), (int)Math.Round(h * 0.05), (int)Math.Round(w * 0.60), (int)Math.Round(h * 0.50));
    }

    // ---- bursts ------------------------------------------------------------------------------------
    void OnEvent(Packet p)
    {
        var type = p.Get("type");
        if (type == "burst_start") Start();
        else if (type == "burst_end") End(p);
    }

    void Start()
    {
        lock (_gate) { _frames.Clear(); _recording = false; }
        _timer?.Dispose(); _timer = null;
        var why = Why();
        if (why != "") { Status = "idle: " + why; Changed?.Invoke(); return; }
        if (_busy) return;
        Matching = !Training;
        _burstStart = Clock.Ms;
        Raw?.BeginBurst();
        lock (_gate) _recording = true;
        Snap();
        int every = Matching ? 160 : 250;                       // match sprays are short: sample faster
        _timer = new System.Threading.Timer(_ => Snap(), null, every, every);
    }

    void Snap()
    {
        try
        {
            lock (_gate) { if (!_recording || _frames.Count >= 24) return; }
            var r = Region();
            var f = Grab?.Invoke(r.X, r.Y, r.W, r.H);
            if (f != null) lock (_gate) if (_recording && _frames.Count < 24) _frames.Add((Clock.Ms, f));
        }
        catch (Exception e) { _live.AddLog("screen capture failed: " + e.Message); }
    }

    void End(Packet p)
    {
        _timer?.Dispose(); _timer = null;
        List<(long T, Frame F)> frames;
        lock (_gate) { if (!_recording) return; _recording = false; frames = new(_frames); _frames.Clear(); }
        var hand = Raw?.EndBurst() ?? new List<RawSample>();
        double ms = Num(p.Get("ms")); int ticks = (int)Num(p.Get("ticks")); double py = Num(p.Get("py"));
        if (py <= 0 || ticks < 25) { Skip("hold fire a bit longer (the macro must pull for 0.3 s or more)"); return; }
        if (Matching && !Calibrated) { Skip("match learning needs the pixels-per-count calibration first (Coach page: F11, move the mouse slowly, F10)"); return; }
        if (Matching && ms < 450) { Skip("match mode needs a spray of at least half a second"); return; }
        if (Keys != null && Keys.ActivitySince(_burstStart - 150)) { Skip("you were moving, crouching or leaning during that spray"); return; }
        // the Lua's profile for this loadout, as it was when the burst ended
        var key = Key();
        double pa = Num(_live.Get("pull_a", "x")), pb = Num(_live.Get("pull_b", "x")), pc = Num(_live.Get("pull_c", "x"));
        if (key == "" || double.IsNaN(pa) || double.IsNaN(pb) || double.IsNaN(pc)) { Skip("the Lua did not report a profile for this weapon"); return; }
        var pulls = new Pulls
        {
            Key = key, A = pa, B = pb, C = pc, X = Or0(Num(_live.Get("pull_x", "0"))),
            T1 = OrDef(Num(_live.Get("pull_t1", "x")), 450), T2 = OrDef(Num(_live.Get("pull_t2", "x")), 900), Gain = OrDef(Num(_live.Get("recoil_gain", "1")), 1),
        };
        var burst = new BurstInfo { Ms = ms, Ticks = ticks, PyCounts = py };
        var phys = Raw?.PhysicalDevices() ?? new HashSet<long>();
        var handSamples = hand.Where(h => phys.Count == 0 || phys.Contains(h.Dev)).ToList();
        var g = C.Game; double cy = PxY, cx = PxX;
        var (sw, sh) = ScreenSize(); var reg = Region();
        int mx = sw / 2 - reg.X, my = sh / 2 - reg.Y;
        _busy = true;
        Task.Run(() =>
        {
            try
            {
                var list = frames.Select(f => (f.T, ImageShift.Profile(f.F, mx, my))).ToList();
                var res = CoachMath.Analyze(list, burst, pulls, g, cy, cx, out var why, handSamples, Matching ? 3 : 2);
                Post(() => { _busy = false; if (res == null) Skip(why); else Apply(res); });
            }
            catch (Exception e) { Post(() => { _busy = false; Skip("analysis failed: " + e.Message); }); }
        });
    }

    static double Num(string s) => double.TryParse(s, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var v) ? v : double.NaN;
    static double Or0(double v) => double.IsNaN(v) ? 0 : v;
    static double OrDef(double v, double d) => double.IsNaN(v) ? d : v;

    string Key()
    {
        var w = _live.Get("weapon", "-");
        if (w is "-" or "NONE" or "") return "";
        string b = _live.Get("barrel", "-"), g = _live.Get("grip", "-");
        return $"{w}:{(b == "-" ? "nil" : b)}:{(g == "-" ? "nil" : g)}";
    }

    void Skip(string why)
    {
        Skipped++;
        Last = "skipped: " + why;
        Status = Last;
        Changed?.Invoke();
    }

    void Apply(SprayResult r)
    {
        Measured++;
        LastResult = r;
        var lp = Matching ? CoachBook.Record(C, r, out var msg, 5, 0.35) : CoachBook.Record(C, r, out msg);
        _store.Touch();
        Last = (Matching ? "match: " : "") + $"EARLY {CoachMath.Say(r.Early, r.Pa)}  ·  MID {CoachMath.Say(r.Mid, r.Pb)}  ·  LATE {CoachMath.Say(r.Late, r.Pc)}  ·  sideways "
             + (Math.Abs(r.Sideways) < 0.08 ? "ok" : "drifts " + (r.Sideways < 0 ? "RIGHT" : "LEFT"))
             + $"   ({r.UsedIntervals} of {r.Intervals} clear)";
        Status = (Matching ? "[match] " : "[range] ") + msg;
        if (lp != null) _live.AddRecent("Coach improved " + r.Key);
        _live.AddLog("coach: " + Last + " | " + msg);
        Changed?.Invoke();
    }

    // ---- pixels per mouse count (no injected input: you move the mouse yourself) -------------------
    public bool Calibrating => _calA != null;

    public string BeginCalibration()
    {
        if (Raw == null || Grab == null) return "not available on this system";
        if (!_live.HasData) return "no live data from G HUB";
        if (!Allowed()) return "Siege must be the active window (press the key in the game)";
        var r = Region();
        var f = Grab(r.X, r.Y, r.W, r.H);
        if (f == null) return "screen capture failed";
        _calA = (Environment.TickCount64, f);
        Raw.BeginCapture();
        Status = "Calibrating: aim at a textured wall, hold aim, move the mouse slowly down 1-2 cm, then press the finish key (F10)";
        Changed?.Invoke();
        return "";
    }

    public string FinishCalibration()
    {
        if (_calA == null || Raw == null || Grab == null) return "not started";
        var (dx, dy) = Raw.EndCapture();
        var a = _calA.Value; _calA = null;
        var r = Region();
        var f = Grab(r.X, r.Y, r.W, r.H);
        if (f == null) { Status = "screen capture failed"; Changed?.Invoke(); return Status; }
        var (sw, sh) = ScreenSize();
        int mx = sw / 2 - r.X, my = sh / 2 - r.Y;
        var m = ImageShift.Measure(ImageShift.Profile(a.F, mx, my), ImageShift.Profile(f, mx, my), out var why);
        if (m == null) { Status = "Calibration failed: " + why; Changed?.Invoke(); return Status; }
        var parts = new List<string>();
        if (m.Dy != null && Math.Abs(dy) >= 150) { C.Coach.PxY = Math.Round(Math.Abs(m.Dy.Value) / Math.Abs(dy), 3); parts.Add($"vertical {C.Coach.PxY} px/count ({Math.Abs(dy)} counts)"); }
        if (m.Dx != null && Math.Abs(dx) >= 150) { C.Coach.PxX = Math.Round(Math.Abs(m.Dx.Value) / Math.Abs(dx), 3); parts.Add($"horizontal {C.Coach.PxX} px/count ({Math.Abs(dx)} counts)"); }
        if (parts.Count == 0)
            Status = $"Calibration needs more movement: you moved {Math.Abs(dx)} / {Math.Abs(dy)} counts (need at least 150 on an axis). Try again.";
        else
        {
            if (C.Coach.PxY <= 0) C.Coach.PxY = C.Coach.PxX;
            if (C.Coach.PxX <= 0) C.Coach.PxX = C.Coach.PxY;
            Status = "Calibrated: " + string.Join(", ", parts);
            _store.Touch();
        }
        Changed?.Invoke();
        return Status;
    }
}
