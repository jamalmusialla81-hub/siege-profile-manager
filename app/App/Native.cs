using System.Runtime.InteropServices;
using System.Text;

namespace SPM.App;

/// <summary>The few Win32 calls the app needs. Everything here is guarded so the project also loads on other systems.</summary>
internal static class Native
{
    public delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    // kernel32
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern IntPtr CreateEventW(IntPtr attr, bool manualReset, bool initialState, string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern IntPtr CreateFileMappingW(IntPtr file, IntPtr attr, uint protect, uint maxHigh, uint maxLow, string name);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr MapViewOfFile(IntPtr map, uint access, uint offHigh, uint offLow, UIntPtr bytes);
    [DllImport("kernel32.dll")] public static extern bool UnmapViewOfFile(IntPtr view);
    [DllImport("kernel32.dll")] public static extern bool SetEvent(IntPtr h);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool QueryFullProcessImageNameW(IntPtr proc, uint flags, StringBuilder name, ref uint size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetModuleHandleW(string? name);

    // user32
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetWindowsHookExW(int id, LowLevelKeyboardProc proc, IntPtr mod, uint thread);
    [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] public static extern short GetKeyState(int vk);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [StructLayout(LayoutKind.Sequential)] public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int px, py; }
    [DllImport("user32.dll")] public static extern int GetMessageW(out MSG msg, IntPtr hwnd, uint min, uint max);
    [DllImport("user32.dll")] public static extern IntPtr DispatchMessageW(ref MSG msg);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] public static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);

    public const int WH_KEYBOARD_LL = 13;
    public const int WM_KEYDOWN = 0x0100, WM_SYSKEYDOWN = 0x0104;
    public const int GWL_EXSTYLE = -20;
    public const long WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x08000000;
    public const int VK_SCROLL = 0x91;

    /// <summary>Process name (e.g. "RainbowSix.exe") of the window in front, or "".</summary>
    public static string ForegroundExe()
    {
        if (!OperatingSystem.IsWindows()) return "";
        try
        {
            var h = GetForegroundWindow();
            if (h == IntPtr.Zero) return "";
            GetWindowThreadProcessId(h, out var pid);
            var p = OpenProcess(0x1000, false, pid);       // PROCESS_QUERY_LIMITED_INFORMATION
            if (p == IntPtr.Zero) return "";
            try
            {
                var sb = new StringBuilder(520);
                uint size = (uint)sb.Capacity;
                return QueryFullProcessImageNameW(p, 0, sb, ref size) ? Path.GetFileName(sb.ToString()) : "";
            }
            finally { CloseHandle(p); }
        }
        catch { return ""; }
    }

    /// <summary>The Scroll Lock key is the signal the Lua reads for "primary (off) / secondary (on)".</summary>
    public static void SetScrollLock(bool on)
    {
        if (!OperatingSystem.IsWindows()) return;
        bool cur = (GetKeyState(VK_SCROLL) & 1) != 0;
        if (cur == on) return;
        keybd_event(VK_SCROLL, 0x46, 1, UIntPtr.Zero);
        keybd_event(VK_SCROLL, 0x46, 3, UIntPtr.Zero);
    }

    /// <summary>Presses and releases Scroll Lock once. Never call this from inside a keyboard hook callback.</summary>
    public static void PressScrollLock()
    {
        if (!OperatingSystem.IsWindows()) return;
        keybd_event(VK_SCROLL, 0x46, 1, UIntPtr.Zero);
        keybd_event(VK_SCROLL, 0x46, 3, UIntPtr.Zero);
    }

    /// <summary>Makes a window click-through, non-activating and hidden from Alt+Tab (the HUD).</summary>
    public static void MakeOverlay(IntPtr hwnd)
    {
        if (!OperatingSystem.IsWindows() || hwnd == IntPtr.Zero) return;
        long ex = GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64();
        ex |= WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
        SetWindowLongPtr(hwnd, GWL_EXSTYLE, new IntPtr(ex));
    }
}
