using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Iso2Hd;

/// <summary>
/// "Safely remove" for a disk: the same Configuration Manager request the notification-area icon
/// makes. It goes to the nearest removable device node above the disk (the USB device, not the disk
/// itself), so Windows flushes caches, dismounts the volumes and powers the port down.
/// </summary>
internal static class DeviceEject
{
    private const int CR_SUCCESS = 0;
    private const uint CM_DRP_CAPABILITIES = 0x10;
    private const uint CM_DEVCAP_REMOVABLE = 0x4;
    private const uint DIGCF_PRESENT = 0x2;
    private const uint DIGCF_DEVICEINTERFACE = 0x10;
    private const uint IOCTL_STORAGE_GET_DEVICE_NUMBER = 0x2D1080;
    private const uint FILE_SHARE_READ_WRITE = 0x3;
    private const uint OPEN_EXISTING = 3;
    private static readonly Guid DiskInterface = new("53f56307-b6bf-11d0-94f2-00a0c91efb8b");

    private static readonly string[] VetoReasons =
    [
        "unknown reason", "legacy device", "a driver is waiting to install", "the device is disabled",
        "legacy driver", "insufficient power", "a program or file is still open on the drive",
        "the device is in use by Windows", "the driver refused", "insufficient rights",
        "the device does not support removal", "the drive holds the Windows page file",
    ];

    [StructLayout(LayoutKind.Sequential)]
    private struct SP_DEVICE_INTERFACE_DATA
    {
        public int cbSize;
        public Guid InterfaceClassGuid;
        public int Flags;
        public UIntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SP_DEVINFO_DATA
    {
        public int cbSize;
        public Guid ClassGuid;
        public uint DevInst;
        public UIntPtr Reserved;
    }

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern IntPtr SetupDiGetClassDevsW(ref Guid classGuid, IntPtr enumerator, IntPtr hwnd, uint flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr devInfo, ref Guid classGuid, uint index,
                                                           ref SP_DEVICE_INTERFACE_DATA data);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiGetDeviceInterfaceDetailW(IntPtr set, ref SP_DEVICE_INTERFACE_DATA data, IntPtr detail,
                                                                int detailSize, out int requiredSize, ref SP_DEVINFO_DATA devInfo);

    [DllImport("setupapi.dll")]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security,
                                                     uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr inBuf, int inSize,
                                               out StorageDeviceNumber outBuf, int outSize, out int returned, IntPtr overlapped);

    [StructLayout(LayoutKind.Sequential)]
    private struct StorageDeviceNumber
    {
        public int DeviceType;
        public int DeviceNumber;
        public int PartitionNumber;
    }

    [DllImport("cfgmgr32.dll")]
    private static extern int CM_Get_Parent(out uint parent, uint devInst, uint flags);

    [DllImport("cfgmgr32.dll")]
    private static extern int CM_Get_DevNode_Registry_PropertyW(uint devInst, uint property, out uint dataType,
                                                                ref uint buffer, ref uint length, uint flags);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    private static extern int CM_Request_Device_EjectW(uint devInst, out int vetoType, StringBuilder vetoName,
                                                       int nameLength, uint flags);

    /// <summary>Device node to eject for a disk, or 0 when nothing on its path is removable (an internal drive).</summary>
    public static uint FindEjectTarget(int diskNumber)
    {
        var node = FindDiskNode(diskNumber);
        for (var depth = 0; node != 0 && depth < 16; depth++)
        {
            if (IsRemovable(node)) return node;
            if (CM_Get_Parent(out var parent, node, 0) != CR_SUCCESS) break;
            node = parent;
        }
        return 0;
    }

    /// <summary>Requests the eject. Returns null on success, otherwise why Windows refused.</summary>
    public static string? Eject(uint devInst)
    {
        string? reason = null;
        for (var attempt = 0; attempt < 3; attempt++)
        {
            if (attempt > 0) Thread.Sleep(750);   // a drive scan may briefly hold a handle
            var name = new StringBuilder(260);
            var cr = CM_Request_Device_EjectW(devInst, out var veto, name, name.Capacity, 0);
            if (cr == CR_SUCCESS && veto == 0) return null;
            reason = cr != CR_SUCCESS
                ? $"Configuration Manager error {cr}"
                : (veto < VetoReasons.Length ? VetoReasons[veto] : $"veto type {veto}") + (name.Length > 0 ? $" ({name})" : "");
        }
        return reason;
    }

    private static bool IsRemovable(uint devInst)
    {
        uint caps = 0, length = 4;
        return CM_Get_DevNode_Registry_PropertyW(devInst, CM_DRP_CAPABILITIES, out _, ref caps, ref length, 0) == CR_SUCCESS
            && (caps & CM_DEVCAP_REMOVABLE) != 0;
    }

    // Finds the disk's device node by asking each present disk interface for its device number.
    private static uint FindDiskNode(int diskNumber)
    {
        var guid = DiskInterface;
        var set = SetupDiGetClassDevsW(ref guid, IntPtr.Zero, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (set == new IntPtr(-1)) return 0;
        try
        {
            for (uint i = 0; ; i++)
            {
                var iface = new SP_DEVICE_INTERFACE_DATA { cbSize = Marshal.SizeOf<SP_DEVICE_INTERFACE_DATA>() };
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref guid, i, ref iface)) return 0;
                var info = new SP_DEVINFO_DATA { cbSize = Marshal.SizeOf<SP_DEVINFO_DATA>() };
                SetupDiGetDeviceInterfaceDetailW(set, ref iface, IntPtr.Zero, 0, out var size, ref info);
                if (size <= 0) continue;
                var detail = Marshal.AllocHGlobal(size);
                try
                {
                    // SP_DEVICE_INTERFACE_DETAIL_DATA_W: DWORD cbSize (8 on x64) followed by the path.
                    Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);
                    if (!SetupDiGetDeviceInterfaceDetailW(set, ref iface, detail, size, out _, ref info)) continue;
                    var path = Marshal.PtrToStringUni(detail + 4);
                    if (path == null) continue;
                    using var h = CreateFileW(path, 0, FILE_SHARE_READ_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
                    if (h.IsInvalid) continue;
                    if (DeviceIoControl(h, IOCTL_STORAGE_GET_DEVICE_NUMBER, IntPtr.Zero, 0, out var number,
                                        Marshal.SizeOf<StorageDeviceNumber>(), out _, IntPtr.Zero) &&
                        number.DeviceNumber == diskNumber)
                        return info.DevInst;
                }
                finally
                {
                    Marshal.FreeHGlobal(detail);
                }
            }
        }
        finally
        {
            SetupDiDestroyDeviceInfoList(set);
        }
    }
}
