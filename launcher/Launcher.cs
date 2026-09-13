// ISO2HD.exe - starts ISO2HD.ps1 without a console window.
// Uses ISO2HD.ps1 from the exe's folder when present, otherwise the copy embedded at build time.
// Built by Build-Exe.ps1 with the .NET Framework 4 compiler (C# 5).
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("ISO2HD")]
[assembly: AssemblyDescription("Burn ISO to Hard Drive")]
[assembly: AssemblyProduct("ISO2HD")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]

static class Program
{
    const string ScriptName = "ISO2HD.ps1";

    [STAThread]
    static int Main(string[] args)
    {
        try
        {
            string script = ResolveScript();
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");

            ProcessStartInfo psi = new ProcessStartInfo(powershell);
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File " + Quote(script) + JoinArgs(args);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.WorkingDirectory = Path.GetDirectoryName(script);

            StringBuilder output = new StringBuilder();
            using (Process p = new Process())
            {
                p.StartInfo = psi;
                p.OutputDataReceived += (s, e) => { if (e.Data != null) lock (output) output.AppendLine(e.Data); };
                p.ErrorDataReceived += (s, e) => { if (e.Data != null) lock (output) output.AppendLine(e.Data); };
                p.Start();
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
                p.WaitForExit();

                if (p.ExitCode != 0)
                {
                    string text;
                    lock (output) text = output.ToString().Trim();
                    if (text.Length > 3000) text = "..." + text.Substring(text.Length - 3000);
                    ShowError("ISO2HD stopped with an error (exit code " + p.ExitCode + ").\r\n\r\n" + text);
                }
                return p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            ShowError("ISO2HD could not start.\r\n\r\n" + ex.Message);
            return 1;
        }
    }

    static string ResolveScript()
    {
        string beside = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ScriptName);
        if (File.Exists(beside)) return beside;

        byte[] data;
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(ScriptName))
        {
            if (s == null) throw new FileNotFoundException(ScriptName + " was not found next to ISO2HD.exe and no embedded copy is present.");
            using (MemoryStream ms = new MemoryStream())
            {
                s.CopyTo(ms);
                data = ms.ToArray();
            }
        }

        string hash = Sha256(data);
        string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            Path.Combine("ISO2HD", hash.Substring(0, 12)));
        Directory.CreateDirectory(dir);
        string path = Path.Combine(dir, ScriptName);
        // Rewrite the extracted copy unless it still matches the embedded script exactly.
        if (!File.Exists(path) || Sha256(File.ReadAllBytes(path)) != hash)
            File.WriteAllBytes(path, data);
        return path;
    }

    static string Sha256(byte[] data)
    {
        using (SHA256 sha = SHA256.Create())
            return BitConverter.ToString(sha.ComputeHash(data)).Replace("-", "");
    }

    static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    static string JoinArgs(string[] args)
    {
        StringBuilder sb = new StringBuilder();
        foreach (string a in args) sb.Append(' ').Append(Quote(a));
        return sb.ToString();
    }

    static void ShowError(string message)
    {
        MessageBox.Show(message, "ISO2HD", MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
}
