using System.Diagnostics;
using System.Net.Http;
using System.Reflection;

namespace SPM.App;

/// <summary>Checks a version file next to the published exe and replaces the running exe in place.</summary>
public sealed class Updater
{
    public const string BaseUrl = "https://raw.githubusercontent.com/jamalmusialla81-hub/siege-profile-manager/main/app/dist/";
    public static string Current => (Assembly.GetEntryAssembly()?.GetName().Version ?? new Version(0, 0)).ToString(3);
    public string Latest { get; private set; } = "";
    public bool Available => Latest != "" && Version.TryParse(Latest, out var l) && Version.TryParse(Current, out var c) && l > c;

    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(3) };

    public async Task<string> CheckAsync()
    {
        try
        {
            Latest = (await Http.GetStringAsync(BaseUrl + "version.txt?t=" + DateTime.UtcNow.Ticks)).Trim();
            return Available ? $"Update available: {Latest} (you have {Current})" : $"You are up to date ({Current})";
        }
        catch (Exception e)
        {
            return e.Message.Contains("404") ? "Can't reach the update files (the GitHub repo is private, see the note below)" : "Update check failed: " + e.Message;
        }
    }

    /// <summary>Downloads the new exe, swaps it in (a running exe can be renamed), starts it and returns true so the caller can quit.</summary>
    public async Task<(bool ok, string msg)> InstallAsync()
    {
        try
        {
            string exe = Environment.ProcessPath ?? "";
            if (exe == "" || !File.Exists(exe)) return (false, "can't find the running exe");
            string neu = exe + ".new", old = exe + ".old";
            var bytes = await Http.GetByteArrayAsync(BaseUrl + "SiegeProfileManager.exe?t=" + DateTime.UtcNow.Ticks);
            if (bytes.Length < 5_000_000 || bytes[0] != (byte)'M' || bytes[1] != (byte)'Z') return (false, "the download looked wrong, nothing changed");
            await File.WriteAllBytesAsync(neu, bytes);
            if (File.Exists(old)) File.Delete(old);
            File.Move(exe, old);
            try { File.Move(neu, exe); }
            catch { File.Move(old, exe); throw; }                       // roll back
            Process.Start(new ProcessStartInfo(exe, "--updated") { UseShellExecute = true });
            return (true, "restarting");
        }
        catch (Exception e) { return (false, "update failed: " + e.Message); }
    }

    public static void CleanUp()
    {
        try { var exe = Environment.ProcessPath; if (exe != null && File.Exists(exe + ".old")) File.Delete(exe + ".old"); } catch { }
    }
}
