using System.Runtime.InteropServices;

namespace Iso2Hd;

/// <summary>
/// Raises <see cref="DevicesChanged"/> (on the window's thread) when Windows broadcasts that devices
/// were added or removed, by subclassing the window to see WM_DEVICECHANGE.
/// </summary>
internal sealed class DeviceWatcher : IDisposable
{
    private const uint WM_DEVICECHANGE = 0x0219;
    private const int DBT_DEVNODES_CHANGED = 0x0007;
    private const int DBT_DEVICEARRIVAL = 0x8000;
    private const int DBT_DEVICEREMOVECOMPLETE = 0x8004;

    private delegate IntPtr SubclassProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam, UIntPtr id, UIntPtr refData);

    [DllImport("comctl32.dll")]
    private static extern bool SetWindowSubclass(IntPtr hwnd, SubclassProc proc, UIntPtr id, UIntPtr refData);

    [DllImport("comctl32.dll")]
    private static extern bool RemoveWindowSubclass(IntPtr hwnd, SubclassProc proc, UIntPtr id);

    [DllImport("comctl32.dll")]
    private static extern IntPtr DefSubclassProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    private readonly IntPtr _hwnd;
    private readonly SubclassProc _proc;   // kept in a field so the delegate isn't collected

    public event EventHandler? DevicesChanged;

    public DeviceWatcher(IntPtr hwnd)
    {
        _hwnd = hwnd;
        _proc = WndProc;
        SetWindowSubclass(_hwnd, _proc, UIntPtr.Zero, UIntPtr.Zero);
    }

    private IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam, UIntPtr id, UIntPtr refData)
    {
        if (msg == WM_DEVICECHANGE && (int)wParam.ToInt64() is DBT_DEVNODES_CHANGED or DBT_DEVICEARRIVAL or DBT_DEVICEREMOVECOMPLETE)
            DevicesChanged?.Invoke(this, EventArgs.Empty);
        return DefSubclassProc(hwnd, msg, wParam, lParam);
    }

    public void Dispose() => RemoveWindowSubclass(_hwnd, _proc, UIntPtr.Zero);
}

/// <summary>
/// Progress on the app's taskbar button (ITaskbarList3), so a long write can be followed from the taskbar.
/// Failures are ignored: they must never stop a write.
/// </summary>
internal sealed class TaskbarProgress(IntPtr hwnd)
{
    public enum State { None = 0, Indeterminate = 0x1, Normal = 0x2, Error = 0x4, Paused = 0x8 }

    private ITaskbarList3? _taskbar;

    public void SetState(State state) => Call(t => t.SetProgressState(hwnd, state));

    public void SetValue(int percent) => Call(t => t.SetProgressValue(hwnd, (ulong)Math.Clamp(percent, 0, 100), 100));

    private void Call(Action<ITaskbarList3> action)
    {
        try
        {
            if (_taskbar == null)
            {
                _taskbar = (ITaskbarList3)new TaskbarListRcw();
                _taskbar.HrInit();
            }
            action(_taskbar);
        }
        catch (Exception)
        {
            // No taskbar (e.g. Explorer restarting).
        }
    }

    [ComImport, Guid("56FDF344-FD6D-11d0-958A-006097C9A090")]
    private class TaskbarListRcw { }

    // ITaskbarList + ITaskbarList2 + ITaskbarList3 methods, in vtable order (only up to SetProgressState is used).
    [ComImport, Guid("ea1afb91-9e28-4b86-90e9-9e9f8a5eefaf"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ITaskbarList3
    {
        void HrInit();
        void AddTab(IntPtr hwnd);
        void DeleteTab(IntPtr hwnd);
        void ActivateTab(IntPtr hwnd);
        void SetActiveAlt(IntPtr hwnd);
        void MarkFullscreenWindow(IntPtr hwnd, [MarshalAs(UnmanagedType.Bool)] bool fullscreen);
        void SetProgressValue(IntPtr hwnd, ulong completed, ulong total);
        void SetProgressState(IntPtr hwnd, State state);
    }
}
