using System.Diagnostics;
using System.Text;

namespace AdaptiveMedia;

public static class NativeProcess
{
    public static ProcessStartInfo StartInfo(string executable, IEnumerable<string> arguments, bool capture = true)
    {
        var psi = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = capture, RedirectStandardError = capture,
            WorkingDirectory = AppContext.BaseDirectory };
        if (capture) { psi.StandardOutputEncoding = Encoding.UTF8; psi.StandardErrorEncoding = Encoding.UTF8; }
        foreach (string argument in arguments) psi.ArgumentList.Add(argument);
        return psi;
    }

    public static async Task<(int ExitCode, string Output, string Error)> CaptureAsync(string executable,
        IEnumerable<string> arguments, TimeSpan timeout)
    {
        using var process = Process.Start(StartInfo(executable, arguments)) ?? throw new IOException("Could not start media helper.");
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        using var cancellation = new CancellationTokenSource(timeout);
        try { await process.WaitForExitAsync(cancellation.Token); }
        catch (OperationCanceledException)
        {
            try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            await process.WaitForExitAsync();
            await Task.WhenAll(stdout, stderr);
            throw new TimeoutException("Media helper timed out.");
        }
        return (process.ExitCode, await stdout, await stderr);
    }
}

public static class MediaProbe
{
    public static async Task<MediaInfo> ReadAsync(string mpv, string item)
    {
        if (!File.Exists(item)) return new(); // URLs are observed during playback; never prefetch credentials.
        item = Path.GetFullPath(item);
        const string marker = "AMPROBE|${width}|${height}|${container-fps}|${video-format}|${video-params/gamma}|${video-params/primaries}|${audio-codec-name}|${video-params/pixelformat}|${video-params/aspect}";
        var result = await NativeProcess.CaptureAsync(mpv,
            ["--no-config", "--load-scripts=no", "--frames=1", "--vo=null", "--ao=null", "--terminal=yes", "--quiet", "--term-playing-msg=" + marker, "--", item], TimeSpan.FromSeconds(20));
        string? line = result.Output.Split('\n').LastOrDefault(x => x.StartsWith("AMPROBE|", StringComparison.Ordinal));
        if (result.ExitCode != 0 || line is null) return new();
        string[] p = line.Trim().Split('|');
        if (p.Length != 10) return new();
        int.TryParse(p[1], out int width); int.TryParse(p[2], out int height);
        double.TryParse(p[3], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out double fps);
        double.TryParse(p[9], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out double aspect);
        return new(width, height, fps, p[4], p[5], p[6], p[7], p[8], aspect);
    }
}
