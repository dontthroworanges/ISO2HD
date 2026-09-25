using System.Diagnostics;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Iso2Hd;

/// <summary>A drive from "ISO2HD.ps1 -ListDisks -Json".</summary>
public sealed class DiskInfo
{
    public int Number { get; set; }
    public string Name { get; set; } = "";
    public long SizeBytes { get; set; }
    public string Size { get; set; } = "";
    public string BusType { get; set; } = "";
    public int LogicalSectorSize { get; set; }
    public string PartitionStyle { get; set; } = "";
    public bool Eligible { get; set; }
    public string Reason { get; set; } = "";

    public override string ToString() => $"Disk {Number}: {Name}   [{Size}, {BusType}]";
}

/// <summary>An image from "ISO2HD.ps1 -Inspect &lt;file&gt; -Json".</summary>
public sealed class IsoInfo
{
    public string Path { get; set; } = "";
    public long SizeBytes { get; set; }
    public string Size { get; set; } = "";
    public long Sectors { get; set; }
    public string VolumeLabel { get; set; } = "";
    public bool IsIso9660 { get; set; }
    public bool IsUdf { get; set; }
    public string BiosBoot { get; set; } = "";
    public string[] Warnings { get; set; } = [];

    public string FileSystem =>
        string.Join(" + ", new[] { IsIso9660 ? "ISO 9660" : null, IsUdf ? "UDF" : null }.OfType<string>()) is { Length: > 0 } fs
            ? fs
            : "unrecognized";

    /// <summary>Bytes the track takes on a drive: whole 2048-byte sectors, at least 300 of them.</summary>
    public long TrackBytes(int padSectors) => (Math.Max((SizeBytes + 2047) / 2048, 300) + padSectors) * 2048;
}

/// <summary>The "##RESULT|" line printed by "ISO2HD.ps1 -ReportStatus" after a successful write.</summary>
public sealed class BurnResult
{
    public string DiskName { get; set; } = "";
    public string BiosBootFix { get; set; } = "";
    public long TrackSectors { get; set; }
    public long BytesWritten { get; set; }
    public string ImageSha256 { get; set; } = "";
    public bool Verified { get; set; }
    public string Elapsed { get; set; } = "";
}

/// <summary>
/// Runs ISO2HD.ps1 in a hidden Windows PowerShell process. All the disk and image logic stays in the script.
/// </summary>
internal static class ScriptHost
{
    public const string ScriptName = "ISO2HD.ps1";

    public static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    // The image and drive queries start together at launch; only one of them extracts the script.
    private static readonly object ExtractLock = new();

    /// <summary>
    /// ISO2HD.ps1 from the exe's folder, or else the copy built into the exe, extracted to
    /// %LOCALAPPDATA%\ISO2HD\&lt;hash&gt; (so the exe also works when copied somewhere on its own).
    /// </summary>
    public static string ResolveScript()
    {
        var beside = Path.Combine(AppSettings.AppDir, ScriptName);
        if (File.Exists(beside)) return beside;

        using var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(ScriptName)
            ?? throw new FileNotFoundException($"{ScriptName} was not found next to ISO2HD.exe and no built-in copy is present.");
        using var ms = new MemoryStream();
        resource.CopyTo(ms);
        var data = ms.ToArray();

        var hash = Convert.ToHexString(SHA256.HashData(data));
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ISO2HD", hash[..12]);
        var path = Path.Combine(dir, ScriptName);
        lock (ExtractLock)
        {
            // Rewrite the extracted copy unless it still matches the built-in script exactly.
            if (!File.Exists(path) || Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))) != hash)
            {
                Directory.CreateDirectory(dir);
                File.WriteAllBytes(path, data);
            }
        }
        return path;
    }

    /// <summary>A hidden Windows PowerShell running the script with <paramref name="args"/>; output is redirected as UTF-8.</summary>
    public static ProcessStartInfo CreateStartInfo(params string[] args)
    {
        var script = ResolveScript();
        var psi = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = Path.GetDirectoryName(script)!,
        };
        // -File with separate arguments: .NET handles the quoting.
        foreach (var arg in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script })
            psi.ArgumentList.Add(arg);
        foreach (var arg in args) psi.ArgumentList.Add(arg);
        return psi;
    }

    /// <summary>
    /// Runs one of the script's -Json queries. Throws with the script's message if it failed.
    /// </summary>
    public static async Task<T> QueryAsync<T>(params string[] args)
    {
        using var proc = Process.Start(CreateStartInfo(args)) ?? throw new InvalidOperationException("Windows PowerShell did not start.");
        var stdout = proc.StandardOutput.ReadToEndAsync();
        var stderr = proc.StandardError.ReadToEndAsync();
        await proc.WaitForExitAsync();
        var output = (await stdout).Trim();
        var errors = (await stderr).Trim();

        JsonDocument? doc = null;
        try { doc = JsonDocument.Parse(output); } catch (JsonException) { }
        using (doc)
        {
            if (doc?.RootElement is { ValueKind: JsonValueKind.Object } root &&
                root.TryGetProperty("Error", out var error) && error.ValueKind == JsonValueKind.String)
                throw new InvalidOperationException(error.GetString());
            if (proc.ExitCode != 0 || doc == null)
            {
                // e.g. PowerShell couldn't load the script. Its first line holds the message.
                var message = (errors.Length > 0 ? errors : output).Split('\n')[0].Trim();
                throw new InvalidOperationException(message.Length > 0 ? message : $"ISO2HD.ps1 stopped with exit code {proc.ExitCode}.");
            }
            return doc.Deserialize<T>(JsonOptions) ?? throw new InvalidOperationException("ISO2HD.ps1 returned no data.");
        }
    }
}
