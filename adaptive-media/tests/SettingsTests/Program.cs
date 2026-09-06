using AdaptiveMedia;
using System.Text.Json;
try {
var root = Path.Combine(Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../.artifacts")), "AdaptiveMedia-SettingsTests-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
Environment.SetEnvironmentVariable("ADAPTIVE_MEDIA_DATA_DIR", root);
int count = 0;
void Check(bool pass, string name) { if (!pass) throw new Exception(name); count++; }
void Write(string text) => File.WriteAllText(SettingsStore.PathName, text);
try {
    if (args.Contains("--verify-failure-reporting")) throw new InvalidOperationException("Intentional harness failure-reporting check");
    Check(SettingsStore.DirectoryPath == root, "isolated data directory");
    Write("{\"Profile\":\"Enhanced\",\"AutoHdrSwitch\":false,\"DefaultUpscaleMode\":\"RtxVsr\",\"ExtraOption\":{\"keep\":true}}");
    var legacy=SettingsStore.Load();
    Check(legacy.Profile=="Enhanced" && !legacy.AutoHdrSwitch && legacy.DefaultUpscaleMode=="RtxVsr", "legacy choices preserved");
    Check(SettingsStore.Save(legacy), "save legacy: " + SettingsStore.LastWarning);
    using(var doc=JsonDocument.Parse(File.ReadAllText(SettingsStore.PathName))) {
        Check(doc.RootElement.GetProperty("SchemaVersion").GetInt32()==1, "schema stamped");
        Check(doc.RootElement.GetProperty("ExtraOption").GetProperty("keep").GetBoolean(), "unknown fields preserved");
    }
    Write("{\"Profile\":\"Unavailable\",\"DefaultUpscaleMode\":null,\"DefaultMotionMode\":\"Smooth\",\"AutoHdrSwitch\":false}");
    var invalid=SettingsStore.Load();
    Check(invalid.Profile=="Automatic" && invalid.DefaultUpscaleMode=="Off" && invalid.DefaultMotionMode=="Smooth" && !invalid.AutoHdrSwitch, "invalid choices repaired independently");
    Check(!string.IsNullOrWhiteSpace(SettingsStore.LastWarning), "validation warning visible");
    Write("{\"Profile\":\"Reference\",\"AutoHdrSwitch\":\"oops\",\"HdmiBitstream\":true}");
    var badType=SettingsStore.Load();
    Check(badType.Profile=="Reference" && badType.AutoHdrSwitch && badType.HdmiBitstream, "invalid type does not discard valid fields");
    Write("{broken");
    Check(SettingsStore.Load().Profile=="Automatic" && SettingsStore.LastWarning!=null, "corrupt file handled");
    Check(File.ReadAllText(SettingsStore.PathName)=="{broken", "load preserves corrupt bytes");
    SettingsStore.Save(new AppSettings());
    Check(File.ReadAllText(SettingsStore.PathName+".bak")=="{broken", "atomic replacement backs up prior bytes");
    string future="{\"SchemaVersion\":999,\"Profile\":\"Future\"}";
    Write(future);
    var newer=SettingsStore.Load();
    SettingsStore.Save(newer);
    Check(File.ReadAllText(SettingsStore.PathName)==future && SettingsStore.LastWarning!=null, "future schema never overwritten");
    foreach (var schema in new[] { "999999999999999999999", "\"unknown\"", "-1" }) {
        var unsupported="{\"SchemaVersion\":"+schema+"}";
        Write(unsupported);
        SettingsStore.Load();
        Check(!SettingsStore.Save(new AppSettings()) && File.ReadAllText(SettingsStore.PathName)==unsupported, "unsupported schema protected: " + schema);
    }
    Write("{\"Profile\":\"Reference\"}");
    using (var held=new FileStream(SettingsStore.PathName,FileMode.Open,FileAccess.Read,FileShare.None)) {
        Check(!SettingsStore.Save(new AppSettings()) && SettingsStore.LastWarning!=null, "locked file save fails gracefully");
    }
    Check(File.ReadAllText(SettingsStore.PathName)=="{\"Profile\":\"Reference\"}", "failed save preserves prior bytes");
    Check(!Directory.GetFiles(root,"*.tmp").Any(), "atomic temp files cleaned");
    File.Delete(SettingsStore.PathName);
    SettingsStore.Save(new AppSettings { Profile="compatibility", DefaultMotionMode="gentle" });
    var canonical=SettingsStore.Load();
    Check(canonical.Profile=="Compatibility" && canonical.DefaultMotionMode=="Gentle", "choices canonicalized");
    Check(SettingsStore.LastWarning==null, "successful operation clears stale warning");
    Console.WriteLine($"Settings tests: {count} PASS");
} catch (Exception error) { Console.Error.WriteLine(JsonSerializer.Serialize(new { status="failed", error=error.ToString() })); Environment.ExitCode = 1; } finally { Environment.SetEnvironmentVariable("ADAPTIVE_MEDIA_DATA_DIR",null); Directory.Delete(root,true); }

} catch (Exception error) { Console.Error.WriteLine(JsonSerializer.Serialize(new { status="failed", error=error.ToString() })); Environment.ExitCode=1; }
