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

    Console.WriteLine($"PASS: {assertions} Dolby Vision execution assertions");
    return 0;
}
catch (Exception ex)
{
    Console.Error.WriteLine(ex);
    return 1;
}
