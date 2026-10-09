using System.Diagnostics;

namespace SPM.Core.Coach;

/// <summary>One millisecond clock shared by screen pictures and raw mouse samples.</summary>
public static class Clock
{
    public static long Ms => Stopwatch.GetTimestamp() * 1000 / Stopwatch.Frequency;
}

/// <summary>One raw mouse movement from a physical device (counts), stamped with <see cref="Clock.Ms"/>.</summary>
public readonly record struct RawSample(long T, int Dx, int Dy, long Dev);
