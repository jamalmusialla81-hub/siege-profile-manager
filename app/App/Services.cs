using System.Runtime.InteropServices;
using SPM.Core;

namespace SPM.App;

/// <summary>
/// Receives the Lua's OutputDebugMessage text through the Windows debug channel (the same DBWIN mechanism DebugView uses).
/// </summary>
public sealed class DbwinListener : IDisposable
{
    IntPtr _ready, _data, _map, _view;
    Thread? _thread;
    volatile bool _stop;
    public bool Ready { get; private set; }
    public bool Shared { get; private set; }
    public string Error { get; private set; } = "";
    public event Action<int, string>? Message;

    public void Start()
    {
        if (!OperatingSystem.IsWindows()) { Error = "Windows only"; return; }
        try
        {
            _ready = Native.CreateEventW(IntPtr.Zero, false, false, "DBWIN_BUFFER_READY");
            Shared = Marshal.GetLastWin32Error() == 183;                 // ERROR_ALREADY_EXISTS: another debug monitor is running
            _data = Native.CreateEventW(IntPtr.Zero, false, false, "DBWIN_DATA_READY");
            _map = Native.CreateFileMappingW(new IntPtr(-1), IntPtr.Zero, 4, 0, 4096, "DBWIN_BUFFER");
            _view = _map == IntPtr.Zero ? IntPtr.Zero : Native.MapViewOfFile(_map, 4, 0, 0, UIntPtr.Zero);
            if (_ready == IntPtr.Zero || _data == IntPtr.Zero || _view == IntPtr.Zero) { Error = "could not open the debug channel"; return; }
            Ready = true;
            _thread = new Thread(Loop) { IsBackground = true, Name = "DBWIN" };
            _thread.Start();
        }
        catch (Exception e) { Error = e.Message; }
    }

    void Loop()
    {
        while (!_stop)
        {
            Native.SetEvent(_ready);
            if (Native.WaitForSingleObject(_data, 500) != 0) continue;
            try
            {
                int pid = Marshal.ReadInt32(_view);
                var text = Marshal.PtrToStringAnsi(_view + 4) ?? "";
                if (text.StartsWith("SPM")) Message?.Invoke(pid, text);
            }
            catch { }
        }
    }

    public void Dispose()
    {
        _stop = true;
        try { _thread?.Join(800); } catch { }
        if (_view != IntPtr.Zero) Native.UnmapViewOfFile(_view);
        foreach (var h in new[] { _map, _data, _ready }) if (h != IntPtr.Zero) Native.CloseHandle(h);
    }
}

/// <summary>Global keys: F8 window, F9 HUD, and the 1 / 2 weapon keys that drive the Lua's slot sync (Scroll Lock).</summary>
public sealed class HookService : IDisposable
{
    readonly Native.LowLevelKeyboardProc _proc;
    IntPtr _hook;
    readonly ConfigStore _store;
    public static readonly string[] SiegeExes = { "RainbowSix.exe", "RainbowSix_Vulkan.exe", "RainbowSix_BE.exe" };
    public string Slot { get; private set; } = "PRIMARY";

    public event Action? ToggleWindow;
    public event Action? ToggleHud;
    public event Action? SlotChanged;
    public event Action? ToggleTraining;     // F12
    public event Action? CalBegin;           // F11
    public event Action? CalFinish;          // F10

    public HookService(ConfigStore store)
    {
        _store = store;
        _proc = Callback;
    }

    public bool SiegeActive()
    {
        if (_store.Config.SlotSyncAnywhere) return true;
        var exe = Native.ForegroundExe();
        return exe != "" && SiegeExes.Any(e => string.Equals(e, exe, StringComparison.OrdinalIgnoreCase));
    }

    public void Start()
    {
        if (!OperatingSystem.IsWindows()) return;
        _hook = Native.SetWindowsHookExW(Native.WH_KEYBOARD_LL, _proc, Native.GetModuleHandleW(null), 0);
        Native.SetScrollLock(false);                                    // baseline: lock key OFF = primary
    }

    IntPtr Callback(int code, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            if (code >= 0 && (wParam == (IntPtr)Native.WM_KEYDOWN || wParam == (IntPtr)Native.WM_SYSKEYDOWN))
            {
                int vk = Marshal.ReadInt32(lParam);
                int flags = Marshal.ReadInt32(lParam, 8);
                bool injected = (flags & 0x10) != 0;
                if (!injected)
                {
                    if (vk == 0x77) ToggleWindow?.Invoke();                                        // F8
                    else if (vk == 0x78) ToggleHud?.Invoke();                                      // F9
                    else if (vk == 0x79) CalFinish?.Invoke();                                      // F10
                    else if (vk == 0x7A) CalBegin?.Invoke();                                       // F11
                    else if (vk == 0x7B) ToggleTraining?.Invoke();                                 // F12
                    else if ((vk == 0x31 || vk == 0x32) && _store.Config.SlotSyncEnabled && SiegeActive())
                    {
                        Slot = vk == 0x32 ? "SECONDARY" : "PRIMARY";
                        Native.SetScrollLock(Slot == "SECONDARY");
                        SlotChanged?.Invoke();
                    }
                }
            }
        }
        catch { }
        return Native.CallNextHookEx(_hook, code, wParam, lParam);
    }

    public void Dispose()
    {
        if (_hook != IntPtr.Zero) { Native.UnhookWindowsHookEx(_hook); _hook = IntPtr.Zero; }
    }
}
