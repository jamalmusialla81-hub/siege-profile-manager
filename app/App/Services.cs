using System.Runtime.InteropServices;
using SPM.Core;
using SPM.Core.Coach;

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

/// <summary>
/// Global keys: F8 window, F9 HUD, F10-F12 coach, and the 1 / 2 weapon keys that drive the Lua's slot sync (Scroll Lock).
/// The hook lives on its own thread and its callback only records the key and queues it: Windows waits for a low-level
/// hook before delivering the key to anything, so any slow work in it (foreground check, sending Scroll Lock) lags the
/// whole keyboard. A worker thread does that work.
/// </summary>
public sealed class HookService : IDisposable, IMoveKeys
{
    static readonly HashSet<int> MoveVk = new() { 0x57, 0x41, 0x53, 0x44, 0x51, 0x45, 0x43, 0x20, 0xA2, 0xA3, 0xA0 };   // W A S D Q E C Space Ctrl LShift
    readonly HashSet<int> _down = new();
    long _lastMove;
    public bool ActivitySince(long clockMs) { lock (_down) return _down.Count > 0 || _lastMove >= clockMs; }

    readonly Native.LowLevelKeyboardProc _proc;
    readonly ConfigStore _store;
    readonly System.Collections.Concurrent.BlockingCollection<int> _queue = new();
    readonly SynchronizationContext? _ui;
    IntPtr _hook;
    Thread? _hookThread, _worker;
    volatile bool _stop;
    bool _lockOn;                                                   // our belief about Scroll Lock (kept in step by watching the key)
    public static readonly string[] SiegeExes = { "RainbowSix.exe", "RainbowSix_Vulkan.exe", "RainbowSix_BE.exe" };
    volatile string _slot = "PRIMARY";
    public string Slot => _slot;

    public event Action? ToggleWindow;
    public event Action? ToggleHud;
    public event Action? SlotChanged;
    public event Action? ToggleTraining;     // F12
    public event Action? CalBegin;           // F11
    public event Action? CalFinish;          // F10

    public HookService(ConfigStore store)
    {
        _store = store;
        _ui = SynchronizationContext.Current;
        _proc = Callback;
    }

    void Post(Action? a) { if (a == null) return; if (_ui != null) _ui.Post(_ => a(), null); else a(); }

    public bool SiegeActive()
    {
        if (_store.Config.SlotSyncAnywhere) return true;
        var exe = Native.ForegroundExe();
        return exe != "" && SiegeExes.Any(e => string.Equals(e, exe, StringComparison.OrdinalIgnoreCase));
    }

    public void Start()
    {
        if (!OperatingSystem.IsWindows()) return;
        // baseline: Scroll Lock OFF = primary
        _lockOn = (Native.GetKeyState(Native.VK_SCROLL) & 1) != 0;
        if (_lockOn) { Native.PressScrollLock(); _lockOn = false; }
        var ready = new ManualResetEventSlim(false);
        _hookThread = new Thread(() => HookLoop(ready)) { IsBackground = true, Name = "KbdHook" };
        _hookThread.Start();
        ready.Wait(2000);
        _worker = new Thread(Work) { IsBackground = true, Name = "KbdWork" };
        _worker.Start();
    }

    void HookLoop(ManualResetEventSlim ready)
    {
        _hook = Native.SetWindowsHookExW(Native.WH_KEYBOARD_LL, _proc, Native.GetModuleHandleW(null), 0);
        ready.Set();
        if (_hook == IntPtr.Zero) return;
        while (!_stop && Native.GetMessageW(out var m, IntPtr.Zero, 0, 0) > 0) Native.DispatchMessageW(ref m);
    }

    /// <summary>Runs inside Windows' keyboard path: record and queue only.</summary>
    IntPtr Callback(int code, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            if (code >= 0)
            {
                int msg = (int)wParam;
                bool down = msg == 0x0100 || msg == 0x0104, up = msg == 0x0101 || msg == 0x0105;
                int vk = Marshal.ReadInt32(lParam);
                bool injected = (Marshal.ReadInt32(lParam, 8) & 0x10) != 0;
                if (!injected)
                {
                    if (MoveVk.Contains(vk))
                        lock (_down) { if (down) _down.Add(vk); else if (up) _down.Remove(vk); _lastMove = Clock.Ms; }
                    if (down)
                    {
                        if (vk == Native.VK_SCROLL) _lockOn = !_lockOn;                 // you pressed the real Scroll Lock key
                        else if (vk is 0x77 or 0x78 or 0x79 or 0x7A or 0x7B or 0x31 or 0x32) _queue.TryAdd(vk);
                    }
                }
            }
        }
        catch { }
        return Native.CallNextHookEx(_hook, code, wParam, lParam);
    }

    void Work()
    {
        foreach (var vk in _queue.GetConsumingEnumerable())
        {
            if (_stop) break;
            try
            {
                switch (vk)
                {
                    case 0x77: Post(ToggleWindow); break;                               // F8
                    case 0x78: Post(ToggleHud); break;                                  // F9
                    case 0x79: Post(CalFinish); break;                                  // F10
                    case 0x7A: Post(CalBegin); break;                                   // F11
                    case 0x7B: Post(ToggleTraining); break;                             // F12
                    case 0x31:
                    case 0x32:
                        if (_store.Config.SlotSyncEnabled && SiegeActive())
                        {
                            bool second = vk == 0x32;
                            _slot = second ? "SECONDARY" : "PRIMARY";
                            if (_lockOn != second) { _lockOn = second; Native.PressScrollLock(); }
                            Post(SlotChanged);
                        }
                        break;
                }
            }
            catch { }
        }
    }

    public void Dispose()
    {
        _stop = true;
        _queue.CompleteAdding();
        if (_hook != IntPtr.Zero) { Native.UnhookWindowsHookEx(_hook); _hook = IntPtr.Zero; }
    }
}
