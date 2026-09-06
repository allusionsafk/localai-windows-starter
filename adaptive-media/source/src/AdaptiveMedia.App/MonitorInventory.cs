using System.Runtime.InteropServices;
namespace AdaptiveMedia;

internal static class MonitorInventory
{
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct MonitorInfo
    {
        public int Size;
        public Rect Bounds, Work;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Device;
    }
    private delegate bool MonitorCallback(nint monitor, nint hdc, ref Rect rect, nint data);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumDisplayMonitors(nint hdc, nint clip, MonitorCallback callback, nint data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetMonitorInfoW")]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);

    public static ScreenInfo[] GetScreens()
    {
        var screens = new List<ScreenInfo>();
        bool Add(nint monitor, nint hdc, ref Rect rect, nint data)
        {
            var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>(), Device = "" };
            if (GetMonitorInfo(monitor, ref info)) screens.Add(new() { Name = info.Device, Primary = (info.Flags & 1) != 0,
                Width = info.Bounds.Right - info.Bounds.Left, Height = info.Bounds.Bottom - info.Bounds.Top,
                WorkWidth = info.Work.Right - info.Work.Left, WorkHeight = info.Work.Bottom - info.Work.Top });
            return true;
        }
        if (!EnumDisplayMonitors(0, 0, Add, 0)) return [];
        return screens.ToArray();
    }
}
