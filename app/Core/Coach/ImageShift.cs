namespace SPM.Core.Coach;

/// <summary>A captured picture: 32-bit B,G,R,A pixels, top-down.</summary>
public sealed class Frame
{
    public int W { get; init; }
    public int H { get; init; }
    public byte[] Bgra { get; init; } = Array.Empty<byte>();
}

/// <summary>Brightness profiles of one picture (already differenced + normalised), used to measure how far the view moved.</summary>
public sealed class Prof
{
    public double[] X { get; init; } = Array.Empty<double>();
    public double[] Y { get; init; } = Array.Empty<double>();
}

public sealed record ShiftResult(int D, double C, double Sec, double Dsub = 0)
{
    public bool Clear => C >= 0.4 && C - Sec >= 0.03;
}

/// <summary>Movement of picture B relative to picture A in pixels. A null axis = unclear.</summary>
public sealed record Move(double? Dx, double? Dy, double Cx, double Cy);

public static class ImageShift
{
    public const int Stp = 6;                       // pixel stride of the analysis

    /// <summary>
    /// Mean brightness per column and per row (every Stp-th pixel), skipping a box around the crosshair, then
    /// first-differenced (kills lighting gradients) and normalised. Null = the picture is blank.
    /// maskCx / maskCy = crosshair position inside the picture.
    /// </summary>
    public static Prof? Profile(Frame f, int maskCx, int maskCy)
    {
        int nx = f.W / Stp, ny = f.H / Stp;
        if (nx < 32 || ny < 32 || f.Bgra.Length < f.W * f.H * 4) return null;
        var sx = new double[nx]; var sy = new double[ny]; var cx = new int[nx]; var cy = new int[ny];
        for (int iy = 0; iy < ny; iy++)
        {
            int y = iy * Stp;
            int row = y * f.W * 4 + 1;                                  // +1 = the green byte, brightness enough
            for (int ix = 0; ix < nx; ix++)
            {
                int x = ix * Stp;
                if (Math.Abs(x - maskCx) > 70 || Math.Abs(y - maskCy) > 70)
                {
                    byte l = f.Bgra[row + x * 4];
                    sx[ix] += l; cx[ix]++;
                    sy[iy] += l; cy[iy]++;
                }
            }
        }
        for (int i = 0; i < nx; i++) sx[i] = cx[i] > 0 ? sx[i] / cx[i] : 0;
        for (int i = 0; i < ny; i++) sy[i] = cy[i] > 0 ? sy[i] / cy[i] : 0;
        var px = Prep(sx); var py = Prep(sy);
        return px == null || py == null ? null : new Prof { X = px, Y = py };
    }

    static double[]? Prep(double[] arr)
    {
        int n = arr.Length - 1;
        if (n < 30) return null;
        var dif = new double[n];
        for (int i = 0; i < n; i++) dif[i] = arr[i + 1] - arr[i];
        double m = dif.Average();
        double ss = 0;
        foreach (var v in dif) ss += (v - m) * (v - m);
        double sd = Math.Sqrt(ss / n);
        if (sd < 0.02) return null;                                     // truly blank; plain targets have only small variation
        var o = new double[n];
        for (int i = 0; i < n; i++) o[i] = (dif[i] - m) / sd;
        return o;
    }

    /// <summary>d (in samples) such that b[i + d] ~ a[i]; C is its correlation, Sec the best other peak.</summary>
    public static ShiftResult Shift(double[] a, double[] b, int maxd)
    {
        int n = Math.Min(a.Length, b.Length);
        double best = -2; int bd = 0;
        var cs = new double[2 * maxd + 1];
        for (int d = -maxd; d <= maxd; d++)
        {
            double s = 0; int cnt = 0;
            int i0 = Math.Max(0, -d), i1 = Math.Min(n - 1, n - 1 - d);
            for (int i = i0; i <= i1; i++) { s += a[i] * b[i + d]; cnt++; }
            double c = cnt > n / 2 ? s / cnt : -1;
            cs[d + maxd] = c;
            if (c > best) { best = c; bd = d; }
        }
        double sec = -2;
        for (int k = 0; k < cs.Length; k++)
            if (Math.Abs(k - maxd - bd) > 3 && cs[k] > sec) sec = cs[k];
        // sub-sample position: parabola through the peak and its two neighbours
        double dsub = bd;
        int k0 = bd + maxd;
        if (k0 > 0 && k0 < cs.Length - 1)
        {
            double l = cs[k0 - 1], c0 = cs[k0], r = cs[k0 + 1];
            double den = l - 2 * c0 + r;
            if (den < -1e-9) dsub = bd + Math.Clamp(0.5 * (l - r) / den, -0.5, 0.5);
        }
        return new ShiftResult(bd, best, sec, dsub);
    }

    /// <summary>How far B moved relative to A, per axis, or null when neither axis is usable (reason in why).</summary>
    public static Move? Measure(Prof? a, Prof? b, out string why)
    {
        why = "";
        if (a == null || b == null) { why = "a picture looks blank (is the game in borderless / windowed mode? exclusive fullscreen captures black)"; return null; }
        var sy = Shift(a.Y, b.Y, Math.Min(60, a.Y.Length / 2 - 10));
        var sx = Shift(a.X, b.X, Math.Min(60, a.X.Length / 2 - 10));
        var m = new Move(sx.Clear ? sx.Dsub * Stp : null, sy.Clear ? sy.Dsub * Stp : null, sx.C, sy.C);
        if (m.Dx == null && m.Dy == null)
        {
            why = $"the picture match was unclear (vertical {sy.C:0.00} vs {sy.Sec:0.00}, horizontal {sx.C:0.00} vs {sx.Sec:0.00}; needs 0.40 and a clear gap)";
            return null;
        }
        return m;
    }
}
