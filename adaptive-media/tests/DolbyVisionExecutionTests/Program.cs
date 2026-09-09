using AdaptiveMedia;

if (args.SequenceEqual(["--sleep"]))
{
    await Task.Delay(TimeSpan.FromSeconds(30));
    return 0;
}

try
{
    int assertions = 0;
    void Check(bool condition, string message)
    {
        assertions++;
        if (!condition) throw new Exception(message);
    }

    string dotnet = Environment.ProcessPath is { } host && Path.GetFileNameWithoutExtension(host).Equals("dotnet", StringComparison.OrdinalIgnoreCase)
        ? host : "dotnet";
    var runner = new DvToolProcess();
    DvToolResult version = await runner.RunAsync(dotnet, ["--version"], AppContext.BaseDirectory,
        TimeSpan.FromSeconds(10), CancellationToken.None);
    Check(version.ExitCode == 0 && version.Output.Trim().Length > 0, "Tool runner captures a real process");

    using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(200));
    bool cancelled = false;
    try
    {
        await runner.RunAsync(dotnet, [Path.Combine(AppContext.BaseDirectory, "DolbyVisionExecutionTests.dll"), "--sleep"],
            AppContext.BaseDirectory, TimeSpan.FromSeconds(10), cancellation.Token);
    }
    catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
    {
        cancelled = true;
    }
    Check(cancelled, "Caller cancellation stops a real child process");

    string RequiredArgument(string name)
    {
        int index = Array.IndexOf(args, name);
        if (index < 0 || index + 1 >= args.Length) throw new ArgumentException($"Required argument missing: {name}");
        return Path.GetFullPath(args[index + 1]);
    }
    string ffprobe = RequiredArgument("--ffprobe");
    string doviTool = RequiredArgument("--dovi-tool");
    string mkvDirectory = RequiredArgument("--mkvtoolnix");
    var tools = new DvToolPaths(ffprobe, doviTool,
        Path.Combine(mkvDirectory, "mkvmerge.exe"),
        Path.Combine(mkvDirectory, "mkvextract.exe"),
        Path.Combine(mkvDirectory, "mkvpropedit.exe"));
    var adapter = new DvEvidenceAdapter(tools, runner);
    string fixtures = Path.Combine(AppContext.BaseDirectory, "fixtures");
    DvMatroskaEvidence mel = await adapter.ReadAsync(Path.Combine(fixtures, "p7-mel.mkv"), CancellationToken.None);
    Check(mel.Source is { Detection: DvDetection.Detected, Profile: 7, CompatibilityId: 6,
        EnhancementLayer: DvEnhancementLayer.Mel, Rpu: DvRpuStatus.Validated,
        Hdr10Base: DvCompatibility.Yes, BitDepth: 10 }, "Real MEL source classified");
    Check(mel.RpuFrameCount == 259 && mel.VideoPacketCount == 259 && mel.EnhancementLayerPresent,
        "MEL evidence covers the complete selected stream");
    Check(mel.StaticHdrMetadata && mel.Source.BaseVideo is { Width: 256, Height: 144, Codec: "hevc", Transfer: "pq", Primaries: "bt.2020" },
        "MEL base has explicit HDR10 evidence");

    DvMatroskaEvidence fel = await adapter.ReadAsync(Path.Combine(fixtures, "p7-fel.mkv"), CancellationToken.None);
    Check(fel.Source is { Detection: DvDetection.Detected, Profile: 7, CompatibilityId: 6,
        EnhancementLayer: DvEnhancementLayer.Fel, Rpu: DvRpuStatus.Validated,
        Hdr10Base: DvCompatibility.Yes, BitDepth: 10 }, "Real FEL source classified");
    Check(fel.RpuFrameCount == 259 && fel.VideoPacketCount == 259 && fel.EnhancementLayerPresent,
        "FEL evidence covers the complete selected stream");
    Check(DvConversionPlanner.Build(fel.Source, DvConversionTarget.Profile81).Executable,
        "Real FEL evidence feeds the executable planner path");

    Console.WriteLine($"PASS: {assertions} Dolby Vision execution assertions");
    return 0;
}
catch (Exception ex)
{
    Console.Error.WriteLine(ex);
    return 1;
}
