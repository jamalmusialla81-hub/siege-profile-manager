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

store.Dispose();
Console.WriteLine(fails == 0 ? "ALL PASSED" : fails + " FAILED");
return fails == 0 ? 0 : 1;
