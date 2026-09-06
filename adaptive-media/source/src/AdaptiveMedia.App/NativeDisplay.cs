#nullable disable
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace AdaptiveMedia.Native
{
    public sealed class DisplayColorInfo
    {
        public int Index;
        public uint AdapterLow;
        public int AdapterHigh;
        public uint TargetId;
        public string Name;
        public uint OutputTechnology;
        public bool Supported;
        public bool Enabled;
        public bool ForceDisabled;
    }

    public static class HdrController
    {
        const uint QDC_ONLY_ACTIVE_PATHS = 0x2;
        const int ERROR_INSUFFICIENT_BUFFER = 122;
        const uint GET_TARGET_NAME = 2;
        const uint GET_ADVANCED_COLOR_INFO = 9;
        const uint SET_ADVANCED_COLOR_STATE = 10;

        [StructLayout(LayoutKind.Sequential)]
        public struct LUID { public uint LowPart; public int HighPart; }

        [StructLayout(LayoutKind.Sequential)]
        struct RATIONAL { public uint Numerator; public uint Denominator; }

        [StructLayout(LayoutKind.Sequential)]
        struct REGION { public uint cx; public uint cy; }

        [StructLayout(LayoutKind.Sequential)]
        struct POINTL { public int x; public int y; }

        [StructLayout(LayoutKind.Sequential)]
        struct PATH_SOURCE_INFO
        {
            public LUID adapterId;
            public uint id;
            public uint modeInfoIdx;
            public uint statusFlags;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct PATH_TARGET_INFO
        {
            public LUID adapterId;
            public uint id;
            public uint modeInfoIdx;
            public uint outputTechnology;
            public uint rotation;
            public uint scaling;
            public RATIONAL refreshRate;
            public uint scanLineOrdering;
            [MarshalAs(UnmanagedType.Bool)] public bool targetAvailable;
            public uint statusFlags;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct PATH_INFO
        {
            public PATH_SOURCE_INFO sourceInfo;
            public PATH_TARGET_INFO targetInfo;
            public uint flags;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct SOURCE_MODE
        {
            public uint width;
            public uint height;
            public uint pixelFormat;
            public POINTL position;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct VIDEO_SIGNAL_INFO
        {
            public ulong pixelRate;
            public RATIONAL hSyncFreq;
            public RATIONAL vSyncFreq;
            public REGION activeSize;
            public REGION totalSize;
            public uint videoStandard;
            public uint scanLineOrdering;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct TARGET_MODE { public VIDEO_SIGNAL_INFO targetVideoSignalInfo; }

        [StructLayout(LayoutKind.Explicit)]
        struct MODE_UNION
        {
            [FieldOffset(0)] public TARGET_MODE targetMode;
            [FieldOffset(0)] public SOURCE_MODE sourceMode;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct MODE_INFO
        {
            public uint infoType;
            public uint id;
            public LUID adapterId;
            public MODE_UNION modeInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct DEVICE_INFO_HEADER
        {
            public uint type;
            public uint size;
            public LUID adapterId;
            public uint id;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct TARGET_DEVICE_NAME
        {
            public DEVICE_INFO_HEADER header;
            public uint flags;
            public uint outputTechnology;
            public ushort edidManufactureId;
            public ushort edidProductCodeId;
            public uint connectorInstance;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string monitorFriendlyDeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string monitorDevicePath;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct GET_COLOR_INFO
        {
            public DEVICE_INFO_HEADER header;
            public uint value;
            public uint colorEncoding;
            public uint bitsPerColorChannel;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct SET_COLOR_STATE
        {
            public DEVICE_INFO_HEADER header;
            public uint value;
        }

        [DllImport("user32.dll")]
        static extern int GetDisplayConfigBufferSizes(uint flags, out uint pathCount, out uint modeCount);

        [DllImport("user32.dll")]
        static extern int QueryDisplayConfig(uint flags, ref uint pathCount, [Out] PATH_INFO[] paths, ref uint modeCount, [Out] MODE_INFO[] modes, IntPtr topologyId);

        [DllImport("user32.dll")]
        static extern int DisplayConfigGetDeviceInfo(ref TARGET_DEVICE_NAME packet);

        [DllImport("user32.dll")]
        static extern int DisplayConfigGetDeviceInfo(ref GET_COLOR_INFO packet);

        [DllImport("user32.dll")]
        static extern int DisplayConfigSetDeviceInfo(ref SET_COLOR_STATE packet);

        static PATH_INFO[] QueryPaths()
        {
            uint pc, mc;
            int err;
            do
            {
                err = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out pc, out mc);
                if (err != 0) throw new InvalidOperationException("GetDisplayConfigBufferSizes failed: " + err);
                PATH_INFO[] paths = new PATH_INFO[pc];
                MODE_INFO[] modes = new MODE_INFO[mc];
                err = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref pc, paths, ref mc, modes, IntPtr.Zero);
                if (err == 0)
                {
                    Array.Resize(ref paths, (int)pc);
                    return paths;
                }
            } while (err == ERROR_INSUFFICIENT_BUFFER);
            throw new InvalidOperationException("QueryDisplayConfig failed: " + err);
        }

        static string GetName(LUID adapter, uint targetId)
        {
            TARGET_DEVICE_NAME p = new TARGET_DEVICE_NAME();
            p.header.type = GET_TARGET_NAME;
            p.header.size = (uint)Marshal.SizeOf(typeof(TARGET_DEVICE_NAME));
            p.header.adapterId = adapter;
            p.header.id = targetId;
            int err = DisplayConfigGetDeviceInfo(ref p);
            if (err == 0 && !String.IsNullOrWhiteSpace(p.monitorFriendlyDeviceName)) return p.monitorFriendlyDeviceName;
            return "Display " + targetId;
        }

        static GET_COLOR_INFO GetColor(LUID adapter, uint targetId)
        {
            GET_COLOR_INFO p = new GET_COLOR_INFO();
            p.header.type = GET_ADVANCED_COLOR_INFO;
            p.header.size = (uint)Marshal.SizeOf(typeof(GET_COLOR_INFO));
            p.header.adapterId = adapter;
            p.header.id = targetId;
            int err = DisplayConfigGetDeviceInfo(ref p);
            if (err != 0) throw new InvalidOperationException("DisplayConfigGetDeviceInfo failed: " + err);
            return p;
        }

        public static DisplayColorInfo[] GetDisplays()
        {
            List<DisplayColorInfo> result = new List<DisplayColorInfo>();
            PATH_INFO[] paths = QueryPaths();
            for (int i = 0; i < paths.Length; i++)
            {
                PATH_INFO path = paths[i];
                DisplayColorInfo item = new DisplayColorInfo();
                item.Index = i;
                item.AdapterLow = path.targetInfo.adapterId.LowPart;
                item.AdapterHigh = path.targetInfo.adapterId.HighPart;
                item.TargetId = path.targetInfo.id;
                item.OutputTechnology = path.targetInfo.outputTechnology;
                item.Name = GetName(path.targetInfo.adapterId, path.targetInfo.id);
                try
                {
                    GET_COLOR_INFO c = GetColor(path.targetInfo.adapterId, path.targetInfo.id);
                    item.Supported = (c.value & 0x1) != 0;
                    item.Enabled = (c.value & 0x2) != 0;
                    item.ForceDisabled = (c.value & 0x8) != 0;
                }
                catch
                {
                    item.Supported = false;
                    item.Enabled = false;
                    item.ForceDisabled = false;
                }
                result.Add(item);
            }
            return result.ToArray();
        }

        public static bool SetState(uint adapterLow, int adapterHigh, uint targetId, bool enable)
        {
            LUID luid = new LUID();
            luid.LowPart = adapterLow;
            luid.HighPart = adapterHigh;
            GET_COLOR_INFO before;
            try { before = GetColor(luid, targetId); }
            catch { return false; }
            bool supported = (before.value & 0x1) != 0;
            bool forced = (before.value & 0x8) != 0;
            if (!supported || (enable && forced)) return false;
            bool current = (before.value & 0x2) != 0;
            if (current == enable) return true;

            SET_COLOR_STATE p = new SET_COLOR_STATE();
            p.header.type = SET_ADVANCED_COLOR_STATE;
            p.header.size = (uint)Marshal.SizeOf(typeof(SET_COLOR_STATE));
            p.header.adapterId = luid;
            p.header.id = targetId;
            p.value = enable ? 1u : 0u;
            if (DisplayConfigSetDeviceInfo(ref p) != 0) return false;
            try
            {
                GET_COLOR_INFO after = GetColor(luid, targetId);
                return ((after.value & 0x2) != 0) == enable;
            }
            catch { return false; }
        }
    }
}