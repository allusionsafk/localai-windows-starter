using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.Json;

namespace AdaptiveMedia;

internal static class SettingsStore
{
    private static readonly object Gate = new();
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true, WriteIndented = true };
    public static string? LastWarning { get; private set; }
    public static string DirectoryPath => string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("ADAPTIVE_MEDIA_DATA_DIR"))
        ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AdaptiveMediaPreview")
        : Path.GetFullPath(Environment.GetEnvironmentVariable("ADAPTIVE_MEDIA_DATA_DIR")!);
    public static string PathName => Path.Combine(DirectoryPath, "settings.json");
    private static string LegacyPath => File.Exists(Path.Combine(AppContext.BaseDirectory, "settings.json"))
        ? Path.Combine(AppContext.BaseDirectory, "settings.json")
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AdaptiveMedia", "settings.json");

    public static AppSettings Load()
    {
        lock (Gate)
        {
            LastWarning = null;
            try
            {
                var path = PathName;
                // An explicit data directory is isolated from installed legacy settings.
                if (!File.Exists(path) && string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("ADAPTIVE_MEDIA_DATA_DIR")) && File.Exists(LegacyPath))
                    path = LegacyPath;
                if (!File.Exists(path)) return new AppSettings();
                var result = Read(File.ReadAllText(path));
                return result;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or ArgumentException or NotSupportedException)
            {
                LastWarning = "Settings could not be read. Defaults are in use; the original file is unchanged. " + e.Message;
                return new AppSettings();
            }
        }
    }

    private static AppSettings Read(string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object) throw new JsonException("Settings must be a JSON object.");
        if (HasUnsupportedSchema(root))
        {
            LastWarning = "Settings have a newer or unsupported schema. Defaults are in use and this file will not be overwritten.";
            return new AppSettings();
        }
        var settings = new AppSettings();
        var warnings = new List<string>();
        var properties = typeof(AppSettings).GetProperties().Where(p => p.CanWrite && p.Name != nameof(AppSettings.ExtraSettings))
            .ToDictionary(p => p.Name, StringComparer.OrdinalIgnoreCase);
        foreach (var entry in root.EnumerateObject())
        {
            if (!properties.TryGetValue(entry.Name, out var property))
            {
                settings.ExtraSettings[entry.Name] = entry.Value.Clone();
                continue;
            }
            try
            {
                var value = JsonSerializer.Deserialize(entry.Value.GetRawText(), property.PropertyType, JsonOptions);
                if (value is null) { warnings.Add(entry.Name); continue; }
                property.SetValue(settings, value);
            }
            catch (JsonException) { warnings.Add(entry.Name); }
        }
        if (settings.SchemaVersion > AppSettings.CurrentSchemaVersion)
        {
            LastWarning = "Settings were created by a newer version. Defaults are in use and this file will not be overwritten.";
            return new AppSettings();
        }
        if (settings.SchemaVersion < 0) warnings.Add(nameof(settings.SchemaVersion));
        settings.SchemaVersion = AppSettings.CurrentSchemaVersion;
        Validate(settings, warnings);
        if (warnings.Count > 0) LastWarning = "Some saved settings were unavailable or invalid and now use safe defaults: " + string.Join(", ", warnings.Distinct()) + ".";
        return settings;
    }

    private static void Validate(AppSettings settings, List<string> warnings)
    {
        string Choice(string? value, string fallback, string name, params string[] choices)
        {
            var match = choices.FirstOrDefault(c => string.Equals(c, value, StringComparison.OrdinalIgnoreCase));
            if (match != null) return match;
            warnings.Add(name);
            return fallback;
        }
        settings.Profile = Choice(settings.Profile, "Automatic", nameof(settings.Profile), "Automatic", "Reference", "Enhanced", "Compatibility");
        settings.DefaultUpscaleMode = Choice(settings.DefaultUpscaleMode, "Off", nameof(settings.DefaultUpscaleMode), "Off", "Automatic", "HighQuality", "RtxVsr");
        settings.DefaultCleanupMode = Choice(settings.DefaultCleanupMode, "Legacy", nameof(settings.DefaultCleanupMode), "Legacy", "Off", "Gentle", "Normal", "Strong", "Automatic");
        settings.DefaultMotionMode = Choice(settings.DefaultMotionMode, "Off", nameof(settings.DefaultMotionMode), "Off", "Gentle", "Smooth");
        settings.SchemaVersion = AppSettings.CurrentSchemaVersion;
    }

    private static bool HasUnsupportedSchema(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object) return false;
        foreach (var entry in root.EnumerateObject())
            if (entry.Name.Equals(nameof(AppSettings.SchemaVersion), StringComparison.OrdinalIgnoreCase) &&
                (entry.Value.ValueKind != JsonValueKind.Number || !entry.Value.TryGetInt32(out var version) ||
                 version < 0 || version > AppSettings.CurrentSchemaVersion)) return true;
        return false;
    }

    public static bool Save(AppSettings settings)
    {
        lock (Gate)
        {
            LastWarning = null;
            string? temporary = null;
            try
            {
                var path = PathName;
                // Recheck at save time: another/newer app may have written since Load.
                if (File.Exists(path))
                {
                    try
                    {
                        using var document = JsonDocument.Parse(File.ReadAllText(path));
                        if (HasUnsupportedSchema(document.RootElement))
                        {
                            LastWarning = "Settings have a newer or unsupported schema and were not overwritten.";
                            return false;
                        }
                    }
                    catch (JsonException) { /* Preserve corrupt input in the replacement backup. */ }
                }
                if (settings.SchemaVersion > AppSettings.CurrentSchemaVersion)
                {
                    LastWarning = "Settings belong to a newer version and were not saved.";
                    return false;
                }
                var warnings = new List<string>();
                Validate(settings, warnings);
                Directory.CreateDirectory(DirectoryPath);
                temporary = Path.Combine(DirectoryPath, ".settings-" + Guid.NewGuid().ToString("N") + ".tmp");
                using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    JsonSerializer.Serialize(stream, settings, JsonOptions);
                    stream.Flush(flushToDisk: true);
                }
                // Some user/sandbox filesystems reject copying ACL metadata. The
                // same-directory replacement remains atomic without that metadata.
                if (File.Exists(path)) File.Replace(temporary, path, path + ".bak", ignoreMetadataErrors: true);
                else File.Move(temporary, path);
                if (warnings.Count > 0) LastWarning = "Saved with safe defaults for: " + string.Join(", ", warnings) + ".";
                return true;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or ArgumentException or NotSupportedException)
            {
                LastWarning = "Settings could not be saved. Existing settings are unchanged. " + e.Message;
                return false;
            }
            finally
            {
                if (temporary != null)
                    try { File.Delete(temporary); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
        }
    }
}
