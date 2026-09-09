using AdaptiveMedia;
using System.Security.Cryptography;

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

    static string Sha256(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }
    string executionRoot = Path.Combine(Path.GetTempPath(), "adaptive-media-dv-execution-tests-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(executionRoot);
    try
    {
        var executor = new DvMatroskaP81Executor(tools, runner);
        string felOutput = Path.Combine(executionRoot, "fel-output.mkv");
        bool acknowledgementRequired = false;
        try
        {
            await executor.ExecuteAsync(new(fel.SourcePath, felOutput,
                DvConversionPlanner.Build(fel.Source, DvConversionTarget.Profile81), AcknowledgeFelLoss: false), CancellationToken.None);
        }
        catch (DvFelLossAcknowledgementRequiredException)
        {
            acknowledgementRequired = true;
        }
        Check(acknowledgementRequired && !File.Exists(felOutput), "FEL loss cannot be executed without explicit acknowledgement");

        string melHash = Sha256(mel.SourcePath);
        string melOutput = Path.Combine(executionRoot, "mel-output.mkv");
        DvExecutionResult melResult = await executor.ExecuteAsync(new(mel.SourcePath, melOutput,
            DvConversionPlanner.Build(mel.Source, DvConversionTarget.Profile81), AcknowledgeFelLoss: false), CancellationToken.None);
        Check(melResult.Promoted && File.Exists(melOutput), "Validated MEL output is promoted");
        Check(melResult.SourceSha256Before == melHash && melResult.SourceSha256After == melHash && Sha256(mel.SourcePath) == melHash,
            "MEL source remains byte-for-byte unchanged");
        Check(melResult.Validation is { Profile81: true, RpuValidated: true, EnhancementLayerAbsent: true,
            BaseVideoIdentical: true, VideoTimestampsIdentical: true }, "MEL output proves profile and stream-copy invariants");
        Check(melResult.Validation is { NonVideoPayloadsIdentical: true, TrackInventoryPreserved: true,
            ChaptersPreserved: true, AttachmentsPreserved: true, MetadataPreserved: true },
            "MEL output preserves supported Matroska content");

        bool noOverwrite = false;
        try
        {
            await executor.ExecuteAsync(new(mel.SourcePath, melOutput,
                DvConversionPlanner.Build(mel.Source, DvConversionTarget.Profile81), false), CancellationToken.None);
        }
        catch (IOException)
        {
            noOverwrite = true;
        }
        Check(noOverwrite && melResult.OutputSha256 == Sha256(melOutput), "Existing destinations are never overwritten");

        string sabotagedOutput = Path.Combine(executionRoot, "sabotaged-output.mkv");
        bool validationRejectedZeroExit = false;
        try
        {
            var sabotagedExecutor = new DvMatroskaP81Executor(tools, new ConvertedStreamSabotageProcess(runner, doviTool));
            await sabotagedExecutor.ExecuteAsync(new(mel.SourcePath, sabotagedOutput,
                DvConversionPlanner.Build(mel.Source, DvConversionTarget.Profile81), false), CancellationToken.None);
        }
        catch (DvExecutionException)
        {
            validationRejectedZeroExit = true;
        }
        Check(validationRejectedZeroExit && !File.Exists(sabotagedOutput),
            "A zero-exit helper result cannot promote output that fails independent validation");

        string felHash = Sha256(fel.SourcePath);
        DvExecutionResult felResult = await executor.ExecuteAsync(new(fel.SourcePath, felOutput,
            DvConversionPlanner.Build(fel.Source, DvConversionTarget.Profile81), AcknowledgeFelLoss: true), CancellationToken.None);
        Check(felResult.Promoted && felResult.Validation.Profile81 && felResult.Validation.BaseVideoIdentical,
            "Acknowledged FEL converts to validated Profile 8.1 with copied base");
        Check(felResult.Losses.HasFlag(DvLossClassification.FelPictureContributionLost) &&
            felResult.Codes.Contains(DvReasonCode.P7FelToP81FelDiscarded) &&
            felResult.Codes.Contains(DvReasonCode.FelPictureContributionNotRetained),
            "FEL result cannot hide picture-contribution loss");
        Check(felResult.SourceSha256Before == felHash && felResult.SourceSha256After == felHash && Sha256(fel.SourcePath) == felHash,
            "FEL source remains byte-for-byte unchanged");
        Check(!Directory.EnumerateDirectories(executionRoot, ".adaptivemedia-dv-*").Any(),
            "Transaction directories are removed after success and rejection");
    }
    finally
    {
        Directory.Delete(executionRoot, recursive: true);
    }

    Console.WriteLine($"PASS: {assertions} Dolby Vision execution assertions");
    return 0;
}
catch (Exception ex)
{
    Console.Error.WriteLine(ex);
    return 1;
}

sealed class ConvertedStreamSabotageProcess(IDvToolProcess inner, string doviTool) : IDvToolProcess
{
    public async Task<DvToolResult> RunAsync(string executable, IReadOnlyList<string> arguments,
        string workingDirectory, TimeSpan timeout, CancellationToken cancellationToken)
    {
        DvToolResult result = await inner.RunAsync(executable, arguments, workingDirectory, timeout, cancellationToken);
        if (result.ExitCode == 0 && Path.GetFullPath(executable) == Path.GetFullPath(doviTool) && arguments.Contains("convert"))
        {
            string[] command = arguments.ToArray();
            int sourceIndex = Array.IndexOf(command, "--discard") + 1;
            int outputIndex = Array.IndexOf(command, "-o") + 1;
            File.Copy(command[sourceIndex], command[outputIndex], overwrite: true);
        }
        return result;
    }
}
