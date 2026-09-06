using System.Diagnostics;
using System.Text.Json;
namespace AdaptiveMedia;

public sealed class PlaybackService
{
    public event Action<string>? StatusChanged;
    public SessionDiagnostics? LastReport { get; private set; }
    private readonly Dictionary<string, (DateTime Stamp, bool Vpp, string Version)> _capabilities = [];
    private readonly Dictionary<string, (DateTime Stamp, long Length, MediaInfo Media)> _mediaCache = [];
    private readonly Dictionary<string, SessionDiagnostics> _preparedReports = [];

    public async Task<PlaybackPlan> PrepareAsync(IReadOnlyList<string> items, PlaybackOptions options,
        SystemSummary system, AppSettings settings, PlaybackTarget? destination = null)
    {
        var expanded = new List<string>();
        string[] extensions = [".mkv", ".mp4", ".m4v", ".avi", ".mov", ".webm", ".ts", ".m2ts", ".flv", ".wmv", ".mp3", ".flac", ".m4a", ".aac", ".opus", ".wav", ".ogg"];
        foreach (string item in items)
        {
            if (Directory.Exists(item)) expanded.AddRange(Directory.EnumerateFiles(item).Where(x => extensions.Contains(Path.GetExtension(x).ToLowerInvariant()))
                .OrderBy(x => System.Text.RegularExpressions.Regex.Replace(Path.GetFileName(x), "[0-9]+", m => m.Value.PadLeft(16, '0')), StringComparer.OrdinalIgnoreCase));
            else if (File.Exists(item)) expanded.Add(Path.GetFullPath(item));
            else if (Uri.TryCreate(item, UriKind.Absolute, out var uri) && new[] { "https", "http", "rtsp", "rtmp", "ftp" }.Contains(uri.Scheme)) expanded.Add(item);
            else throw new FileNotFoundException("The selected media file could not be found.", item);
        }
        if (expanded.Count == 0) throw new IOException("This folder contains no supported media files.");
        string mpv = ResolveMpv(system.MpvPath);
        if (!_capabilities.TryGetValue(mpv, out var capability) || capability.Stamp != File.GetLastWriteTimeUtc(mpv))
        {
            var filters = await NativeProcess.CaptureAsync(mpv, ["--no-config", "--terminal=yes", "--vf=help"], TimeSpan.FromSeconds(10));
            var version = await NativeProcess.CaptureAsync(mpv, ["--no-config", "--terminal=yes", "--version"], TimeSpan.FromSeconds(10));
            capability = (File.GetLastWriteTimeUtc(mpv), filters.ExitCode == 0 && filters.Output.Contains("d3d11vpp"), version.Output.Split('\n')[0].Trim());
            _capabilities[mpv] = capability;
        }
        MediaInfo source;
        var file = File.Exists(expanded[0]) ? new FileInfo(expanded[0]) : null;
        if (file is { Exists: true } && _mediaCache.TryGetValue(file.FullName, out var cached) && cached.Stamp == file.LastWriteTimeUtc && cached.Length == file.Length) source = cached.Media;
        else
        {
            try { source = await MediaProbe.ReadAsync(mpv, expanded[0]); }
            catch (TimeoutException) { source = new(); }
            if (file is { Exists: true } && source.Known)
            {
                if (_mediaCache.Count >= 32) _mediaCache.Clear();
                _mediaCache[file.FullName] = (file.LastWriteTimeUtc, file.Length, source);
            }
        }
        // Re-read cheap display geometry for every preparation; GPU inventory may be cached.
        system.Screens = MonitorInventory.GetScreens();
        Native.DisplayColorInfo[] displays;
        try { displays = Native.HdrController.GetDisplays(); } catch { displays = []; }
        int screen = Array.FindIndex(system.Screens, x => x.Primary);
        if (screen < 0) screen = 0;
        if (settings.PreferExternalDisplay && system.Screens.Length > 1)
            screen = Enumerable.Range(0, system.Screens.Length).Where(i => !system.Screens[i].Primary)
                .OrderByDescending(i => (long)system.Screens[i].Width * system.Screens[i].Height).FirstOrDefault(screen);
        var selected = system.Screens.ElementAtOrDefault(screen);
        bool hdrEnabled = displays.Length == 1 && displays[0].Supported && displays[0].Enabled && !displays[0].ForceDisabled;
        bool fullscreen = system.Screens.Length > 1 && selected is { Primary: false } && settings.FullscreenExternal;
        var target = destination ?? new PlaybackTarget(selected is null ? 0 : fullscreen ? selected.Width : (int)(selected.WorkWidth * .8),
            selected is null ? 0 : fullscreen ? selected.Height : (int)(selected.WorkHeight * .8), screen, fullscreen, hdrEnabled);
        var plan = PlaybackPlanBuilder.Build(mpv, Path.Combine(AppContext.BaseDirectory, "mpv-config"), expanded, options with { AutoHdrSwitch = settings.AutoHdrSwitch }, source, target,
            new(system.HasNvidia, capability.Vpp, system.NvidiaAdapter, system.NvidiaAdapter?.Contains("RTX", StringComparison.OrdinalIgnoreCase) == true),
            "adaptive-media-" + Guid.NewGuid().ToString("N"), settings.HdmiBitstream, HasStreamHelper(system));
        if (_preparedReports.Count >= 32) _preparedReports.Clear();
        _preparedReports[plan.PipeName] = new() { Plan = plan, MpvVersion = capability.Version, Summary = plan.Summary,
            Hardware = new { system.Gpu, system.Cpu, system.Drivers, system.Screens, system.Audio, system.Power,
                Topology = "GPU inventory does not establish display ownership. VRR and endpoint bitstream support are unknown." } };
        return plan;
    }

    public async Task<int> LaunchAsync(PlaybackPlan plan, double? stopAfterSeconds = null)
    {
        _preparedReports.TryGetValue(plan.PipeName, out var prepared);
        LastReport = new() { Plan = plan, Summary = plan.Summary, MpvVersion = prepared?.MpvVersion ?? "unknown", Hardware = prepared?.Hardware };
        using var hdrSession = HdrSession.Begin(plan, LastReport);
        DiagnosticsStore.Event("info", "playback-plan", plan.Renderer);
        StatusChanged?.Invoke(plan.Summary);
        int code = await RunOnceAsync(plan, stopAfterSeconds);
        if (code != 0 && plan.Renderer == "RTX D3D11")
        {
            const string reason = "RTX playback failed. Retrying once with compatibility video and PCM audio.";
            LastReport.FallbackHistory.Add(reason); StatusChanged?.Invoke(reason);
            DiagnosticsStore.Event("warning", "fallback", reason);
            string[] items = plan.Arguments.SkipWhile(x => x != "--").Skip(1).ToArray();
            var fallback = PlaybackPlanBuilder.Build(plan.Executable, Path.Combine(AppContext.BaseDirectory, "mpv-config"), items,
                plan.Requested with { Profile = "Compatibility", UpscaleMode = "HighQuality", RtxHdr = false, MotionMode = "Off" }, plan.Source, plan.Target,
                new(false, false), "adaptive-media-" + Guid.NewGuid().ToString("N"));
            LastReport.Plan = fallback;
            code = await RunOnceAsync(fallback, stopAfterSeconds);
        }
        LastReport.ExitCode = code;
        LastReport.Summary = (LastReport.Plan?.Summary ?? "Playback") + "\n" + (code == 0 ? "Playback ended." : $"Playback failed ({code}).") +
            "\n" + string.Join("\n", LastReport.FallbackHistory);
        try { DiagnosticsStore.Save(LastReport); } catch (IOException) { StatusChanged?.Invoke("Playback ended; diagnostics could not be saved."); }
        return code;
    }

    private async Task<int> RunOnceAsync(PlaybackPlan plan, double? stopAfterSeconds)
    {
        LastReport!.Attempts.Add(plan);
        LastReport.Observed.Clear();
        // Launch the exact immutable argument vector; do not probe or rebuild it here.
        using var process = Process.Start(NativeProcess.StartInfo(plan.Executable, plan.Arguments)) ?? throw new IOException("Could not start the player.");
        DiagnosticsStore.Event("info", "player-started", "Player process started.");
        var stdout = process.StandardOutput.ReadToEndAsync(); var stderr = process.StandardError.ReadToEndAsync();
        using var cancellation = new CancellationTokenSource();
        Task monitor = MonitorAsync(plan, stopAfterSeconds, cancellation.Token);
        await process.WaitForExitAsync();
        DiagnosticsStore.Event("info", "player-exited", "Player process exited.");
        cancellation.Cancel();
        try { await monitor; } catch (OperationCanceledException) { }
        DiagnosticsStore.Event("info", "monitor-ended", "Player observation ended.");
        await stdout; string error = await stderr;
        if (process.ExitCode != 0) { LastReport!.Error = error; DiagnosticsStore.Event("error", "playback-exit", $"mpv exited with {process.ExitCode}"); }
        return process.ExitCode;
    }

    private async Task MonitorAsync(PlaybackPlan plan, double? stopAfterSeconds, CancellationToken cancellation)
    {
        try
        {
            await using var ipc = new MpvIpc(plan.PipeName);
            using var connectTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation); connectTimeout.CancelAfter(TimeSpan.FromSeconds(10));
            await ipc.ConnectAsync(connectTimeout.Token);
            DiagnosticsStore.Event("info", "ipc-connected", "Player observation connected.");
            var timer = Stopwatch.StartNew();
            while (!cancellation.IsCancellationRequested)
            {
                using var queryTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation); queryTimeout.CancelAfter(TimeSpan.FromSeconds(5));
                foreach (string name in new[] { "mpv-version", "gpu-api", "gpu-context", "hwdec-current", "vf", "video-params", "video-out-params", "osd-dimensions",
                    "display-fps", "estimated-display-fps", "vsync-jitter", "frame-drop-count", "decoder-frame-drop-count", "vo-delayed-frame-count", "video-sync",
                    "interpolation", "audio-out-params", "current-ao", "user-data/adaptive/state" })
                {
                    var data = await ipc.CommandAsync(["get_property", name], queryTimeout.Token);
                    if (data.HasValue) LastReport!.Observed[name] = data.Value;
                }
                if (plan.Requested.MotionMode != "Off" && LastReport!.Observed.TryGetValue("video-sync", out var sync) && sync.ValueKind == JsonValueKind.String && sync.GetString() == "audio")
                {
                    const string reason = "Smooth motion was disabled because display timing became unstable.";
                    if (!LastReport.FallbackHistory.Contains(reason)) { LastReport.FallbackHistory.Add(reason); StatusChanged?.Invoke(reason); DiagnosticsStore.Event("warning", "motion-fallback", reason); }
                }
                if (LastReport!.Observed.TryGetValue("user-data/adaptive/state", out var state) && state.ValueKind == JsonValueKind.String)
                    StatusChanged?.Invoke(plan.Summary + "\n" + state.GetString());
                if (stopAfterSeconds.HasValue && timer.Elapsed.TotalSeconds >= stopAfterSeconds) { await ipc.CommandAsync(["quit"], queryTimeout.Token); return; }
                await Task.Delay(1000, cancellation);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or OperationCanceledException or JsonException or InvalidOperationException)
        {
            if (!cancellation.IsCancellationRequested)
            {
                LastReport!.FallbackHistory.Add("Live diagnostics unavailable; playback was not interrupted.");
                DiagnosticsStore.Event("warning", "ipc-unavailable", ex.ToString());
            }
        }
    }

    // The inventory helper can fail and leave a default summary, so confirm PATH before claiming yt-dlp is absent.
    private static bool HasStreamHelper(SystemSummary system) => system.YtDlpAvailable ||
        (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
            .Any(x => !string.IsNullOrWhiteSpace(x) && File.Exists(Path.Combine(x.Trim('"'), "yt-dlp.exe")));

    public static string ResolveMpv(string? hint = null)
    {
        var candidates = new List<string?> { hint, Path.Combine(AppContext.BaseDirectory, "tools", "mpv.exe"), @"C:\mpv\mpv.exe",
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "mpv", "mpv.exe") };
        candidates.AddRange((Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator).Select(x => Path.Combine(x.Trim('"'), "mpv.exe")));
        return candidates.FirstOrDefault(x => !string.IsNullOrWhiteSpace(x) && File.Exists(x)) ?? throw new FileNotFoundException("mpv was not found. Run the installer and select the MPV component.");
    }
}

