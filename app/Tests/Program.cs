using SPM.Core;

int fails = 0;
void Check(bool ok, string what) { Console.WriteLine((ok ? "PASS  " : "FAIL  ") + what); if (!ok) fails++; }

// ---- protocol -----------------------------------------------------------------------------------
var live = new LiveState();
live.Ingest("SPMSTATE#1|protocol=2|session=ABC|operator=LESION|side=DEFENDER|primary=T-5 SMG|primary_scope=RED DOT A|primary_barrel=SUPPRESSOR|primary_grip=HORIZONTAL|secondary=Q-929|secondary_scope=CUSTOM SIGHT|secondary_barrel=NONE|secondary_grip=NONE|cfgrev=none|cal_attackers=0.13924,0.26597,0.42180,0.88819|cal_defenders=-|end=1\n");
Check(live.Get("operator") == "LESION", "state parsed");
Check(live.Ok == 1 && live.Status == LinkStatus.Connected, "link connected after a packet");
live.Ingest("SPMSTATE#1|protocol=2|session=ABC|operator=X|end=1\n");
Check(live.Duplicates == 1, "duplicate sequence ignored");
live.Ingest("SPMSTATE#9|protocol=2|session=ABC|operator=X\n");
Check(live.Rejected == 1, "cut-off packet rejected (no end=1)");
live.Ingest("SPMSTATE#2|protocol=3|session=ABC|end=1\n");
Check(live.Status == LinkStatus.Mismatch, "wrong protocol reported");

// ---- config + sync ------------------------------------------------------------------------------
var tmp = Path.Combine(Path.GetTempPath(), "spm-test-" + Guid.NewGuid().ToString("N"));
var store = new ConfigStore(tmp);
store.Load();
Check(store.Config.Saved.ContainsKey("Mute") && store.Config.Saved["Mute"].Secondary!.Weapon == "SMG-11", "Mute standard loadout seeded");
Check(store.Config.Saved["Warden"].Secondary!.Weapon == "SMG-12", "Warden standard loadout seeded");
var live2 = new LiveState();
var sync = new SyncService(store, live2);
store.Config.LuaPath = args.Length > 0 ? args[0] : "";
live2.Ingest("SPMSTATE#1|protocol=2|session=S1|operator=LESION|side=DEFENDER|primary=T-5 SMG|primary_scope=RED DOT A|primary_barrel=SUPPRESSOR|primary_grip=HORIZONTAL|secondary=Q-929|secondary_scope=CUSTOM SIGHT|secondary_barrel=NONE|secondary_grip=NONE|cfgrev=none|cal_attackers=0.13924,0.26597,0.42180,0.88819|cal_defenders=-|end=1\n");
Check(store.Config.Operator == "Lesion" && store.Config.Side == "defenders", "operator + side recorded from state");
Check(store.Config.Saved["Lesion"].Primary!.Weapon == "T-5 SMG" && store.Config.Saved["Lesion"].Primary!.Barrel == "SUPPRESSOR", "loadout recorded from state");
Check(store.Config.Calibration.ContainsKey("attackers") && !store.Config.Calibration.ContainsKey("defenders"), "grid adopted from the Lua");
live2.Ingest("SPMEVENT#2|protocol=2|session=S1|type=favourite_changed|operator=Jager|on=1|end=1\n");
Check(store.Config.Favorites.Contains("Jager"), "favourite event recorded");
Check(sync.State() == SyncState.NoBlock, "no block in G HUB -> NoBlock");

store.Config.Learned["SPEAR .308:SUPPRESSOR:HORIZONTAL"] = new LearnedProfile { R = 23.166, Y1 = 3.564, Y2 = 1.782, Side = -0.45 };
store.Config.Favorites.Add("Mute");
var block = LuaBlock.Build(store.Config, "TESTREV");
Check(block.Contains("[\"SPEAR .308:SUPPRESSOR:HORIZONTAL\"] = { r = 23.16600, y1 = 3.56400"), "learned profile exported with the Lua's number format");
Check(block.Contains("operator = \"Lesion\"") && block.Contains("[\"Mute\"] = { primary = { weapon = \"M590A1\""), "operator + seeded loadout exported");

if (args.Length > 0 && File.Exists(args[0]))
{
    var script = File.ReadAllText(args[0]);
    var merged = LuaBlock.Merge(script, store.Config, "TESTREV", out var err);
    Check(merged != null, "block merged into the Lua script (" + err + ")");
    if (merged != null)
    {
        File.WriteAllText(args.Length > 1 ? args[1] : Path.Combine(tmp, "merged.lua"), merged);
        var outside = script[..script.IndexOf(LuaBlock.BeginMark)] == merged[..merged.IndexOf(LuaBlock.BeginMark)];
        Check(outside, "everything before the block is unchanged");
    }
    var built = sync.BuildFullScript(out var e2);
    Check(built != null && File.Exists(sync.MergedPath), "BuildFullScript writes the merged file (" + e2 + ")");
    Check(sync.State() == SyncState.NoBlock, "state still NoBlock until G HUB reports the rev");
    live2.Ingest("SPMSTATE#3|protocol=2|session=S1|operator=LESION|side=DEFENDER|primary=T-5 SMG|cfgrev=" + store.Config.CopiedRev + "|end=1\n");
    Check(sync.State() == SyncState.Ok, "in sync once G HUB reports the copied rev");
    store.Config.Favorites.Add("Rook");
    Check(sync.Pending && sync.State() == SyncState.Pending, "a config change makes it pending");
}


// ---- coach: image measurement + learning (synthetic pictures with known movement) -----------------------
static byte WorldAt(int wx, int wy)
{
    // aperiodic "foam panels": 70 px blocks with a hashed brightness, plus fine stripes whose direction depends on the block
    int cx = (int)Math.Floor(wx / 70.0), cy = (int)Math.Floor(wy / 70.0);
    uint h = (uint)(cx * 73856093) ^ (uint)(cy * 19349663); h ^= h >> 13; h *= 0x5bd1e995; h ^= h >> 15;
    int baseB = 60 + (int)(h % 120);
    bool vert = (h & 0x100) != 0;
    int stripe = ((vert ? wx : wy) / 5) % 2 == 0 ? 18 : -18;
    return (byte)Math.Clamp(baseB + stripe, 0, 255);
}
SPM.Core.Coach.Frame MakeFrame(int w, int h, int dx, int dy)
{
    // dx,dy = how far the CONTENT moved relative to the unshifted view (content moved down = view climbed)
    var f = new byte[w * h * 4];
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++)
        {
            byte v = WorldAt(x - dx + 5000, y - dy + 5000);
            int o = (y * w + x) * 4; f[o] = v; f[o + 1] = v; f[o + 2] = v; f[o + 3] = 255;
        }
    return new SPM.Core.Coach.Frame { W = w, H = h, Bgra = f };
}
{
    int W = 640, H = 300;
    var a = SPM.Core.Coach.ImageShift.Profile(MakeFrame(W, H, 0, 0), W / 2, H / 2);
    var b = SPM.Core.Coach.ImageShift.Profile(MakeFrame(W, H, -30, 60), W / 2, H / 2);
    var m = SPM.Core.Coach.ImageShift.Measure(a, b, out var why);
    Check(m != null && m.Dy != null && Math.Abs(m.Dy.Value - 60) <= 6, $"vertical movement measured (got {m?.Dy}, want 60)");
    Check(m != null && m.Dx != null && Math.Abs(m.Dx.Value + 30) <= 6, $"horizontal movement measured (got {m?.Dx}, want -30)");
    var z = SPM.Core.Coach.ImageShift.Measure(a, SPM.Core.Coach.ImageShift.Profile(MakeFrame(W, H, 0, 0), W / 2, H / 2), out _);
    Check(z != null && z.Dy == 0 && z.Dx == 0, "no movement measured as zero");
    var blank = new SPM.Core.Coach.Frame { W = W, H = H, Bgra = Enumerable.Repeat((byte)128, W * H * 4).ToArray() };
    Check(SPM.Core.Coach.ImageShift.Profile(blank, W / 2, H / 2) == null, "a blank picture is rejected");

    // a spray: the view climbs 24 px every 250 ms in the first half, then stops
    var frames = new List<(long, SPM.Core.Coach.Prof?)>();
    int cum = 0;
    for (int i = 0; i < 7; i++)
    {
        frames.Add((1000 + i * 250, SPM.Core.Coach.ImageShift.Profile(MakeFrame(W, H, 0, cum), W / 2, H / 2)));
        cum += i < 3 ? 24 : 0;
    }
    var g = new GameSettings { Dpi = 1600, SensH = 4, SensV = 4 };
    var pulls = new SPM.Core.Coach.Pulls { Key = "TEST:NONE:NONE", A = 10, B = 12, C = 14, X = 0, T1 = 450, T2 = 900, Gain = 1 };
    var burst = new SPM.Core.Coach.BurstInfo { Ms = 1500, Ticks = 214, PyCounts = 5000 };
    var res = SPM.Core.Coach.CoachMath.Analyze(frames, burst, pulls, g, 0.4, 0.4, out var why2);
    Check(res != null, "spray analysed (" + why2 + ")");
    if (res != null)
    {
        Check(res.Early > 0.3, $"early phase: macro too weak is positive (got {res.Early:0.00})");
        Check(Math.Abs(res.Late) < 0.05, $"late phase: no movement means no error (got {res.Late:0.00})");
        Check(res.Accuracy is > 0 and < 100, $"accuracy computed ({res.Accuracy:0}%)");
        // learning: three sprays with the same error -> a stronger early pull, bounded and saved as a learned profile
        var cfg = new AppConfig();
        LearnedProfile? lp = null; string msg = "";
        for (int i = 0; i < 3; i++) lp = SPM.Core.Coach.CoachBook.Record(cfg, res, out msg);
        Check(lp != null && lp.R > pulls.A && lp.R <= pulls.A * 1.5, $"learned profile pulls harder, within bounds (r={lp?.R}) {msg}");
        Check(cfg.Learned.ContainsKey(res.Key), "learned profile stored for the loadout");
        // accurate sprays lock the profile
        var cfg2 = new AppConfig();
        var good = new SPM.Core.Coach.SprayResult { Key = "G:NONE:NONE", Early = 0.01, Mid = 0.0, Late = -0.01, Sideways = 0.0, Pa = 10, Pb = 12, Pc = 14, T1 = 450, T2 = 900, Accuracy = 99 };
        LearnedProfile? lp2 = null; string msg2 = "";
        for (int i = 0; i < 3; i++) lp2 = SPM.Core.Coach.CoachBook.Record(cfg2, good, out msg2);
        Check(lp2 == null && cfg2.Coach.Hist["G:NONE:NONE"].Locked, "an accurate profile is locked, not changed (" + msg2 + ")");
    }
}


// ---- loadout edits made in the app must survive the Lua's old state until the new script is pasted ------------
{
    var store3 = new ConfigStore(Path.Combine(Path.GetTempPath(), "spm-test-" + Guid.NewGuid().ToString("N")));
    store3.Load();
    var live3 = new LiveState();
    var sync3 = new SyncService(store3, live3);
    live3.Ingest("SPMSTATE#1|protocol=2|session=Z|operator=KAID|side=DEFENDER|primary=AUG A3|primary_scope=RED DOT A|primary_barrel=SUPPRESSOR|primary_grip=HORIZONTAL|secondary=.44 MAG SEMI-AUTO|cfgrev=none|end=1\n");
    Check(store3.Config.Saved["Kaid"].Primary!.Weapon == "AUG A3", "Kaid loadout recorded from the Lua");
    sync3.EditLoadout("Kaid", new Loadout { Primary = new Slot { Weapon = "TCSG12" }, Secondary = new Slot { Weapon = ".44 MAG SEMI-AUTO" } });
    live3.Ingest("SPMSTATE#2|protocol=2|session=Z|operator=KAID|side=DEFENDER|primary=AUG A3|primary_scope=RED DOT A|primary_barrel=SUPPRESSOR|primary_grip=HORIZONTAL|secondary=.44 MAG SEMI-AUTO|cfgrev=none|end=1\n");
    Check(store3.Config.Saved["Kaid"].Primary!.Weapon == "TCSG12", "an edit made in the app is not overwritten by the Lua's old loadout");
    store3.Config.StartOperator = "Mute"; store3.Config.StartSide = "defenders";
    var blk = LuaBlock.Build(store3.Config, "R");
    Check(blk.Contains("operator = \"Mute\"") && blk.Contains("side = \"defenders\""), "starting operator is exported as the Lua's operator");
    live3.Ingest("SPMSTATE#3|protocol=2|session=Z|operator=MUTE|side=DEFENDER|primary=M590A1|secondary=SMG-11|cfgrev=none|end=1\n");
    Check(store3.Config.StartOperator == "", "starting operator cleared once the Lua is on that operator");
    store3.Dispose();
}


// ---- your own mouse movement must not look like recoil error ----------------------------------------------
{
    int W = 640, H = 300;
    var frames = new List<(long, SPM.Core.Coach.Prof?)>();
    int cum = 0;
    for (int i = 0; i < 6; i++)
    {
        frames.Add((1000 + i * 160, SPM.Core.Coach.ImageShift.Profile(MakeFrame(W, H, 0, cum), W / 2, H / 2)));
        cum -= 30;                                       // content moves UP 30 px per interval: the view looks down
    }
    // the physical mouse moved down 75 counts per interval (75 * 0.4 px = 30 px of view movement)
    var hand = new List<SPM.Core.Coach.RawSample>();
    for (int i = 0; i < 5; i++) hand.Add(new SPM.Core.Coach.RawSample(1000 + i * 160 + 80, 0, 75, 1));
    var g2 = new GameSettings { Dpi = 1600, SensH = 4, SensV = 4 };
    var pl = new SPM.Core.Coach.Pulls { Key = "H:NONE:NONE", A = 10, B = 12, C = 14, T1 = 450, T2 = 900, Gain = 1 };
    var bi = new SPM.Core.Coach.BurstInfo { Ms = 800, Ticks = 114, PyCounts = 3000 };
    var without = SPM.Core.Coach.CoachMath.Analyze(frames, bi, pl, g2, 0.4, 0.4, out var w1);
    var with = SPM.Core.Coach.CoachMath.Analyze(frames, bi, pl, g2, 0.4, 0.4, out var w2, hand, 3);
    Check(without != null && without.Early < -0.3, $"without hand data the view looks over-pulled (early {without?.Early:0.00})");
    Check(with != null && Math.Abs(with.Early) < 0.1 && Math.Abs(with.Mid) < 0.1, $"your own mouse movement is subtracted (early {with?.Early:0.00}, mid {with?.Mid:0.00}) {w2}");
}

store.Dispose();
Console.WriteLine(fails == 0 ? "ALL PASSED" : fails + " FAILED");
return fails == 0 ? 0 : 1;
