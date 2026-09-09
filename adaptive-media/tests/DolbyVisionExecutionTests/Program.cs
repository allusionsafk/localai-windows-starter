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
        var guardedProcess = new RecordingProcess(runner);
        var guardedExecutor = new DvMatroskaP81Executor(tools, guardedProcess);
        bool samePathRejected = false;
        try
        {
            await guardedExecutor.ExecuteAsync(new(mel.SourcePath, mel.SourcePath,
                DvConversionPlanner.Build(mel.Source, DvConversionTarget.Profile81), false), CancellationToken.None);
        }
        catch (IOException)
        {
            samePathRejected = true;
        }
        bool wrongPlanRejected = false;
        try
        {
            await guardedExecutor.ExecuteAsync(new(mel.SourcePath, Path.Combine(executionRoot, "wrong-plan.mkv"),
                DvConversionPlanner.Build(mel.Source, DvConversionTarget.Hdr10), false), CancellationToken.None);
        }
        catch (DvExecutionException)
        {
            wrongPlanRejected = true;
        }
        Check(samePathRejected && wrongPlanRejected && guardedProcess.Invocations == 0,
            "Path aliases and non-executable plans are rejected before helper launch");

        string notMatroska = Path.Combine(executionRoot, "not-matroska.mkv");
        File.WriteAllText(notMatroska, "not a Matroska container");
        bool nonMatroskaRejected = false;
        try
        {
            await adapter.ReadAsync(notMatroska, CancellationToken.None);
        }
        catch (DvEvidenceException)
        {
            nonMatroskaRejected = true;
        }
        Check(nonMatroskaRejected, "Non-Matroska input is rejected by real container evidence");

        string multipleVideo = Path.Combine(executionRoot, "multiple-video.mkv");
        var multipleArguments = new List<string> { "-o", multipleVideo, "--regenerate-track-uids" };
        for (int input = 0; input < 2; input++)
            multipleArguments.AddRange(["--no-audio", "--no-subtitles", "--no-attachments", "--no-chapters",
                "--no-global-tags", "--no-track-tags", mel.SourcePath]);
        DvToolResult multipleResult = await runner.RunAsync(tools.MkvMerge, multipleArguments, executionRoot,
            TimeSpan.FromSeconds(30), CancellationToken.None);
        bool multipleVideoRejected = false;
        try
        {
            await adapter.ReadAsync(multipleVideo, CancellationToken.None);
        }
        catch (DvEvidenceException)
        {
            multipleVideoRejected = true;
        }
        Check(multipleResult.ExitCode == 0 && multipleVideoRejected,
            "Matroska sources with multiple video tracks are rejected by real inventory evidence");

        async Task ExpectFailsClosedAsync<TException>(IDvToolProcess failingProcess, string name)
            where TException : Exception
        {
            string failedOutput = Path.Combine(executionRoot, name + ".mkv");
            string sourceHash = Sha256(mel.SourcePath);
            bool rejected = false;
            try
            {
                var failingExecutor = new DvMatroskaP81Executor(tools, failingProcess);
                await failingExecutor.ExecuteAsync(new(mel.SourcePath, failedOutput,
                    DvConversionPlanner.Build(mel.Source, DvConversionTarget.Profile81), false), CancellationToken.None);
            }
            catch (TException)
            {
                rejected = true;
            }
            Check(rejected && !File.Exists(failedOutput) && Sha256(mel.SourcePath) == sourceHash &&
                !Directory.EnumerateDirectories(executionRoot, ".adaptivemedia-dv-*").Any(),
                $"{name} preserves source and cleans transaction without promotion");
        }

        await ExpectFailsClosedAsync<DvExecutionException>(
            new InterceptProcess(runner, doviTool, "convert", InterceptBehavior.NonZero), "conversion-failure");
        await ExpectFailsClosedAsync<TimeoutException>(
            new InterceptProcess(runner, doviTool, "convert", InterceptBehavior.Timeout), "conversion-timeout");
        await ExpectFailsClosedAsync<OperationCanceledException>(
            new InterceptProcess(runner, doviTool, "convert", InterceptBehavior.Cancel), "conversion-cancellation");
        await ExpectFailsClosedAsync<DvExecutionException>(
            new InterceptProcess(runner, tools.MkvMerge, "-o", InterceptBehavior.NonZero), "remux-failure");

        string mismatchOutput = Path.Combine(executionRoot, "plan-source-mismatch.mkv");
        bool mismatchRejected = false;
        try
        {
            await executor.ExecuteAsync(new(fel.SourcePath, mismatchOutput,
                DvConversionPlanner.Build(mel.Source, DvConversionTarget.Profile81), false), CancellationToken.None);
        }
        catch (DvExecutionException)
        {
            mismatchRejected = true;
        }
        Check(mismatchRejected && !File.Exists(mismatchOutput) &&
            !Directory.EnumerateDirectories(executionRoot, ".adaptivemedia-dv-*").Any(),
            "A plan whose source facts do not match current evidence fails closed");

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
        Check(melResult.Promoted && melResult.DestinationPath == melOutput && File.Exists(melOutput),
            "Validated MEL output is promoted to the requested path");
        Check(melResult.SourceSha256Before == melHash && melResult.SourceSha256After == melHash && Sha256(mel.SourcePath) == melHash,
            "MEL source remains byte-for-byte unchanged");
        Check(melResult.Validation is { Profile81: true, RpuValidated: true, EnhancementLayerAbsent: true,
            BaseVideoIdentical: true, VideoTimestampsIdentical: true }, "MEL output proves profile and stream-copy invariants");
        Check(melResult.Validation is { NonVideoPayloadsIdentical: true, TrackInventoryPreserved: true,
            ChaptersPreserved: true, AttachmentsPreserved: true, MetadataPreserved: true },
            "MEL output preserves supported Matroska content");
        DvMatroskaEvidence failedElProbe = await new DvEvidenceAdapter(
            tools, new InterceptProcess(runner, doviTool, "demux", InterceptBehavior.NonZero))
            .ReadAsync(melOutput, CancellationToken.None);
        Check(failedElProbe.Source is { Rpu: DvRpuStatus.Malformed, EnhancementLayer: DvEnhancementLayer.Unknown },
            "A failed enhancement-layer probe cannot be interpreted as validated EL absence");

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

        string mutableSource = Path.Combine(executionRoot, "mutable-source.mkv");
        File.Copy(mel.SourcePath, mutableSource);
        DvMatroskaEvidence mutableEvidence = await adapter.ReadAsync(mutableSource, CancellationToken.None);
        string sourceRaceOutput = Path.Combine(executionRoot, "source-race-output.mkv");
        bool sourceRaceRejected = false;
        try
        {
            var sourceRaceExecutor = new DvMatroskaP81Executor(tools,
                new SourceMutationProcess(runner, doviTool, mutableSource, removeInvocation: 3));
            await sourceRaceExecutor.ExecuteAsync(new(mutableSource, sourceRaceOutput,
                DvConversionPlanner.Build(mutableEvidence.Source, DvConversionTarget.Profile81), false), CancellationToken.None);
        }
        catch (DvExecutionException)
        {
            sourceRaceRejected = true;
        }
        Check(sourceRaceRejected && !File.Exists(sourceRaceOutput) &&
            !Directory.EnumerateDirectories(executionRoot, ".adaptivemedia-dv-*").Any(),
            "A source change during the final helper operation is detected before promotion");

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

sealed class RecordingProcess(IDvToolProcess inner) : IDvToolProcess
{
    public int Invocations { get; private set; }

    public Task<DvToolResult> RunAsync(string executable, IReadOnlyList<string> arguments,
        string workingDirectory, TimeSpan timeout, CancellationToken cancellationToken)
    {
        Invocations++;
        return inner.RunAsync(executable, arguments, workingDirectory, timeout, cancellationToken);
    }
}

enum InterceptBehavior { NonZero, Timeout, Cancel }

sealed class InterceptProcess(IDvToolProcess inner, string interceptedExecutable, string argument,
    InterceptBehavior behavior) : IDvToolProcess
{
    public Task<DvToolResult> RunAsync(string executable, IReadOnlyList<string> arguments,
        string workingDirectory, TimeSpan timeout, CancellationToken cancellationToken)
    {
        bool intercept = string.Equals(Path.GetFullPath(executable), Path.GetFullPath(interceptedExecutable),
            OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal) &&
            arguments.Contains(argument);
        if (!intercept) return inner.RunAsync(executable, arguments, workingDirectory, timeout, cancellationToken);
        return behavior switch
        {
            InterceptBehavior.NonZero => Task.FromResult(new DvToolResult(97, string.Empty, "injected failure")),
            InterceptBehavior.Timeout => Task.FromException<DvToolResult>(new TimeoutException("injected timeout")),
            InterceptBehavior.Cancel => Task.FromException<DvToolResult>(new OperationCanceledException("injected cancellation")),
            _ => throw new ArgumentOutOfRangeException(nameof(behavior))
        };
    }
}

sealed class SourceMutationProcess(IDvToolProcess inner, string doviTool, string sourcePath,
    int removeInvocation) : IDvToolProcess
{
    private int removes;

    public async Task<DvToolResult> RunAsync(string executable, IReadOnlyList<string> arguments,
        string workingDirectory, TimeSpan timeout, CancellationToken cancellationToken)
    {
        DvToolResult result = await inner.RunAsync(executable, arguments, workingDirectory, timeout, cancellationToken);
        if (result.ExitCode == 0 && string.Equals(Path.GetFullPath(executable), Path.GetFullPath(doviTool),
                OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal) &&
            arguments.Contains("remove") && ++removes == removeInvocation)
        {
            await using FileStream stream = new(sourcePath, FileMode.Append, FileAccess.Write, FileShare.Read);
            await stream.WriteAsync(new byte[] { 0x00 }, cancellationToken);
        }
        return result;
    }
}
