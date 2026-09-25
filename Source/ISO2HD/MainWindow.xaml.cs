using System.Collections.Concurrent;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using WinRT.Interop;

namespace Iso2Hd;

public sealed class LogLine(string text, Brush foreground)
{
    public string Text { get; } = text;
    public Brush Foreground { get; } = foreground;
}

/// <summary>
/// Runs ISO2HD.ps1 (next to the exe, or the copy built into it) in hidden Windows PowerShell processes
/// to list drives, read images and write them, and shows its output. All disk logic stays in the script.
/// </summary>
public sealed partial class MainWindow : Window
{
    internal const string AppTitle = "ISO2HD";

    // Lines from "ISO2HD.ps1 -ReportStatus" that aren't shown in the output.
    private const string ProgressPrefix = "##PROGRESS|";   // ##PROGRESS|<percent>|<phase>|<status>
    private const string WaitPrefix = "##WAIT|";           // ##WAIT|start / ##WAIT|end
    private const string ResultPrefix = "##RESULT|";       // ##RESULT|<json>
    private const int CancelledExitCode = 2;

    // "[12:34:56] WARN  message"
    private static readonly Regex LogRx = new(@"^\[\d\d:\d\d:\d\d\] (\w+)\s+(.*)$", RegexOptions.Compiled);

    private readonly AppSettings _settings;
    private readonly ObservableCollection<LogLine> _lines = [];
    private readonly ConcurrentQueue<(string Text, bool IsError)> _pending = new();
    private readonly DispatcherQueueTimer _flushTimer;
    private readonly IntPtr _hwnd;
    private readonly TaskbarProgress _taskbar;
    private DeviceWatcher? _deviceWatcher;
    private readonly DispatcherQueueTimer _deviceTimer;   // rescans once a burst of device changes settles

    // Image and drives
    private string _isoPath = "";
    private IsoInfo? _isoInfo;
    private bool _inspecting;
    private List<DiskInfo> _disks = [];
    private string? _scanError;
    private bool _scanning;
    private bool _rescanPending;
    private readonly Stopwatch _scanClock = new();
    private readonly DispatcherQueueTimer _scanTimer;     // "still scanning" message

    // The current write
    private Process? _proc;
    private EventWaitHandle? _cancelEvent;
    private readonly DispatcherQueueTimer _killTimer;     // last resort if the script doesn't stop when cancelled
    private bool _cancelled;
    private bool _closeAfterStop;
    private string _runIso = "";
    private DiskInfo? _runDisk;
    private string _status = "";
    private int _percent = -1;                            // -1 = no progress figure for the current step
    private DateTime? _waitingSince;                      // waiting for the drive to respond
    private BurnResult? _result;
    private string? _lastError;
    private (TaskbarProgress.State State, int Percent) _taskbarShown = (TaskbarProgress.State.None, 0);

    // Output show/hide animation (window height, in pixels)
    private static readonly TimeSpan OutputAnimDuration = TimeSpan.FromMilliseconds(500);
    private readonly ExponentialEase _outputEase = new() { Exponent = 7, EasingMode = EasingMode.EaseOut };   // decelerate
    private readonly Stopwatch _animClock = new();
    private bool _outputHidden;
    private bool _animating;
    private int _animFrom;
    private int _animTo;
    private int _expandedHeight;   // height to return to when the output is shown again

    public MainWindow()
    {
        InitializeComponent();

        _hwnd = WindowNative.GetWindowHandle(this);
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "app.ico"));
        SizeAndCenter(900, 760);
        AppWindow.Closing += AppWindow_Closing;
        AppWindow.Changed += AppWindow_Changed;
        Closed += (_, _) => _deviceWatcher?.Dispose();
        _taskbar = new TaskbarProgress(_hwnd);

        LogList.ItemsSource = _lines;
        _flushTimer = CreateTimer(100, true, () =>
        {
            FlushOutput();
            UpdateStatus();   // also counts the seconds while waiting for the drive
        });
        _scanTimer = CreateTimer(1000, true, UpdateScanMessage);
        _deviceTimer = CreateTimer(1500, false, () => { if (!IsRunning) StartDiskScan(); });
        _killTimer = CreateTimer(30000, false, KillBurn);

        _settings = AppSettings.Load(out var loadError);
        IsoBox.Text = _settings.IsoPath;
        UpdateSummary();

        if (!_settings.ShowOutput)
        {
            // Start collapsed; the window is shrunk once the layout (and so the collapsed height) is known.
            _outputHidden = true;
            UpdateOutputToggle();
            OutputPanel.Visibility = Visibility.Collapsed;
            Root.Loaded += (_, _) => CollapseWindowAtStartup();
        }

        Root.Loaded += (_, _) =>
        {
            // Rescan automatically when drives are plugged in or removed.
            _deviceWatcher = new DeviceWatcher(_hwnd);
            _deviceWatcher.DevicesChanged += (_, _) =>
            {
                _deviceTimer.Stop();
                _deviceTimer.Start();
            };
            _isoPath = CurrentIsoText();
            StartInspect();
            StartDiskScan();
        };

        if (loadError != null)
            Root.Loaded += async (_, _) => await ShowMessageAsync("Preferences not loaded",
                $"Could not read the preferences file; defaults are being used.\n\n{AppSettings.FilePath}\n\n{loadError}");
    }

    private DispatcherQueueTimer CreateTimer(int milliseconds, bool repeating, Action tick)
    {
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(milliseconds);
        timer.IsRepeating = repeating;
        timer.Tick += (_, _) => tick();
        return timer;
    }

    #region Window

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    private void SizeAndCenter(int width, int height)
    {
        var scale = GetDpiForWindow(_hwnd) / 96.0;
        var size = new SizeInt32((int)(width * scale), (int)(height * scale));
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
        size.Width = Math.Min(size.Width, area.Width);
        size.Height = Math.Min(size.Height, area.Height);
        AppWindow.MoveAndResize(new RectInt32(
            area.X + (area.Width - size.Width) / 2, area.Y + (area.Height - size.Height) / 2, size.Width, size.Height));
    }

    private async void AppWindow_Closing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (!IsRunning) return;
        args.Cancel = true;
        if (!await ConfirmAsync("Burn in progress", "Stop writing and exit? The drive will be left holding an incomplete image.",
                                "Stop and exit", "Keep writing"))
            return;
        if (IsRunning)
        {
            _closeAfterStop = true;
            StopBurn();
        }
        else
        {
            Close();
        }
    }

    #endregion

    #region Dialogs

    // Dialogs are separate windows so they aren't clipped when the main window is small or collapsed.
    private static TextBlock MessageText(string message) =>
        new() { Text = message, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };

    private Task ShowMessageAsync(string title, string message) =>
        new DialogWindow(title, MessageText(message), null, "OK").ShowAsync(this);

    private Task<bool> ConfirmAsync(string title, string message, string yes, string no) =>
        new DialogWindow(title, MessageText(message), yes, no).ShowAsync(this);

    private async void SaveSettings()
    {
        var error = _settings.Save();
        if (error != null)
            await ShowMessageAsync("Preferences not saved", $"Could not save preferences to:\n{AppSettings.FilePath}\n\n{error}");
    }

    private async void About_Click(object sender, RoutedEventArgs e) =>
        await new DialogWindow("About", new AboutPanel(), null, "Close", width: 420).ShowAsync(this);

    private async void Preferences_Click(object sender, RoutedEventArgs e)
    {
        var panel = new PreferencesPanel(_settings);
        var dialog = new DialogWindow("Preferences", panel, "Save", "Cancel", width: 520) { PrimaryButtonClick = panel.TryApply };
        if (!await dialog.ShowAsync(this)) return;
        SaveSettings();
        UpdateSummary();
        ShowDiskInfo();   // the padding changes whether the image fits
    }

    #endregion

    #region Image and drives

    private string CurrentIsoText() => IsoBox.Text.Trim().Trim('"');

    private void UpdateSummary()
    {
        SummaryText.Text = $"Verify: {(_settings.Verify ? "On" : "Off")}   ·   " +
                           $"BIOS boot fix: {(_settings.BootPatch ? "On" : "Off")}   ·   " +
                           $"Rest of drive: {(_settings.ZeroRemainder ? "Erase" : "Clear old partition data")}   ·   " +
                           $"Pad sectors: {_settings.PadSectors}";
    }

    private void Browse_Click(object sender, RoutedEventArgs e)
    {
        string? folder = null;
        try
        {
            var current = CurrentIsoText();
            if (current.Length > 0) folder = Directory.Exists(current) ? current : Path.GetDirectoryName(current);
        }
        catch (Exception)
        {
            // Not a valid path: open at the dialog's default folder.
        }
        var path = ShellDialog.PickFile(_hwnd, "Select a disc image", folder,
                                        ("Disc images", "*.iso;*.img"), ("All files", "*.*"));
        if (path == null) return;
        IsoBox.Text = path;
        OnIsoPathChanged();
    }

    private void IsoBox_LostFocus(object sender, RoutedEventArgs e) => OnIsoPathChanged();

    private void IsoBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter) OnIsoPathChanged();
    }

    private void OnIsoPathChanged()
    {
        var path = CurrentIsoText();
        if (path == _isoPath) return;
        _isoPath = path;
        _isoInfo = null;
        StartInspect();
        StartDiskScan();   // the drive holding the image is left out of the target list
    }

    /// <summary>Reads the image's details in the background.</summary>
    private async void StartInspect()
    {
        if (_inspecting) return;   // when it finishes, it starts again if the path changed
        if (_isoPath.Length == 0)
        {
            ShowIsoInfo("No image selected.");
            return;
        }

        _inspecting = true;
        var path = _isoPath;
        ShowIsoInfo("Reading image…");
        IsoInfo? info = null;
        string? error = null;
        try
        {
            info = await Task.Run(() => ScriptHost.QueryAsync<IsoInfo>("-Inspect", Path.GetFullPath(path), "-Json"));
        }
        catch (Exception ex)
        {
            error = ex.Message;
        }
        _inspecting = false;

        if (path != _isoPath)
        {
            StartInspect();
            return;
        }
        _isoInfo = info;
        if (info == null) ShowIsoInfo($"Cannot read image: {error}");
        else ShowIsoInfo();
        ShowDiskInfo();
    }

    private void ShowIsoInfo(string? message = null)
    {
        IsoWarningText.Visibility = Visibility.Collapsed;
        if (message != null || _isoInfo is not { } i)
        {
            IsoInfoText.Text = message ?? "";
            return;
        }
        var label = i.VolumeLabel.Length > 0 ? i.VolumeLabel : "(none)";
        IsoInfoText.Text = $"Label: {label}   ·   Size: {i.Size} ({i.Sectors:N0} sectors)   ·   File system: {i.FileSystem}\n" +
                           $"BIOS boot: {i.BiosBoot}";
        if (i.Warnings.Length > 0)
        {
            IsoWarningText.Text = string.Join("\n", i.Warnings);
            IsoWarningText.Visibility = Visibility.Visible;
        }
    }

    private void Refresh_Click(object sender, RoutedEventArgs e) => StartDiskScan();

    /// <summary>
    /// Lists the drives in the background, so a drive that is slow to answer can't freeze the window.
    /// </summary>
    private async void StartDiskScan()
    {
        if (_scanning)
        {
            _rescanPending = true;
            return;
        }
        _scanning = true;
        _rescanPending = false;
        var path = _isoPath;
        _scanClock.Restart();
        _scanTimer.Start();
        DiskInfoText.Text = "Scanning drives…";
        DiskInfoText.Foreground = Brush("TextFillColorSecondaryBrush");
        UpdateControls();

        List<DiskInfo>? disks = null;
        _scanError = null;
        try
        {
            disks = await Task.Run(() =>
            {
                var args = new List<string> { "-ListDisks", "-Json" };
                if (path.Length > 0 && File.Exists(path)) args.AddRange(["-IsoPath", Path.GetFullPath(path)]);
                return ScriptHost.QueryAsync<List<DiskInfo>>([.. args]);
            });
        }
        catch (Exception ex)
        {
            _scanError = ex.Message;
        }
        _scanTimer.Stop();
        _scanning = false;

        var previous = SelectedDisk?.Number;
        _disks = disks?.Where(d => d.Eligible).OrderBy(d => d.Number).ToList() ?? [];
        DiskBox.Items.Clear();
        foreach (var d in _disks) DiskBox.Items.Add(d.ToString());
        DiskBox.SelectedIndex = _disks.FindIndex(d => d.Number == previous);
        ShowDiskInfo();
        UpdateControls();

        if (_rescanPending || path != _isoPath) StartDiskScan();
    }

    private DiskInfo? SelectedDisk => DiskBox.SelectedIndex >= 0 && DiskBox.SelectedIndex < _disks.Count ? _disks[DiskBox.SelectedIndex] : null;

    private void UpdateScanMessage()
    {
        if (!_scanning || _scanClock.Elapsed.TotalSeconds < 5) return;
        DiskInfoText.Text = $"Still scanning drives ({_scanClock.Elapsed.TotalSeconds:N0} s). Windows is waiting for a drive to respond - " +
                            "often a USB adapter waking from power saving. Wait, or unplug and replug that drive.";
    }

    private void DiskBox_SelectionChanged(object sender, SelectionChangedEventArgs e) => ShowDiskInfo();

    private void ShowDiskInfo()
    {
        if (_scanning) return;   // keeps "Scanning drives…"
        var brush = "TextFillColorSecondaryBrush";
        string text;
        if (_scanError != null)
        {
            text = $"Drive scan failed: {_scanError}";
            brush = "SystemFillColorCriticalBrush";
        }
        else if (_disks.Count == 0)
        {
            text = "No drives to write to. Boot and system drives, read-only drives and the drive holding the image are never listed.";
        }
        else if (SelectedDisk is not { } d)
        {
            text = _disks.Count == 1 ? "1 drive available." : $"{_disks.Count} drives available.";
        }
        else
        {
            text = $"Capacity: {d.SizeBytes:N0} bytes   ·   Logical sector: {d.LogicalSectorSize} bytes   ·   Current layout: {d.PartitionStyle}";
            if (_isoInfo != null)
            {
                if (_isoInfo.TrackBytes(_settings.PadSectors) <= d.SizeBytes)
                {
                    text += "   ·   Image fits";
                }
                else
                {
                    text += "   ·   Image doesn't fit: the drive is too small";
                    brush = "SystemFillColorCriticalBrush";
                }
            }
        }
        DiskInfoText.Text = text;
        DiskInfoText.Foreground = Brush(brush);
    }

    private void UpdateControls()
    {
        var idle = !IsRunning;
        IsoBox.IsReadOnly = !idle;
        BrowseButton.IsEnabled = idle;
        DiskBox.IsEnabled = idle && !_scanning;
        RefreshButton.IsEnabled = idle && !_scanning;
        PrefsButton.IsEnabled = idle;
        // Burn waits for the drive list; Cancel is disabled once pressed.
        StartButton.IsEnabled = idle ? !_scanning : !_cancelled;
    }

    #endregion

    #region Burn

    private bool IsRunning => _proc != null;

    /// <summary>One button: Burn when idle, Cancel while a write is running.</summary>
    private async void StartCancel_Click(object sender, RoutedEventArgs e)
    {
        if (IsRunning) StopBurn();
        else await StartBurnAsync();
    }

    private async Task StartBurnAsync()
    {
        OnIsoPathChanged();   // a path typed without leaving the box
        var iso = _isoPath;
        if (iso.Length == 0 || !File.Exists(iso))
        {
            await ShowMessageAsync("Choose an image", "Please choose an existing .iso or .img file to write.");
            return;
        }
        if (SelectedDisk is not { } disk)
        {
            await ShowMessageAsync("Choose a drive", "Please choose the drive to write to.");
            return;
        }
        if (_isoInfo != null && _isoInfo.TrackBytes(_settings.PadSectors) > disk.SizeBytes)
        {
            await ShowMessageAsync("Image doesn't fit",
                $"The image needs {_isoInfo.TrackBytes(_settings.PadSectors):N0} bytes, but Disk {disk.Number} holds {disk.SizeBytes:N0} bytes.");
            return;
        }
        iso = Path.GetFullPath(iso);

        if (!await ConfirmBurnAsync(iso, disk) || IsRunning) return;

        _settings.IsoPath = iso;
        SaveSettings();

        // The script opens this event by name and stops when it is set.
        var cancelName = $@"Local\ISO2HD-Cancel-{Guid.NewGuid():N}";
        var cancelEvent = new EventWaitHandle(false, EventResetMode.ManualReset, cancelName);
        var args = new List<string>
        {
            "-IsoPath", iso, "-DiskNumber", disk.Number.ToString(), "-PadSectors", _settings.PadSectors.ToString(),
            "-Force", "-ReportStatus", "-CancelEvent", cancelName,
        };
        if (!_settings.Verify) args.Add("-NoVerify");
        if (_settings.ZeroRemainder) args.Add("-ZeroRemainder");
        if (!_settings.BootPatch) args.Add("-NoBootPatch");

        Process proc;
        try
        {
            proc = new Process { StartInfo = ScriptHost.CreateStartInfo([.. args]), EnableRaisingEvents = true };
            proc.OutputDataReceived += (_, a) => { if (a.Data != null) _pending.Enqueue((a.Data, false)); };
            proc.ErrorDataReceived += (_, a) => { if (a.Data != null) _pending.Enqueue((a.Data, true)); };
            proc.Exited += (_, _) => DispatcherQueue.TryEnqueue(OnProcessExited);

            _lines.Clear();
            AddLine($"Started {DateTime.Now:g}", LineKind.Header);
            AddLine($"Image:   {iso}", LineKind.Header);
            AddLine($"Drive:   Disk {disk.Number}: {disk.Name} ({disk.Size}, {disk.BusType})", LineKind.Header);
            AddLine($"Options: {SummaryText.Text}", LineKind.Header);
            AddLine("", LineKind.Normal);

            proc.Start();
        }
        catch (Exception ex)
        {
            cancelEvent.Dispose();
            await ShowMessageAsync("Could not start", $"Could not start the write:\n{ex.Message}");
            return;
        }
        proc.BeginOutputReadLine();
        proc.BeginErrorReadLine();

        _proc = proc;
        _cancelEvent = cancelEvent;
        _runIso = iso;
        _runDisk = disk;
        SetRunning(true);
        _flushTimer.Start();
    }

    private async Task<bool> ConfirmBurnAsync(string iso, DiskInfo disk)
    {
        var body = new StackPanel { Spacing = 12 };
        body.Children.Add(new TextBlock
        {
            Text = "All data on this drive will be permanently erased:",
            TextWrapping = TextWrapping.Wrap,
            FontWeight = FontWeights.SemiBold,
            Foreground = Brush("SystemFillColorCriticalBrush"),
        });
        body.Children.Add(new TextBlock
        {
            Text = $"Disk {disk.Number}: {disk.Name}\n{disk.Size}, {disk.BusType}, {disk.PartitionStyle}",
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            Margin = new Thickness(16, 0, 0, 0),
        });
        body.Children.Add(MessageText($"Write \"{Path.GetFileName(iso)}\" to it?"));
        // Cancel has the focus, so pressing Enter by mistake doesn't erase the drive.
        return await new DialogWindow("Erase drive?", body, "Erase and write", "Cancel", primaryIsDefault: false).ShowAsync(this);
    }

    private void StopBurn()
    {
        if (_proc == null || _cancelled) return;
        _cancelled = true;
        StatusText.Text = "Cancelling…";
        UpdateControls();
        // The script stops between 1 MiB blocks and releases the drive.
        try { _cancelEvent?.Set(); } catch (ObjectDisposedException) { }
        _killTimer.Start();
    }

    /// <summary>The script didn't stop (e.g. stuck waiting for an unresponsive drive): end it.</summary>
    private void KillBurn()
    {
        try { _proc?.Kill(entireProcessTree: true); }
        catch (Exception) { /* already exited */ }
    }

    private async void OnProcessExited()
    {
        var proc = _proc;
        if (proc == null) return;

        // Exited can fire before the last output lines arrive; this waits for the streams to close.
        await Task.Run(() => proc.WaitForExit());
        _flushTimer.Stop();
        _killTimer.Stop();
        FlushOutput();

        var code = proc.ExitCode;
        proc.Dispose();
        _proc = null;
        _cancelEvent?.Dispose();
        _cancelEvent = null;

        var cancelled = _cancelled || code == CancelledExitCode;
        var succeeded = !cancelled && code == 0 && _result != null;
        AddLine("", LineKind.Normal);
        if (cancelled)
        {
            AddLine("---- Cancelled ----", LineKind.Warning);
            StatusText.Text = "Cancelled - the drive may hold an incomplete image";
        }
        else if (succeeded)
        {
            AddLine($"---- Finished {DateTime.Now:g} ----", LineKind.Success);
            StatusText.Text = _result!.Verified ? "Finished and verified" : "Finished";
        }
        else
        {
            _lastError ??= code == 0 ? "The write stopped unexpectedly." : $"ISO2HD.ps1 stopped with exit code {code}.";
            AddLine($"---- Stopped with an error (exit code {code}) ----", LineKind.Error);
            StatusText.Text = $"Failed: {_lastError}";
        }
        SetRunning(false);

        if (_closeAfterStop)
        {
            Close();
            return;
        }

        if (succeeded)
        {
            await ShowResultAsync(_result!);
        }
        else if (!cancelled)
        {
            SetTaskbar(TaskbarProgress.State.Error, 100);
            await ShowMessageAsync("Burn failed", $"{_lastError}\n\nSee the output for details.");
        }
        SetTaskbar(TaskbarProgress.State.None, 0);
        StartDiskScan();
    }

    private Task ShowResultAsync(BurnResult r)
    {
        var verified = r.Verified
            ? "Verified: the drive reads back exactly what was written."
            : "Not verified (turned off in Preferences).";
        var message = $"\"{Path.GetFileName(_runIso)}\" was written to Disk {_runDisk?.Number}: {r.DiskName}.\n\n" +
                      $"{verified}\n\n" +
                      $"Track: {r.TrackSectors:N0} sectors, {r.BytesWritten:N0} bytes\n" +
                      $"BIOS boot fix: {r.BiosBootFix}\n" +
                      $"Time: {r.Elapsed}\n\n" +
                      $"Image SHA-256:\n{r.ImageSha256}\n\n" +
                      "If Windows says the drive needs to be formatted, click Cancel: formatting would erase the image.";
        return new DialogWindow("Burn complete", MessageText(message), null, "OK", width: 520).ShowAsync(this);
    }

    private void SetRunning(bool running)
    {
        StartButton.Style = (Style)Application.Current.Resources[running ? "DefaultButtonStyle" : "AccentButtonStyle"];
        StartIcon.Glyph = running ? "\uE711" : "\uE768";   // Cancel / Play
        StartText.Text = running ? "Cancel" : "Burn";
        AutomationProperties.SetName(StartButton, StartText.Text);
        Progress.Visibility = running ? Visibility.Visible : Visibility.Collapsed;
        if (running)
        {
            _cancelled = false;
            _status = "Starting…";
            _percent = -1;
            _waitingSince = null;
            _result = null;
            _lastError = null;
            UpdateStatus();
        }
        else
        {
            SetTaskbar(TaskbarProgress.State.None, 0);
        }
        UpdateControls();
        AppWindow.Title = running ? $"{AppTitle} - writing" : AppTitle;
    }

    private void FlushOutput()
    {
        var added = false;
        while (_pending.TryDequeue(out var item))
        {
            var text = item.Text;
            if (!item.IsError)
            {
                if (text.StartsWith(ProgressPrefix, StringComparison.Ordinal))
                {
                    var parts = text.Split('|', 4);
                    if (parts.Length == 4 && int.TryParse(parts[1], out var pct))
                    {
                        _percent = pct;
                        _status = $"{parts[2]}  ·  {parts[3]}";
                    }
                    continue;
                }
                if (text.StartsWith(WaitPrefix, StringComparison.Ordinal))
                {
                    _waitingSince = text.EndsWith("start", StringComparison.Ordinal) ? DateTime.UtcNow : null;
                    continue;
                }
                if (text.StartsWith(ResultPrefix, StringComparison.Ordinal))
                {
                    try { _result = JsonSerializer.Deserialize<BurnResult>(text[ResultPrefix.Length..], ScriptHost.JsonOptions); }
                    catch (JsonException) { }
                    continue;
                }
            }

            added = true;
            var kind = LineKind.Error;
            if (item.IsError)
            {
                _lastError ??= text.Trim();   // PowerShell itself failed; its first line holds the message
            }
            else if (LogRx.Match(text) is { Success: true } m)
            {
                var message = m.Groups[2].Value;
                kind = m.Groups[1].Value switch
                {
                    "ERROR" => LineKind.Error,
                    "WARN" => LineKind.Warning,
                    "OK" => LineKind.Success,
                    _ => LineKind.Normal,
                };
                if (kind == LineKind.Error) _lastError = message;
                else if (kind != LineKind.Warning)
                {
                    // Each step logs a line as it starts ("Writing track...", "Synchronizing cache...").
                    _status = message.EndsWith("...", StringComparison.Ordinal) ? message[..^3] + "…" : message;
                    _percent = -1;
                }
            }
            else
            {
                kind = LineKind.Normal;
            }
            AddLine(text, kind);
        }
        if (added && _lines.Count > 0) LogList.ScrollIntoView(_lines[^1]);
    }

    /// <summary>Status line, progress bar and taskbar progress for the running write.</summary>
    private void UpdateStatus()
    {
        if (!IsRunning || _cancelled) return;   // keep "Cancelling…"
        if (_waitingSince is { } since)
        {
            var waited = (int)(DateTime.UtcNow - since).TotalSeconds;
            StatusText.Text = waited >= 3
                ? $"Waiting for the drive to respond ({waited} s). If this passes a minute, unplug and replug the drive and start again."
                : "Preparing drive…";
            Progress.IsIndeterminate = true;
            SetTaskbar(TaskbarProgress.State.Indeterminate, 0);
            return;
        }

        StatusText.Text = _status;
        Progress.IsIndeterminate = _percent < 0;
        Progress.Value = Math.Max(0, _percent);
        SetTaskbar(_percent < 0 ? TaskbarProgress.State.Indeterminate : TaskbarProgress.State.Normal, Math.Max(0, _percent));
    }

    private void SetTaskbar(TaskbarProgress.State state, int percent)
    {
        if (_taskbarShown == (state, percent)) return;
        if (state != _taskbarShown.State) _taskbar.SetState(state);
        if (state is TaskbarProgress.State.Normal or TaskbarProgress.State.Error) _taskbar.SetValue(percent);
        _taskbarShown = (state, percent);
    }

    #endregion

    #region Output

    private enum LineKind { Normal, Header, Success, Warning, Error }

    private static Brush Brush(string key) =>
        Application.Current.Resources.TryGetValue(key, out var b) && b is Brush br
            ? br
            : new SolidColorBrush(Microsoft.UI.Colors.Gray);

    private void AddLine(string text, LineKind kind)
    {
        var key = kind switch
        {
            LineKind.Error => "SystemFillColorCriticalBrush",
            LineKind.Success => "SystemFillColorSuccessBrush",
            LineKind.Warning => "SystemFillColorCautionBrush",
            LineKind.Header => "TextFillColorPrimaryBrush",
            _ => "TextFillColorSecondaryBrush",
        };
        _lines.Add(new LogLine(text, Brush(key)));
    }

    private void CopyOutput_Click(object sender, RoutedEventArgs e)
    {
        var package = new DataPackage();
        package.SetText(string.Join(Environment.NewLine, _lines.Select(l => l.Text)));
        Clipboard.SetContent(package);
    }

    private void ToggleOutput_Click(object sender, RoutedEventArgs e) => SetOutputHidden(!_outputHidden);

    /// <summary>
    /// Hides or shows the output section. The window shrinks to end just below the progress row, or
    /// grows back to its previous height, with a decelerating (exponential ease-out) animation.
    /// </summary>
    private void SetOutputHidden(bool hidden)
    {
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Maximized } presenter)
            presenter.Restore();

        _outputHidden = hidden;
        UpdateOutputToggle();
        var current = AppWindow.Size.Height;
        int target;
        if (hidden)
        {
            // Mid-animation the window isn't at its expanded height; keep the one recorded earlier.
            if (!_animating) _expandedHeight = current;
            target = CollapsedWindowHeight();
        }
        else
        {
            OutputPanel.Visibility = Visibility.Visible;
            var scale = Root.XamlRoot.RasterizationScale;
            var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
            target = _expandedHeight > 0 ? _expandedHeight : (int)(760 * scale);
            target = Math.Max(current, Math.Min(target, area.Y + area.Height - AppWindow.Position.Y));
        }

        _animFrom = current;
        _animTo = target;
        _animClock.Restart();
        if (!_animating)
        {
            _animating = true;
            CompositionTarget.Rendering += AnimateWindowHeight;
        }
    }

    private void AnimateWindowHeight(object? sender, object e)
    {
        var t = Math.Min(1.0, _animClock.Elapsed / OutputAnimDuration);
        var height = _animFrom + (_animTo - _animFrom) * _outputEase.Ease(t);
        AppWindow.Resize(new SizeInt32(AppWindow.Size.Width, (int)Math.Round(height)));
        if (t < 1) return;

        CompositionTarget.Rendering -= AnimateWindowHeight;
        _animating = false;
        if (_outputHidden) OutputPanel.Visibility = Visibility.Collapsed;
    }

    /// <summary>Window height (pixels) that ends just below the progress row, keeping the bottom padding.</summary>
    private int CollapsedWindowHeight()
    {
        var scale = Root.XamlRoot.RasterizationScale;
        var rows = ContentGrid.RowDefinitions;
        var client = AppTitleBar.ActualHeight + ContentGrid.Padding.Top + ContentGrid.Padding.Bottom;
        for (var i = 0; i < rows.Count - 1; i++) client += rows[i].ActualHeight;   // all but the output row
        client += ContentGrid.RowSpacing * (rows.Count - 2);
        var frame = AppWindow.Size.Height - AppWindow.ClientSize.Height;
        return (int)Math.Ceiling(client * scale) + frame;
    }

    /// <summary>Output hidden by preference: open at the collapsed height, centered on the screen.</summary>
    private void CollapseWindowAtStartup()
    {
        _expandedHeight = AppWindow.Size.Height;
        var height = CollapsedWindowHeight();
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
        AppWindow.MoveAndResize(new RectInt32(AppWindow.Position.X, area.Y + (area.Height - height) / 2, AppWindow.Size.Width, height));
    }

    /// <summary>While the output is hidden, the window follows the sections above it as their text changes.</summary>
    private void Section_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (!_outputHidden || _animating || Root.XamlRoot == null) return;
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Maximized }) return;
        AppWindow.Resize(new SizeInt32(AppWindow.Size.Width, CollapsedWindowHeight()));
    }

    private void UpdateOutputToggle()
    {
        OutputToggleIcon.Glyph = _outputHidden ? "\uE70D" : "\uE70E";   // ChevronDown / ChevronUp
        OutputToggleText.Text = _outputHidden ? "Show output" : "Hide output";
        AutomationProperties.SetName(OutputToggleButton, OutputToggleText.Text);
    }

    private void AppWindow_Changed(AppWindow sender, AppWindowChangedEventArgs args)
    {
        // Resizing or maximizing the window taller while the output is hidden brings it back.
        if (!args.DidSizeChange || !_outputHidden || _animating || Root.XamlRoot == null) return;
        if (AppWindow.Size.Height <= CollapsedWindowHeight() + 8) return;
        _outputHidden = false;
        _expandedHeight = 0;
        OutputPanel.Visibility = Visibility.Visible;
        UpdateOutputToggle();
    }

    #endregion
}
