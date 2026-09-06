using System.Text.Json;
namespace AdaptiveMedia;
public sealed record PlaybackRequest(string[] Items, PlaybackOptions Options, PlaybackTarget? Target = null, double? StopAfterSeconds = null);
internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        try
        {
            if (args.Contains("--self-test")) return File.Exists(Path.Combine(AppContext.BaseDirectory, "mpv-config", "mpv.conf")) ? 0 : 11;
            if (args.Contains("--integration-test")) return IntegrationTest();
            if (args.Contains("--plan-stdin") || args.Contains("--play-stdin")) return CommandAsync(args.Contains("--plan-stdin")).GetAwaiter().GetResult();
            if (args.Contains("--diagnostics")) { new BackendBridge().OpenDiagnostics(); return 0; }
            var app = new App(); app.InitializeComponent();
            return app.Run(new MainWindow(args));
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.ToString());
            DiagnosticsStore.Event("error", "startup", ex.GetType().Name);
            if (!args.Any(x => x.EndsWith("-stdin") || x.EndsWith("test"))) System.Windows.MessageBox.Show(ex.Message, "Adaptive Media");
            return 29;
        }
    }
    private static async Task<int> CommandAsync(bool planOnly)
    {
        // Read the request as UTF-8 whatever console code page the caller left behind.
        using var input = new StreamReader(Console.OpenStandardInput(), new System.Text.UTF8Encoding(false));
        var request = JsonSerializer.Deserialize<PlaybackRequest>(await input.ReadToEndAsync(), new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? throw new ArgumentException("Missing playback request.");
        var bridge = new BackendBridge();
        var plan = await bridge.GetPlaybackPlanAsync(request.Items, request.Options, request.Target);
        if (planOnly) { Console.WriteLine(JsonSerializer.Serialize(plan)); return 0; }
        return await bridge.Playback.LaunchAsync(plan, request.StopAfterSeconds);
    }
    private static int IntegrationTest()
    {
        var plan = PlaybackPlanBuilder.Build("mpv.exe", "managed", ["https://example.invalid/media.mp4"], new("Enhanced", "RtxVsr", "Smooth", true, false),
            new(1920,1080), new(2560,1600), new(true,true, Rtx: true), "test");
        var psi = NativeProcess.StartInfo(plan.Executable, plan.Arguments);
        return psi.ArgumentList.SequenceEqual(plan.Arguments) && plan.Arguments.Any(x => x.Contains("scale=1.333333:scaling-mode=nvidia")) &&
            plan.Arguments.Contains("--hwdec=d3d11va") && !plan.Arguments.Contains("--vulkan-swap-mode=fifo") ? 0 : 21;
    }
}

