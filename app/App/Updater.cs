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

    /// <summary>
    /// Downloads the new exe and starts it. If the folder the exe sits in can't be written to (Downloads often can't, e.g. Windows
    /// "controlled folder access"), it installs into %LOCALAPPDATA%\SiegeProfileManager instead, makes a desktop shortcut and runs from there.
    /// </summary>
    public async Task<(bool ok, string msg)> InstallAsync()
    {
        try
        {
            string exe = Environment.ProcessPath ?? "";
            if (exe == "" || !File.Exists(exe)) return (false, "can't find the running exe");
            var bytes = await Http.GetByteArrayAsync(BaseUrl + "SiegeProfileManager.exe?t=" + DateTime.UtcNow.Ticks);
            if (bytes.Length < 5_000_000 || bytes[0] != (byte)'M' || bytes[1] != (byte)'Z') return (false, "the download looked wrong, nothing changed");

            string target = exe;
            bool moved = false;
            if (!CanWrite(Path.GetDirectoryName(exe)!) || !TrySwap(exe, bytes))
            {
                string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SiegeProfileManager");
                Directory.CreateDirectory(dir);
                target = Path.Combine(dir, "SiegeProfileManager.exe");
                if (string.Equals(target, exe, StringComparison.OrdinalIgnoreCase)) return (false, "can't write to " + dir);
                if (!TrySwap(target, bytes, exists: File.Exists(target))) return (false, "can't write to " + dir);
                moved = true;
            }
            if (moved) MakeShortcut(target);
            Process.Start(new ProcessStartInfo(target, "--updated") { UseShellExecute = true });
            return (true, moved ? "installed to " + target + " (desktop shortcut made), restarting" : "restarting");
        }
        catch (Exception e) { return (false, "update failed: " + e.Message); }
    }

    static bool CanWrite(string dir)
    {
        try { var t = Path.Combine(dir, ".spm_write_test"); File.WriteAllText(t, "x"); File.Delete(t); return true; } catch { return false; }
    }

    /// <summary>Writes <paramref name="bytes"/> next to <paramref name="exe"/> and renames it into place (the running exe is moved to .old first).</summary>
    static bool TrySwap(string exe, byte[] bytes, bool exists = true)
    {
        string neu = exe + ".new", old = exe + ".old";
        try
        {
            File.WriteAllBytes(neu, bytes);
            if (!exists || !File.Exists(exe)) { File.Move(neu, exe, true); return true; }
            if (File.Exists(old)) File.Delete(old);
            File.Move(exe, old);
            try { File.Move(neu, exe); }
            catch { File.Move(old, exe); throw; }                       // roll back
            return true;
        }
        catch { try { if (File.Exists(neu)) File.Delete(neu); } catch { } return false; }
    }

    static void MakeShortcut(string target)
    {
        try
        {
            string lnk = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "Siege Profile Manager.lnk");
            string ps = $"$s=(New-Object -ComObject WScript.Shell).CreateShortcut('{lnk.Replace("'", "''")}');$s.TargetPath='{target.Replace("'", "''")}';$s.WorkingDirectory='{Path.GetDirectoryName(target)!.Replace("'", "''")}';$s.Save()";
            Process.Start(new ProcessStartInfo("powershell", "-NoProfile -WindowStyle Hidden -Command \"" + ps.Replace("\"", "\\\"") + "\"") { CreateNoWindow = true, UseShellExecute = false });
        }
        catch { }
    }

    public static void CleanUp()
    {
        try { var exe = Environment.ProcessPath; if (exe != null && File.Exists(exe + ".old")) File.Delete(exe + ".old"); } catch { }
    }
}
