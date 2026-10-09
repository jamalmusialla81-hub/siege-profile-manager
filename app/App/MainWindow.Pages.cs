using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using SPM.Core;
using SPM.Core.Coach;

namespace SPM.App;

public partial class MainWindow
{
    string _opSide = "attackers";
    string _opSel = "";
    readonly Dictionary<string, Button> _tiles = new();
    List<string> _coachKeys = new();
    const string Auto = "AUTO";

    void InitPages()
    {
        C<Button>("SideAtk").Click += (_, _) => { _opSide = "attackers"; BuildGrid(); };
        C<Button>("SideDef").Click += (_, _) => { _opSide = "defenders"; BuildGrid(); };
        C<CheckBox>("FavChk").IsCheckedChanged += (_, _) => { if (!_loading && _opSel != "") _app.Sync.SetFavourite(_opSel, C<CheckBox>("FavChk").IsChecked == true); };
        C<Button>("StartOpBtn").Click += (_, _) =>
        {
            if (_opSel == "") return;
            _app.Store.Config.StartOperator = _opSel; _app.Store.Config.StartSide = _opSide; _app.Store.Touch();
            C<TextBlock>("OpsNote").Text = _opSel + " will be your starting operator once you paste the script into G HUB.";
        };
        foreach (var n in new[] { "PrimBox", "PScopeBox", "PBarrelBox", "PGripBox", "SecBox", "SScopeBox", "SBarrelBox", "SGripBox" })
        {
            var name = n;
            C<ComboBox>(name).SelectionChanged += (_, _) => { if (!_loading) OnLoadoutPick(name); };
        }
        C<CheckBox>("MatchChk").IsCheckedChanged += (_, _) => { if (!_loading) _app.Coach.InMatch = C<CheckBox>("MatchChk").IsChecked == true; };
        C<Button>("TrainBtn").Click += (_, _) => _app.Coach.SetTraining(!_app.Coach.Training);
        C<Button>("CalBeginBtn").Click += (_, _) => C<TextBlock>("CoachStatus").Text = _app.Coach.BeginCalibration() is { Length: > 0 } m ? "⚠ " + m : _app.Coach.Status;
        C<Button>("CalFinishBtn").Click += (_, _) => _app.Coach.FinishCalibration();
        C<Button>("ForgetBtn").Click += (_, _) =>
        {
            int i = C<ListBox>("CoachList").SelectedIndex;
            if (i < 0 || i >= _coachKeys.Count) return;
            CoachBook.Forget(_app.Store.Config, _coachKeys[i]);
            _app.Store.Touch();
        };
        BuildGrid();
    }

    // ---- operator grid ---------------------------------------------------------------------------------
    void BuildGrid()
    {
        var grid = C<UniformGrid>("OpGrid");
        grid.Children.Clear();
        _tiles.Clear();
        var layout = _opSide == "attackers" ? GameData.GridAttackers : GameData.GridDefenders;
        foreach (var row in layout)
            foreach (var name in row)
            {
                var b = new Button { Classes = { "tile" } };
                if (name == null) { b.IsEnabled = false; b.Content = ""; b.Opacity = 0.25; }
                else
                {
                    string n = name;
                    b.Content = n;
                    b.Click += (_, _) => { _opSel = n; RefreshOps(); };
                    _tiles[n] = b;
                }
                grid.Children.Add(b);
            }
        (C<Button>("SideAtk")).Classes.Set("on", _opSide == "attackers");
        (C<Button>("SideDef")).Classes.Set("on", _opSide == "defenders");
        RefreshOps();
    }

    static string Pretty(string v) => v == "" ? Auto : v;
    static string Raw(object? o) => o is string s && s != Auto ? s : "";

    Loadout CurrentLoadout(OperatorInfo op)
    {
        if (_app.Store.Config.Saved.TryGetValue(op.Name, out var lo)) return lo.Clone();
        return new Loadout
        {
            Primary = op.DefaultPrimary != "" ? new Slot { Weapon = op.DefaultPrimary } : null,
            Secondary = op.DefaultSecondary != "" ? new Slot { Weapon = op.DefaultSecondary } : null,
        };
    }

    void FillCombo(string name, IEnumerable<string> items, string current)
    {
        var box = C<ComboBox>(name);
        var list = items.ToList();
        box.ItemsSource = list;
        box.SelectedItem = list.Contains(current) ? current : (list.Count > 0 ? list[0] : null);
    }

    void FillSlot(string kind, OperatorInfo op, Slot? slot, string wBox, string scBox, string baBox, string grBox)
    {
        var weapons = kind == "primary" ? op.Primary : op.Secondary;
        C<ComboBox>(wBox).IsEnabled = weapons.Length > 0;
        if (weapons.Length == 0)
        {
            foreach (var n in new[] { wBox, scBox, baBox, grBox }) { C<ComboBox>(n).ItemsSource = new[] { "none" }; C<ComboBox>(n).SelectedIndex = 0; C<ComboBox>(n).IsEnabled = false; }
            return;
        }
        string w = slot != null && weapons.Contains(slot.Weapon) ? slot.Weapon : weapons[0];
        FillCombo(wBox, weapons, w);
        var info = GameData.Weapon(w);
        FillCombo(scBox, new[] { Auto }.Concat(info?.Scopes ?? Array.Empty<string>()), Pretty(slot?.Scope ?? ""));
        FillCombo(baBox, new[] { Auto }.Concat(info?.Barrels ?? Array.Empty<string>()), Pretty(slot?.Barrel ?? ""));
        FillCombo(grBox, new[] { Auto }.Concat(info?.Grips ?? Array.Empty<string>()), Pretty(slot?.Grip ?? ""));
        foreach (var n in new[] { scBox, baBox, grBox }) C<ComboBox>(n).IsEnabled = true;
    }

    public void RefreshOps()
    {
        var live = Operators.Find(_app.Live.Get("operator"));
        var favs = _app.Store.Config.Favorites;
        foreach (var (name, b) in _tiles)
        {
            b.Content = (favs.Contains(name) ? "★ " : "") + name;
            b.Classes.Set("on", name == _opSel);
            b.Classes.Set("live", name == live);
        }
        var op = _opSel != "" ? GameData.Operator(_opSel) : null;
        C<TextBlock>("OpName").Text = op?.Name.ToUpperInvariant() ?? "Pick an operator";
        if (op == null) return;
        _loading = true;
        C<CheckBox>("FavChk").IsChecked = favs.Contains(op.Name);
        var lo = CurrentLoadout(op);
        FillSlot("primary", op, lo.Primary, "PrimBox", "PScopeBox", "PBarrelBox", "PGripBox");
        FillSlot("secondary", op, lo.Secondary, "SecBox", "SScopeBox", "SBarrelBox", "SGripBox");
        _loading = false;
        if (C<TextBlock>("OpsNote").Text is null or "")
            C<TextBlock>("OpsNote").Text = "Changes are saved at once and reach G HUB when you paste the script. Switching the live operator in game still uses RSHIFT + click or your keys: G HUB lets the script react only to your real mouse.";
    }

    void OnLoadoutPick(string box)
    {
        var op = _opSel != "" ? GameData.Operator(_opSel) : null;
        if (op == null) return;
        var lo = CurrentLoadout(op);
        bool prim = box.StartsWith("Prim") || box.StartsWith("P");
        string wBox = prim ? "PrimBox" : "SecBox";
        Slot? slot = prim ? lo.Primary : lo.Secondary;
        var weapon = Raw(C<ComboBox>(wBox).SelectedItem);
        if (weapon == "") return;
        if (box == wBox || slot == null || slot.Weapon != weapon) slot = new Slot { Weapon = weapon };       // a new weapon: attachments back to AUTO
        else
        {
            var sc = prim ? "PScopeBox" : "SScopeBox"; var ba = prim ? "PBarrelBox" : "SBarrelBox"; var gr = prim ? "PGripBox" : "SGripBox";
            slot = new Slot { Weapon = weapon, Scope = Raw(C<ComboBox>(sc).SelectedItem), Barrel = Raw(C<ComboBox>(ba).SelectedItem), Grip = Raw(C<ComboBox>(gr).SelectedItem) };
        }
        if (prim) lo.Primary = slot; else lo.Secondary = slot;
        _app.Sync.EditLoadout(op.Name, lo);
        C<TextBlock>("OpsNote").Text = "Saved. Paste the script into G HUB to apply it.";
        RefreshOps();
    }

    // ---- coach -------------------------------------------------------------------------------------------
    void RefreshCoach()
    {
        var co = _app.Coach; var cfg = _app.Store.Config;
        _loading = true; C<CheckBox>("MatchChk").IsChecked = co.InMatch; _loading = false;
        C<Button>("TrainBtn").Content = co.Training ? "Stop training  (F12)" : "Start training  (F12)";
        C<TextBlock>("TrainText").Text = co.Training ? "● TRAINING ON" : co.InMatch ? "○ range training off  ·  learning carefully in matches" : "○ off";
        C<TextBlock>("CoachStatus").Text = co.Status;
        C<TextBlock>("PxText").Text = co.Calibrated
            ? $"vertical {cfg.Coach.PxY:0.000} px per count   ·   horizontal {cfg.Coach.PxX:0.000}   (calibrated)"
            : "not calibrated: assuming 0.40 px per count. Calibrating makes the corrections accurate.";
        C<TextBlock>("LastText").Text = co.Last;
        var r = co.LastResult;
        C<TextBlock>("AccText").Text = r == null ? "--" : $"{r.Accuracy:0}%";
        _coachKeys = cfg.Coach.Hist.Keys.OrderBy(k => k, StringComparer.Ordinal).ToList();
        var lines = _coachKeys.Select(k =>
        {
            var e = cfg.Coach.Hist[k];
            cfg.Learned.TryGetValue(k, out var lp);
            string acc = e.Acc.Count > 0 ? e.Acc[^1] + "%" : "-";
            string state = e.Locked ? "LOCKED" : e.N >= CoachBook.Needed ? "improving" : $"{e.N}/{CoachBook.Needed}";
            return $"{k}    sprays {e.Acc.Count}    last {acc}    {state}" + (lp != null ? $"    pull {lp.R:0.0}  y1 {lp.Y1:+0.0;-0.0}  y2 {lp.Y2:+0.0;-0.0}  side {lp.Side:+0.00;-0.00}" : "");
        }).ToList();
        var list = C<ListBox>("CoachList");
        int sel = list.SelectedIndex;
        list.ItemsSource = lines;
        if (sel >= 0 && sel < lines.Count) list.SelectedIndex = sel;
    }
}
