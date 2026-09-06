using System.Text.Json;
using System.Diagnostics;
namespace AdaptiveMedia;
internal sealed class BackendBridge
{
    private SystemSummary? _cached;
    private DateTime _scanned;
    public PlaybackService Playback { get; } = new();
    public async Task<SystemSummary> GetSystemSummaryAsync(bool refresh = false)
    {
        if (!refresh && _cached is not null && DateTime.UtcNow - _scanned < TimeSpan.FromSeconds(30)) return _cached;
        string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        var result = await NativeProcess.CaptureAsync(powershell, ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(AppContext.BaseDirectory, "AdaptiveMedia.Engine.ps1"), "-SystemJson"], TimeSpan.FromSeconds(20));
        if (result.ExitCode != 0) throw new IOException("Hardware inventory failed: " + result.Error.Trim());
        _cached = JsonSerializer.Deserialize<SystemSummary>(result.Output, new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? new();
        _scanned = DateTime.UtcNow;
        return _cached;
    }
    public async Task<PlaybackPlan> GetPlaybackPlanAsync(IReadOnlyList<string> items, PlaybackOptions options, PlaybackTarget? target = null, AppSettings? settings = null)
    {
        SystemSummary summary;
        try { summary = await GetSystemSummaryAsync(); } catch { summary = new(); }
        return await Playback.PrepareAsync(items, options, summary, settings ?? SettingsStore.Load(), target);
    }
    public void OpenDiagnostics()
    {
        Directory.CreateDirectory(DiagnosticsStore.DirectoryPath);
        Process.Start(new ProcessStartInfo("explorer.exe") { UseShellExecute = true, ArgumentList = { DiagnosticsStore.DirectoryPath } });
    }
}
