using System.Text.Json;

namespace Iso2Hd;

/// <summary>
/// Preferences stored in Settings\ISO2HD.settings.json beside the exe, so the folder stays portable.
/// </summary>
internal sealed class AppSettings
{
    public const string FileName = "ISO2HD.settings.json";

    // ProcessPath is the real exe location, even for a single-file build that unpacks elsewhere.
    public static string AppDir { get; } = Path.GetDirectoryName(Environment.ProcessPath) ?? AppContext.BaseDirectory;
    public static string FilePath => Path.Combine(AppDir, "Settings", FileName);

    // Where earlier versions kept the file: read when the new one doesn't exist yet, removed on the next save.
    private static string LegacyFilePath => Path.Combine(AppDir, FileName);

    public const int MaxPadSectors = 100000;   // the script's range

    public string IsoPath { get; set; } = "";

    /// <summary>Read the track back after writing and compare SHA-256.</summary>
    public bool Verify { get; set; } = true;

    /// <summary>Replace sector 0 with a PC boot record when ISO2HD has a boot fix for the disc.</summary>
    public bool BootPatch { get; set; } = true;

    /// <summary>Erase everything after the track, not just the end-of-drive partition data.</summary>
    public bool ZeroRemainder { get; set; }

    /// <summary>Extra 2048-byte zero sectors written after the track (like cdrecord -pad).</summary>
    public int PadSectors { get; set; }

    /// <summary>Whether the output section is shown when the app starts.</summary>
    public bool ShowOutput { get; set; } = true;

    public static AppSettings Load(out string? error)
    {
        error = null;
        var s = new AppSettings();
        var path = File.Exists(FilePath) ? FilePath : LegacyFilePath;
        if (File.Exists(path))
        {
            try
            {
                // Read leniently so a hand-edited file doesn't stop the app starting.
                using var doc = JsonDocument.Parse(File.ReadAllText(path));
                foreach (var p in doc.RootElement.EnumerateObject())
                {
                    var v = p.Value;
                    var isBool = v.ValueKind is JsonValueKind.True or JsonValueKind.False;
                    switch (p.Name.ToLowerInvariant())
                    {
                        case "isopath" when v.ValueKind == JsonValueKind.String: s.IsoPath = v.GetString()!; break;
                        case "verify" when isBool: s.Verify = v.GetBoolean(); break;
                        case "bootpatch" when isBool: s.BootPatch = v.GetBoolean(); break;
                        case "zeroremainder" when isBool: s.ZeroRemainder = v.GetBoolean(); break;
                        case "showoutput" when isBool: s.ShowOutput = v.GetBoolean(); break;
                        case "padsectors" when v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var n): s.PadSectors = n; break;
                    }
                }
            }
            catch (Exception ex)
            {
                error = ex.Message;
            }
        }
        s.PadSectors = Math.Clamp(s.PadSectors, 0, MaxPadSectors);
        return s;
    }

    /// <summary>Saves the settings; returns an error message, or null on success.</summary>
    public string? Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
            try { File.Delete(LegacyFilePath); }
            catch (Exception) { /* the new file is saved; a leftover old one is harmless */ }
            return null;
        }
        catch (Exception ex)
        {
            return ex.Message;
        }
    }
}
