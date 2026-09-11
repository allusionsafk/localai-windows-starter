namespace AFKLocalAI.App;

public sealed class ProvisioningController
{
    private readonly AppPaths _paths;
    public ProvisioningController(AppPaths paths) => _paths = paths;

    public ProcessSpec Preflight() => PowerShell(
        "preflight",
        "installer/Get-Preflight.ps1",
        "-Json", "-DataRoot", _paths.StateRoot);

    public ProcessSpec Recovery(string code, string actionId) => PowerShell(
        "recovery",
        "installer/Invoke-Recovery.ps1",
        "-Code", code, "-ActionId", actionId, "-DataRoot", _paths.StateRoot, "-EventStream");

    public ProcessSpec Provision() => Pwsh(
        "provision",
        "installer/Install-LocalAI.ps1",
        "-Resume", "-AcceptDefaults", "-DataRoot", _paths.StateRoot,
        "-LegacyInstallRoot", _paths.LegacyInstallRoot, "-EventStream");

    public ProcessSpec Start() => Python("start", "start");

    /// <summary>
    /// Stops only what this installation can prove it owns.
    /// </summary>
    /// <remarks>
    /// Deliberately NOT "py -m localai stop". That command resolves through the
    /// ambient <c>localai</c> package name, so on a machine that also has the
    /// private engineering workbench installed editable it runs the workbench's
    /// code against the workbench's repository root - unloading Ollama models,
    /// tearing down the workbench's compose project, and force-closing Docker
    /// Desktop and Ollama for the whole machine. The uninstaller runs this, so it
    /// must never be able to do any of that. The payload script below is invoked
    /// by path, resolves this installation's own code, and refuses to act when
    /// ownership cannot be proven.
    /// </remarks>
    public ProcessSpec Stop() => ProcessSpec.Hidden(
        "py.exe",
        new[]
        {
            Path.Combine(_paths.ProgramRoot, "installer", "afk-stop.py"),
            "--program-root", _paths.ProgramRoot
        },
        _paths.ProgramRoot,
        "stop");

    public ProcessSpec Health() => Python("health", "health");
    public ProcessSpec Diagnostics() => PowerShell(
        "diagnostics",
        "installer/Get-Preflight.ps1",
        "-Json", "-DataRoot", _paths.StateRoot);

    public Uri DashboardUri => new("http://127.0.0.1:3000/");

    private ProcessSpec PowerShell(string purpose, string relativeScript, params string[] arguments) =>
        Script("powershell.exe", purpose, relativeScript, arguments);

    private ProcessSpec Pwsh(string purpose, string relativeScript, params string[] arguments) =>
        Script("pwsh.exe", purpose, relativeScript, arguments);

    private ProcessSpec Script(string executable, string purpose, string relativeScript, params string[] arguments)
    {
        var allArguments = new List<string>
        {
            "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", Path.Combine(_paths.ProgramRoot, relativeScript.Replace('/', Path.DirectorySeparatorChar))
        };
        allArguments.AddRange(arguments);
        return ProcessSpec.Hidden(executable, allArguments, _paths.ProgramRoot, purpose);
    }

    private ProcessSpec Python(string purpose, string command) =>
        ProcessSpec.Hidden(
            "py.exe",
            new[] { "-3.12", "-m", "localai", command },
            _paths.ProgramRoot,
            purpose);
}
