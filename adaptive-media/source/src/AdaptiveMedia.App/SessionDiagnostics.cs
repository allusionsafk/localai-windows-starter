using System.Text.Json;
using System.Text.RegularExpressions;

namespace AdaptiveMedia;

public sealed class SessionDiagnostics
{
    public string Version { get; } = "0.4.0-rc1";
    public string Windows { get; } = Environment.OSVersion.VersionString;
    public DateTimeOffset Started { get; } = DateTimeOffset.UtcNow;
    public string Source { get; set; } = "[media]";
    public object? Hardware { get; set; }
    public PlaybackPlan? Plan { get; set; }
    public List<PlaybackPlan> Attempts { get; } = [];
    public string MpvVersion { get; set; } = "unknown";
    public bool RtxDriverActiveVerified { get; } = false;
    public Dictionary<string, JsonElement> Observed { get; set; } = [];
    public List<string> FallbackHistory { get; set; } = [];
    public int? ExitCode { get; set; }
    public string? Error { get; set; }
    public string Summary { get; set; } = "No session recorded.";
}

public static class DiagnosticsStore
{
    public static string DirectoryPath => Path.Combine(SettingsStore.DirectoryPath, "diagnostics");
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };
    public static string Redact(string text)
    {
        string user = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        text = text.Replace(user, "[user]", StringComparison.OrdinalIgnoreCase)
            .Replace(user.Replace("\\", "\\\\"), "[user]", StringComparison.OrdinalIgnoreCase);
        return Regex.Replace(text, @"(?:https?|rtsp|rtmp|ftp)://[^\s""<>]+", "[URL]");
    }
    public static string Save(SessionDiagnostics report)
    {
        Directory.CreateDirectory(DirectoryPath);
        // Do not serialize media arguments, custom URL formats, pipe identifiers or personal config paths.
        object? ShareablePlan(PlaybackPlan? p) => p is not null ? new { p.Requested.Profile, p.Requested.UpscaleMode, p.Requested.MotionMode,
            p.Requested.Cleanup, p.Requested.CleanupMode, p.Requested.RtxHdr, p.Source, p.Target, p.Renderer, p.RtxSrConstructed,
            p.RtxHdrConstructed, p.Scale, p.Reasons, p.ArgumentVectorSha256,
            Arguments = p.Arguments.TakeWhile(x => x != "--").Select(x => x.StartsWith("--config-dir=") ? "--config-dir=[managed]" :
                x.StartsWith("--script=") ? "--script=[managed runtime]" : x.StartsWith("--input-ipc-server=") ? "--input-ipc-server=[session]" :
                x.StartsWith("--ytdl-format=") ? "--ytdl-format=[selected]" : x) } : null;
        string text = Redact(JsonSerializer.Serialize(new { report.Version, report.Windows, report.Started, report.Source,
            report.Hardware, Plan = ShareablePlan(report.Plan), Attempts = report.Attempts.Select(ShareablePlan), report.MpvVersion, report.RtxDriverActiveVerified, report.Observed,
            report.FallbackHistory, report.ExitCode, Error = report.Error is null ? null : "Playback/helper error; see application message.", report.Summary }, Json));
        string path = Path.Combine(DirectoryPath, "latest.json");
        File.WriteAllText(path + ".tmp", text); File.Move(path + ".tmp", path, true);
        File.WriteAllText(Path.Combine(DirectoryPath, "latest.txt"), Redact(report.Summary + "\n" + string.Join("\n", report.FallbackHistory)));
        return path;
    }
    public static void Event(string severity, string kind, string message)
    {
        try
        {
            Directory.CreateDirectory(DirectoryPath);
            string path = Path.Combine(DirectoryPath, "events.jsonl");
            if (File.Exists(path) && new FileInfo(path).Length > 1_000_000)
            {
                for (int i = 2; i >= 1; i--) if (File.Exists(path + "." + i)) File.Move(path + "." + i, path + "." + (i + 1), true);
                File.Move(path, path + ".1", true);
            }
            File.AppendAllText(path, JsonSerializer.Serialize(new { time = DateTimeOffset.UtcNow, severity, kind, message = Redact(message) }) + "\n");
        }
        catch (IOException) { /* Diagnostics cannot prevent playback. */ }
        catch (UnauthorizedAccessException) { }
    }
}
