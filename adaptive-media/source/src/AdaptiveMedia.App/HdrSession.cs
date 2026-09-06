using System.Text.Json;
using AdaptiveMedia.Native;
namespace AdaptiveMedia;

// Preserve the reviewed single-HDMI policy. Ambiguous multi-display mapping is deliberately not changed.
internal sealed class HdrSession : IDisposable
{
    private FileStream? _gate;
    private DisplayColorInfo? _before;
    private bool _desired;
    private bool _restored;
    private EventHandler? _processExit;
    private readonly object _sync = new();
    private static string RecoveryPath => Path.Combine(SettingsStore.DirectoryPath, "hdr-recovery.json");
    private static readonly JsonSerializerOptions Json = new() { IncludeFields = true };
    public static HdrSession Begin(PlaybackPlan plan, SessionDiagnostics report)
    {
        var session = new HdrSession();
        if (!plan.Requested.AutoHdrSwitch || !plan.Source.Known) return session;
        if (plan.Arguments.Length - plan.Arguments.IndexOf("--") - 1 > 1)
        { report.FallbackHistory.Add("Windows HDR is preserved for playlists with unverified later items."); return session; }
        try
        {
            Directory.CreateDirectory(SettingsStore.DirectoryPath);
            // File locks release on process death and are safe across asynchronous continuations.
            session._gate = new FileStream(Path.Combine(SettingsStore.DirectoryPath, "hdr-session.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            if (File.Exists(RecoveryPath))
            {
                var previous = JsonSerializer.Deserialize<DisplayColorInfo>(File.ReadAllText(RecoveryPath), Json);
                if (previous is not null && HdrController.SetState(previous.AdapterLow, previous.AdapterHigh, previous.TargetId, previous.Enabled)) File.Delete(RecoveryPath);
                else { report.FallbackHistory.Add("A previous HDR state could not be restored. Windows HDR was left unchanged."); return session; }
            }
            var displays = HdrController.GetDisplays();
            if (displays.Length != 1 || displays[0].OutputTechnology != 5 || !displays[0].Supported || displays[0].ForceDisabled)
            {
                if (plan.Source.IsHdr) report.FallbackHistory.Add("Automatic HDR switching requires one unambiguous compatible HDMI display; current Windows display state is preserved.");
                return session;
            }
            var display = displays[0];
            session._desired = plan.Source.IsHdr || plan.RtxHdrConstructed;
            if (display.Enabled == session._desired) return session;
            Directory.CreateDirectory(SettingsStore.DirectoryPath);
            File.WriteAllText(RecoveryPath, JsonSerializer.Serialize(display, Json));
            session._before = display;
            // A Windows session end or an Application.Shutdown bypasses the window
            // close that normally disposes this session. Restore before the process
            // leaves rather than deferring to the recovery file on the next launch.
            session._processExit = (_, _) => session.Restore();
            AppDomain.CurrentDomain.ProcessExit += session._processExit;
            if (!HdrController.SetState(display.AdapterLow, display.AdapterHigh, display.TargetId, session._desired))
                report.FallbackHistory.Add("Windows HDR switching failed; the player uses the current display state.");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException or JsonException)
        { report.FallbackHistory.Add("HDR state could not be verified; Windows display state is preserved."); }
        return session;
    }
    // Restoration runs at most once, from whichever of shutdown or disposal happens first.
    private void Restore()
    {
        lock (_sync)
        {
            if (_restored) return;
            _restored = true;
            try
            {
                if (_before is { } d && HdrController.SetState(d.AdapterLow, d.AdapterHigh, d.TargetId, d.Enabled)) File.Delete(RecoveryPath);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { DiagnosticsStore.Event("warning", "hdr-restore", "HDR restore state remains available for recovery."); }
        }
    }

    public void Dispose()
    {
        try { Restore(); }
        finally
        {
            if (_processExit is not null) { AppDomain.CurrentDomain.ProcessExit -= _processExit; _processExit = null; }
            _gate?.Dispose();
            _gate = null;
        }
    }
}

