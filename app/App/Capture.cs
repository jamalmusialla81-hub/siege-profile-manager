using System.Runtime.InteropServices;
using SPM.Core;
using SPM.Core.Coach;

namespace SPM.App;

/// <summary>Screenshot of part of the primary monitor (GDI BitBlt). Works in borderless / windowed games; exclusive fullscreen returns black.</summary>
public static class ScreenCapture
{
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int w, int h);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr dest, int x, int y, int w, int h, IntPtr src, int sx, int sy, uint rop);
    [DllImport("gdi32.dll")] static extern int GetDIBits(IntPtr dc, IntPtr bmp, uint start, uint lines, byte[] bits, ref BITMAPINFOHEADER bi, uint usage);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);

    [StructLayout(LayoutKind.Sequential)]
    struct BITMAPINFOHEADER
    {
        public uint biSize; public int biWidth; public int biHeight; public ushort biPlanes; public ushort biBitCount;
        public uint biCompression; public uint biSizeImage; public int biXPelsPerMeter; public int biYPelsPerMeter; public uint biClrUsed; public uint biClrImportant;
    }

    public static (int W, int H) PrimarySize() => OperatingSystem.IsWindows() ? (GetSystemMetrics(0), GetSystemMetrics(1)) : (1920, 1080);

    public static Frame? Grab(int x, int y, int w, int h)
    {
        if (!OperatingSystem.IsWindows() || w <= 0 || h <= 0) return null;
        IntPtr hdc = GetDC(IntPtr.Zero), mdc = IntPtr.Zero, bmp = IntPtr.Zero, old = IntPtr.Zero;
        try
        {
            mdc = CreateCompatibleDC(hdc);
            bmp = CreateCompatibleBitmap(hdc, w, h);
            old = SelectObject(mdc, bmp);
            if (!BitBlt(mdc, 0, 0, w, h, hdc, x, y, 0x40CC0020)) return null;      // SRCCOPY | CAPTUREBLT
            var bi = new BITMAPINFOHEADER { biSize = 40, biWidth = w, biHeight = -h, biPlanes = 1, biBitCount = 32 };
            var buf = new byte[w * h * 4];
            if (GetDIBits(mdc, bmp, 0, (uint)h, buf, ref bi, 0) == 0) return null;
            return new Frame { W = w, H = h, Bgra = buf };
        }
        finally
        {
            if (old != IntPtr.Zero) SelectObject(mdc, old);
            if (bmp != IntPtr.Zero) DeleteObject(bmp);
            if (mdc != IntPtr.Zero) DeleteDC(mdc);
            ReleaseDC(IntPtr.Zero, hdc);
        }
    }
}

/// <summary>Physical mouse counts through Windows raw input (a hidden message-only window on its own thread). Passive: it only reads.</summary>
public sealed class RawMouse : IRawMouse, IDisposable
{
    delegate IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASSEXW
    {
        public uint cbSize, style; public IntPtr lpfnWndProc; public int cbClsExtra, cbWndExtra; public IntPtr hInstance, hIcon, hCursor, hbrBackground;
        [MarshalAs(UnmanagedType.LPWStr)] public string? lpszMenuName; [MarshalAs(UnmanagedType.LPWStr)] public string lpszClassName; public IntPtr hIconSm;
    }
    [StructLayout(LayoutKind.Sequential)] struct RAWINPUTDEVICE { public ushort UsagePage, Usage; public uint Flags; public IntPtr Target; }
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int px, py; }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern ushort RegisterClassExW(ref WNDCLASSEXW c);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateWindowExW(uint ex, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] static extern IntPtr DefWindowProcW(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern int GetMessageW(out MSG msg, IntPtr hwnd, uint min, uint max);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessageW(ref MSG msg);
    [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] dev, uint n, uint size);
    [DllImport("user32.dll")] static extern uint GetRawInputData(IntPtr raw, uint cmd, byte[]? data, ref uint size, uint headerSize);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr hwnd);

    readonly object _gate = new();
    readonly List<RawSample> _calib = new();
    readonly List<RawSample> _burst = new();
    readonly Dictionary<long, long> _idle = new();
    volatile bool _capturing, _inBurst;
    IntPtr _hwnd;
    Thread? _thread;
    WndProc? _proc;
    public bool Ready { get; private set; }

    public void Start()
    {
        if (!OperatingSystem.IsWindows()) return;
        var started = new ManualResetEventSlim(false);
        _thread = new Thread(() => Loop(started)) { IsBackground = true, Name = "RawMouse" };
        _thread.SetApartmentState(ApartmentState.STA);
        _thread.Start();
        started.Wait(2000);
    }

    void Loop(ManualResetEventSlim started)
    {
        try
        {
            _proc = Proc;
            var inst = Native.GetModuleHandleW(null);
            var wc = new WNDCLASSEXW { cbSize = (uint)Marshal.SizeOf<WNDCLASSEXW>(), lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_proc), hInstance = inst, lpszClassName = "SPMRawMouse" };
            RegisterClassExW(ref wc);
            _hwnd = CreateWindowExW(0, "SPMRawMouse", "", 0, 0, 0, 0, 0, new IntPtr(-3), IntPtr.Zero, inst, IntPtr.Zero);   // HWND_MESSAGE
            if (_hwnd != IntPtr.Zero)
            {
                var rid = new[] { new RAWINPUTDEVICE { UsagePage = 1, Usage = 2, Flags = 0x100, Target = _hwnd } };      // generic mouse, RIDEV_INPUTSINK
                Ready = RegisterRawInputDevices(rid, 1, (uint)Marshal.SizeOf<RAWINPUTDEVICE>());
            }
        }
        catch { }
        finally { started.Set(); }
        if (_hwnd == IntPtr.Zero) return;
        while (GetMessageW(out var m, IntPtr.Zero, 0, 0) > 0) DispatchMessageW(ref m);
    }

    IntPtr Proc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == 0x00FF)                                                 // WM_INPUT
        {
            try
            {
                uint size = 0;
                uint header = (uint)(8 + 2 * IntPtr.Size);
                GetRawInputData(lParam, 0x10000003, null, ref size, header);
                if (size > 0 && size < 512)
                {
                    var buf = new byte[size];
                    if (GetRawInputData(lParam, 0x10000003, buf, ref size, header) == size && BitConverter.ToUInt32(buf, 0) == 0)   // RIM_TYPEMOUSE
                    {
                        int h = (int)header;
                        ushort flags = BitConverter.ToUInt16(buf, h);
                        if ((flags & 1) == 0)                                // relative movement only
                        {
                            int dx = BitConverter.ToInt32(buf, h + 12), dy = BitConverter.ToInt32(buf, h + 16);
                            long dev = BitConverter.ToInt64(buf, 8);
                            if (dx != 0 || dy != 0)
                                lock (_gate)
                                {
                                    var smp = new RawSample(Clock.Ms, dx, dy, dev);
                                    if (_inBurst) { if (_burst.Count < 20000) _burst.Add(smp); }
                                    else _idle[dev] = _idle.GetValueOrDefault(dev) + Math.Abs(dx) + Math.Abs(dy);   // moved while not firing = a physical mouse
                                    if (_capturing && _calib.Count < 50000) _calib.Add(smp);
                                }
                        }
                    }
                }
            }
            catch { }
        }
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }

    public void BeginCapture() { lock (_gate) _calib.Clear(); _capturing = true; }

    public (long Dx, long Dy) EndCapture()
    {
        _capturing = false;
        var phys = PhysicalDevices();
        lock (_gate)
        {
            long dx = 0, dy = 0;
            foreach (var s in _calib) if (phys.Count == 0 || phys.Contains(s.Dev)) { dx += s.Dx; dy += s.Dy; }
            return (dx, dy);
        }
    }

    public void BeginBurst() { lock (_gate) _burst.Clear(); _inBurst = true; }
    public List<RawSample> EndBurst() { _inBurst = false; lock (_gate) return new List<RawSample>(_burst); }

    /// <summary>Devices that moved at least 300 counts while you were not firing: your real mouse.</summary>
    public HashSet<long> PhysicalDevices()
    {
        lock (_gate) return _idle.Where(k => k.Value >= 300).Select(k => k.Key).ToHashSet();
    }

    public void Dispose()
    {
        if (_hwnd != IntPtr.Zero) PostMessageW(_hwnd, 0x0010, IntPtr.Zero, IntPtr.Zero);   // WM_CLOSE -> loop ends via DestroyWindow
    }
}
