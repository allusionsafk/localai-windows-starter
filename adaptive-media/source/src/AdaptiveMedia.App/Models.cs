using System;

namespace AdaptiveMedia;

public sealed class SystemSummary
{
    public ScreenInfo[] Screens { get; set; } = [];
    public string[] Drivers { get; set; } = [];
    public string Cpu { get; set; } = "Unknown";
    public string MpvPath { get; set; } = "";
    public string? NvidiaAdapter { get; set; }
    public string Computer { get; set; } = "";
    public string Gpu { get; set; } = "Unknown";
    public string Displays { get; set; } = "Unknown";
    public string Audio { get; set; } = "Unknown";
    public string Power { get; set; } = "Unknown";
    public bool HasNvidia { get; set; }
    public bool HdrInteropAvailable { get; set; }
    public bool MpvAvailable { get; set; }
    public bool YtDlpAvailable { get; set; }
    public bool MpcAvailable { get; set; }
}

public sealed class AppSettings
{
    public const int CurrentSchemaVersion = 1;
    public int SchemaVersion { get; set; } = 1;
    public string Profile { get; set; } = "Automatic";
    public bool AutoHdrSwitch { get; set; } = true;
    public bool PreferExternalDisplay { get; set; } = true;
    public bool FullscreenExternal { get; set; } = true;
    public bool HdmiBitstream { get; set; } = false;
    public bool MpcFallback { get; set; } = true;
    public string DefaultUpscaleMode { get; set; } = "Off";
    public string DefaultMotionMode { get; set; } = "Off";
    public bool DefaultCleanup { get; set; } = false;
    public string DefaultCleanupMode { get; set; } = "Legacy";
    public bool DefaultRtxHdr { get; set; } = false;
    [System.Text.Json.Serialization.JsonExtensionData]
    public System.Collections.Generic.Dictionary<string, System.Text.Json.JsonElement> ExtraSettings { get; set; } = new();
}

public sealed class ScreenInfo
{
    public int Width { get; set; }
    public int Height { get; set; }
    public int WorkWidth { get; set; }
    public int WorkHeight { get; set; }
    public bool Primary { get; set; }
    public string Name { get; set; } = "";
}

public sealed record PlaybackOptions(
    string Profile,
    string UpscaleMode,
    string MotionMode,
    bool Cleanup,
    bool RtxHdr,
    string? YtdlFormat = null,
    bool AutoHdrSwitch = false,
    string CleanupMode = "Legacy");


public sealed class PlaybackLaunchPlan
{
    public string Executable { get; set; } = "";
    public string[] Arguments { get; set; } = Array.Empty<string>();
    public string Profile { get; set; } = "";
    public string UpscaleMode { get; set; } = "";
    public string MotionMode { get; set; } = "";
    public bool Cleanup { get; set; }
    public bool RtxHdr { get; set; }
}
