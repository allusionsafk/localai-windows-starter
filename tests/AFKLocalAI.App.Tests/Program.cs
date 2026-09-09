using AFKLocalAI.App;
using System.Diagnostics;

var failures = new List<string>();
var passed = 0;

void Check(string name, bool condition, string detail = "")
{
    if (condition)
    {
        passed++;
        Console.WriteLine($"PASS {name}");
        return;
    }
    failures.Add(string.IsNullOrWhiteSpace(detail) ? name : $"{name}: {detail}");
}

void Throws<T>(string name, Action action) where T : Exception
{
    try { action(); failures.Add($"{name}: expected {typeof(T).Name}"); }
    catch (T) { passed++; Console.WriteLine($"PASS {name}"); }
}

var root = Directory.GetCurrentDirectory();
var metadataPath = Path.Combine(root, "installer", "version.json");
var product = ProductInfo.Load(metadataPath);
Check("product name", product.ProductName == "AFK LocalAI", product.ProductName);
Check("display version", product.DisplayVersion == "0.2.0-rc1", product.DisplayVersion);
Check("file version", product.FileVersion == "0.2.0.0", product.FileVersion);
Check("canonical executable", product.ExecutableName == "AFKLocalAI.exe", product.ExecutableName);
Check("stable app id", product.AppId == "{8A8A2D4D-CE75-4A2D-A39B-56B4206F93D0}", product.AppId);

var scratch = Path.Combine(root, "build", "dotnet-core-tests", Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(scratch);
try
{
    var badMetadata = Path.Combine(scratch, "version.json");
    File.WriteAllText(badMetadata, """{"schema_version":1,"product_name":"AFK LocalAI"}""");
    Throws<InvalidDataException>("incomplete metadata fails closed", () => ProductInfo.Load(badMetadata));

    var programRoot = Path.Combine(scratch, "Program");
    var dataRoot = Path.Combine(scratch, "Data");
    var paths = AppPaths.ForCurrentUser(dataRoot, programRoot);
    Check("program root is explicit", paths.ProgramRoot == Path.GetFullPath(programRoot), paths.ProgramRoot);
    Check("data is outside program files", !paths.DataRoot.StartsWith(paths.ProgramRoot, StringComparison.OrdinalIgnoreCase));
    Check("state directory", paths.StateRoot == Path.Combine(Path.GetFullPath(dataRoot), "State"), paths.StateRoot);
    Check("log directory", paths.LogRoot == Path.Combine(Path.GetFullPath(dataRoot), "Logs"), paths.LogRoot);
    Check("diagnostics directory", paths.DiagnosticsRoot == Path.Combine(Path.GetFullPath(dataRoot), "Diagnostics"), paths.DiagnosticsRoot);

    var hidden = ProcessSpec.Hidden("powershell.exe", new[] { "-NoProfile", "-Command", "exit 0" }, root);
    ProcessStartInfo info = hidden.CreateStartInfo();
    Check("shell execution disabled", !info.UseShellExecute);
    Check("console creation disabled", info.CreateNoWindow);
    Check("window style hidden", info.WindowStyle == ProcessWindowStyle.Hidden);
    Check("stdout redirected", info.RedirectStandardOutput);
    Check("stderr redirected", info.RedirectStandardError);
    Check("working directory retained", info.WorkingDirectory == Path.GetFullPath(root), info.WorkingDirectory);

    var store = new ProvisioningStateStore(paths);
    var state = store.LoadOrCreate();
    state.Usable = true;
    state.LastReasonCode = "PREFLIGHT-READY";
    store.SaveAtomic(state);
    var roundTrip = store.LoadOrCreate();
    Check("state roundtrip preserves usable", roundTrip.Usable);
    Check("state roundtrip preserves reason", roundTrip.LastReasonCode == "PREFLIGHT-READY", roundTrip.LastReasonCode ?? "null");

    File.WriteAllText(paths.ProvisioningStatePath, "{ definitely not json");
    var recovered = store.LoadOrCreate();
    Check("corrupt state recovers safely", recovered.SchemaVersion == ProvisioningState.CurrentSchemaVersion);
    Check("corrupt state is quarantined", Directory.EnumerateFiles(paths.StateRoot, "provisioning-state.corrupt-*.json").Any());

    var eventLine = """AFK-EVENT:{"schema_version":1,"timestamp_utc":"2026-09-08T12:00:00Z","event_type":"phase-start","phase":"python","status":"running","code":"phase-start","message":"Starting Python."}""";
    Check("structured event parses", ProvisioningEvent.TryParse(eventLine, out var parsedEvent));
    Check("event phase retained", parsedEvent?.Phase == "python", parsedEvent?.Phase ?? "null");
    Check("ordinary console line is ignored", !ProvisioningEvent.TryParse("Installing Python...", out _));

    Check("docker absent maps to install", RecoveryAction.ForCode("PREFLIGHT-DOCKER-NOT-INSTALLED").ActionId == "install-docker");
    Check("remote context is guidance only", !RecoveryAction.ForCode("PREFLIGHT-DOCKER-REMOTE-CONTEXT").Automatic);
    Throws<ArgumentOutOfRangeException>("unknown recovery mapping fails closed", () => RecoveryAction.ForCode("PREFLIGHT-NOT-REAL"));

    var controller = new ProvisioningController(paths);
    var specs = new[]
    {
        controller.Preflight(),
        controller.Recovery("PREFLIGHT-DOCKER-NOT-INSTALLED", "install-docker"),
        controller.Provision(),
        controller.Start(),
        controller.Stop(),
        controller.Health(),
        controller.Diagnostics()
    };
    foreach (var spec in specs)
    {
        var startInfo = spec.CreateStartInfo();
        Check($"{spec.Purpose} hides console", startInfo.CreateNoWindow && !startInfo.UseShellExecute &&
            startInfo.WindowStyle == ProcessWindowStyle.Hidden, spec.FileName);
    }
    Check("preflight uses inbox Windows PowerShell", controller.Preflight().FileName.Equals("powershell.exe", StringComparison.OrdinalIgnoreCase));
    Check("preflight requests JSON", controller.Preflight().Arguments.Contains("-Json"));
    Check("provision requests event stream", controller.Provision().Arguments.Contains("-EventStream"));

    var options = CommandLineOptions.Parse(new[] { "--self-test", "--data-root", dataRoot });
    Check("self-test option parses", options.SelfTest);
    Check("data-root option parses", options.DataRoot == Path.GetFullPath(dataRoot), options.DataRoot ?? "null");
    Throws<ArgumentException>("unknown command-line option fails closed", () => CommandLineOptions.Parse(new[] { "--mystery" }));

    Check("fresh state opens setup mode", AppModeResolver.Resolve(new ProvisioningState()) == AppMode.Setup);
    Check("usable state opens home mode", AppModeResolver.Resolve(new ProvisioningState { Usable = true }) == AppMode.Home);
    Check("single-instance mutex is version-independent", AppIdentity.SingleInstanceMutexName == "Local\\AFKLocalAI-8A8A2D4D-CE75-4A2D-A39B-56B4206F93D0");

    using var icon = AppIcon.Create();
    Check("application icon is available", icon.Width >= 32 && icon.Height >= 32, $"{icon.Width}x{icon.Height}");
    Check("shell exposes accessible setup labels", MainForm.AccessibilityContract.Contains("Prerequisite status") &&
        MainForm.AccessibilityContract.Contains("Setup progress"));
    Check("shell uses the hidden process runner", MainForm.ProcessRunnerType == typeof(HiddenProcessRunner));

    Directory.CreateDirectory(Path.Combine(programRoot, "installer"));
    File.WriteAllText(Path.Combine(programRoot, "installer", "Get-Preflight.ps1"), "# self-test fixture");
    File.WriteAllText(Path.Combine(programRoot, "installer", "Invoke-Recovery.ps1"), "# self-test fixture");
    var selfTest = SelfTestRunner.Run(paths, product);
    Check("shell self-test succeeds", selfTest.Success, string.Join(" | ", selfTest.Checks.Where(pair => !pair.Value).Select(pair => pair.Key)));
    Check("shell self-test serializes as JSON", selfTest.ToJson().Contains("\"success\":true", StringComparison.Ordinal));
}
finally
{
    if (Directory.Exists(scratch)) Directory.Delete(scratch, recursive: true);
}

Console.WriteLine();
if (failures.Count > 0)
{
    Console.Error.WriteLine($"AFK LocalAI core tests failed: {failures.Count}");
    foreach (var failure in failures) Console.Error.WriteLine($"  - {failure}");
    return 1;
}
Console.WriteLine($"AFK LocalAI core tests passed: {passed}");
return 0;
