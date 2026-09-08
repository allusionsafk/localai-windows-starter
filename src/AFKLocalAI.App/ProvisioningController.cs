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
    public ProcessSpec Stop() => Python("stop", "stop");
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
