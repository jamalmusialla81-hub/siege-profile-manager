namespace SPM.Core.Coach;

/// <summary>The measured error of one spray, per phase, in the Lua's profile units per tick (+ = the macro pulled too little).</summary>
public sealed class SprayResult
{
    public string Key { get; init; } = "";
    public double Early { get; init; }
    public double Mid { get; init; }
    public double Late { get; init; }
    public double Sideways { get; init; }        // + = you would have to pull RIGHT (view drifted left)
    public double Pa { get; init; }
    public double Pb { get; init; }
    public double Pc { get; init; }
    public double Px { get; init; }
    public double T1 { get; init; }
    public double T2 { get; init; }
    public double Accuracy { get; init; }
    public int UsedIntervals { get; init; }
    public int Intervals { get; init; }
    public double Seconds { get; init; }
    public DateTime Time { get; init; } = DateTime.Now;
}

public sealed class BurstInfo
{
    public double Ms { get; init; }
    public int Ticks { get; init; }
    public double PyCounts { get; init; }
}

public sealed class Pulls
{
    public string Key { get; init; } = "";
    public double A { get; init; }
    public double B { get; init; }
    public double C { get; init; }
    public double X { get; init; }
    public double T1 { get; init; } = 450;
    public double T2 { get; init; } = 900;
    public double Gain { get; init; } = 1;
}

public static class CoachMath
{
    public const double RefDpi = 800, RefH = 11, RefV = 11;
    public static double Clamp(double v, double lo, double hi) => Math.Min(Math.Max(v, lo), hi);

    /// <summary>Turns the pictures taken during one spray into the per-phase error. Null + reason when it cannot be judged.</summary>
    public static SprayResult? Analyze(IReadOnlyList<(long TimeMs, Prof? P)> frames, BurstInfo burst, Pulls pulls, GameSettings g,
        double pxPerCountY, double pxPerCountX, out string why)
    {
        why = "";
        int n = frames.Count;
        if (n < 3) { why = "the spray was too short to sample (hold fire for 0.7 s or more)"; return null; }
        double sy = pulls.Gain * (RefDpi * RefV) / (g.Dpi * g.SensV);
        double sxs = pulls.Gain * (RefDpi * RefH) / (g.Dpi * g.SensH);
        double tpm = burst.Ticks / Math.Max(burst.Ms, 1);               // macro ticks per millisecond
        long t0 = frames[0].TimeMs;
        var sumY = new double[3]; var tkY = new double[3];
        double sumX = 0, tkX = 0; int used = 0; string last = "";
        for (int i = 0; i < n - 1; i++)
        {
            var m = ImageShift.Measure(frames[i].P, frames[i + 1].P, out var w);
            if (m == null) { last = w; continue; }
            double dt = frames[i + 1].TimeMs - frames[i].TimeMs;
            double mid = (frames[i].TimeMs + frames[i + 1].TimeMs) / 2.0 - t0;
            int ph = mid < pulls.T1 ? 0 : mid < pulls.T2 ? 1 : 2;
            double tk = dt * tpm;
            if (m.Dy != null) { sumY[ph] += m.Dy.Value; tkY[ph] += tk; used++; }         // picture moved DOWN = view ended ABOVE = too little pull
            if (m.Dx != null) { sumX += -m.Dx.Value; tkX += tk; }                          // picture moved LEFT = view drifted RIGHT
        }
        if (used < 2) { why = $"too few clear pictures in that spray ({used} of {n - 1})" + (last != "" ? ", last: " + last : ""); return null; }
        var pull = new[] { pulls.A, pulls.B, pulls.C };
        var res = new double[3];
        for (int ph = 0; ph < 3; ph++)
            if (tkY[ph] > 0)
            {
                double mp = Math.Max(pull[ph], 0.5);
                res[ph] = Clamp(sumY[ph] / Math.Max(pxPerCountY, 0.01) / tkY[ph] / sy, -0.5 * mp, 0.5 * mp);
            }
        double mX = tkX > 0 ? Clamp(-(sumX / Math.Max(pxPerCountX, 0.01)) / tkX / sxs, -3, 3) : 0;
        double wacc = 0, wsum = 0;
        for (int ph = 0; ph < 3; ph++)
            if (tkY[ph] > 0) { wacc += Math.Abs(res[ph]) / Math.Max(pull[ph], 0.5) * tkY[ph]; wsum += tkY[ph]; }
        double acc = wsum > 0 ? 100 * (1 - Math.Min(1, wacc / wsum * 2)) : 0;
        return new SprayResult
        {
            Key = pulls.Key, Early = res[0], Mid = res[1], Late = res[2], Sideways = mX,
            Pa = pulls.A, Pb = pulls.B, Pc = pulls.C, Px = pulls.X, T1 = pulls.T1, T2 = pulls.T2,
            Accuracy = acc, UsedIntervals = used, Intervals = n - 1, Seconds = burst.Ms / 1000.0,
        };
    }

    /// <summary>Plain-language verdict for one phase: r = residual, pull = what the macro pulls then.</summary>
    public static string Say(double r, double pull)
    {
        double rel = r / Math.Max(pull, 0.5);
        if (Math.Abs(rel) < 0.05) return "on target";
        return (rel > 0 ? "pulls TOO LITTLE by " : "pulls TOO MUCH by ") + Math.Round(Math.Abs(rel) * 100) + "%";
    }
}

/// <summary>Per-loadout learning: collects sprays, proposes a better profile every few sprays, locks it once accurate.</summary>
public static class CoachBook
{
    public const double Eta = 0.5;                  // fraction of the measured error corrected per proposal
    public const int Needed = 3;                    // sprays on the same profile before a proposal

    static double Bound(double v, double b) => CoachMath.Clamp(v, b > 0.3 ? b * 0.6 : 0, b > 0.3 ? b * 1.5 : 6);

    public static CoachEntry Entry(AppConfig c, string key)
    {
        if (!c.Coach.Hist.TryGetValue(key, out var e)) { e = new CoachEntry(); c.Coach.Hist[key] = e; }
        return e;
    }

    /// <summary>Adds one spray. Returns a new learned profile when this spray completed a round, else null. msg = what happened.</summary>
    public static LearnedProfile? Record(AppConfig c, SprayResult r, out string msg)
    {
        msg = "";
        var e = Entry(c, r.Key);
        string sig = $"{r.Key}|{r.Pa:0.00}|{r.Pb:0.00}|{r.Pc:0.00}|{r.Px:0.00}";
        if (e.Sig != sig)                                              // the game now runs a different profile: start a fresh round
        {
            e.Sig = sig; e.N = 0; e.A = e.B = e.C = e.X = 0; e.Locked = false;
            e.Pa = r.Pa; e.Pb = r.Pb; e.Pc = r.Pc; e.Px = r.Px; e.T1 = r.T1; e.T2 = r.T2;
        }
        if (e.BaseA < 0) { e.BaseA = r.Pa; e.BaseB = r.Pb; e.BaseC = r.Pc; e.BaseX = r.Px; }   // the first profile ever seen bounds all later ones
        e.N++;
        e.A += r.Early; e.B += r.Mid; e.C += r.Late; e.X += r.Sideways;
        e.Updated = DateTime.Now.ToString("MM-dd HH:mm");
        e.Acc.Add((int)Math.Round(r.Accuracy));
        while (e.Acc.Count > 60) e.Acc.RemoveAt(0);
        if (e.N < Needed) { msg = $"{e.N} of {Needed} sprays collected for this profile"; return null; }

        // LOCKED: under 4% error in every phase and tiny sideways drift = accurate, stop chasing noise
        double rel = Math.Max(Math.Abs(e.A / e.N) / Math.Max(e.Pa, 0.5), Math.Max(Math.Abs(e.B / e.N) / Math.Max(e.Pb, 0.5), Math.Abs(e.C / e.N) / Math.Max(e.Pc, 0.5)));
        if (rel < 0.04 && Math.Abs(e.X / e.N) < 0.1)
        {
            e.Locked = true;
            msg = $"profile LOCKED: the last {e.N} sprays were within {rel * 100:0.0}%, nothing to change";
            return null;
        }
        e.Locked = false;
        double a2 = Bound(e.Pa + Eta * e.A / e.N, e.BaseA);
        double b2 = Bound(e.Pb + Eta * e.B / e.N, e.BaseB);
        double c2 = Bound(e.Pc + Eta * e.C / e.N, e.BaseC);
        double x2 = CoachMath.Clamp(e.Px + Eta * e.X / e.N, e.BaseX - 4, e.BaseX + 4);
        var p = new LearnedProfile
        {
            R = Math.Round(a2, 3), Y1 = Math.Round(b2 - a2, 3), Y2 = Math.Round(c2 - b2, 3),
            Tym1 = e.T1, Tym2 = e.T2, Side = Math.Round(x2, 3), Strength = 1, Late = 1,
        };
        c.Learned.TryGetValue(r.Key, out var old);
        bool changed = old == null || Math.Abs(old.R - p.R) > 0.03 || Math.Abs(old.Y1 - p.Y1) > 0.03 || Math.Abs(old.Y2 - p.Y2) > 0.03 || Math.Abs(old.Side - p.Side) > 0.03;
        if (!changed) { msg = "no meaningful change this round"; return null; }
        c.Learned[r.Key] = p;
        msg = $"IMPROVED profile saved from {e.N} sprays (pull {p.R:0.0}, sideways {p.Side:+0.00;-0.00})";
        return p;
    }

    public static void Forget(AppConfig c, string key) { c.Coach.Hist.Remove(key); c.Learned.Remove(key); }
}
