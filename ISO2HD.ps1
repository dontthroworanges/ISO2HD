<#
.SYNOPSIS
    ISO2HD - writes an .iso image to a hard drive / SSD / USB drive using the
    same logical sector layout a CD/DVD/BD burning application puts on a disc.

.DESCRIPTION
    A burning application treats an .iso as a sequence of 2048-byte user-data
    sectors (Mode 1 / DVD / BD logical blocks) and writes them, in order, as a
    single data track that begins at LBA 0 of the disc. Reading that disc back
    returns exactly those bytes. ISO2HD reproduces that on a block device:

      * Sector 0 of the ISO lands on byte 0 of the drive; every byte keeps its
        offset, so ISO 9660 / Joliet / UDF structures remain valid.
      * A final partial sector is zero-padded to a whole 2048-byte sector, as
        a burner does.
      * The track is padded to the 300-sector (4 second) minimum track length
        required by the Red Book / Yellow Book.
      * Optional extra zero "pad" sectors (like cdrecord -pad).
      * The track is written sequentially, the device cache is flushed
        (synchronize cache), and an optional verify pass reads the track back
        and compares SHA-256 hashes - the burner "verify" step.
      * Stale partition data beyond the track is cleared (the end-of-disk GPT
        backup header by default, or the entire remainder with -ZeroRemainder)
        so the drive presents only the image, like blank media would.

    Physical-layer structures of optical media (lead-in/TOC, EDC/ECC, sub-
    channel, lead-out) do not exist on a hard drive and cannot be replicated;
    they are not part of the data a burner takes from the .iso either.

    BIOS boot fix: a disc that boots through El Torito alone cannot boot from
    a hard drive on a legacy (non-UEFI) PC, because the BIOS looks for an MBR
    in sector 0. When ISO2HD recognises such a disc and knows how to boot it,
    it replaces only the first 512 bytes with a PC boot record; every other
    byte still matches the disc. Supported today:
      * Darwin/x86 install discs (Apple partition map + HFS+ + Darwin cdboot):
        the MBR loads the disc's own Darwin boot2 from 512-byte sectors and
        carries an active type 0xAF partition entry for the HFS+ volume.
    Use -NoBootPatch to write the image unmodified.

    Run with no parameters to open the graphical interface.

.EXAMPLE
    .\ISO2HD.ps1
    Opens the GUI (self-elevates to Administrator).

.EXAMPLE
    .\ISO2HD.ps1 -ListDisks

.EXAMPLE
    .\ISO2HD.ps1 -Inspect D:\images\ubuntu.iso

.EXAMPLE
    .\ISO2HD.ps1 -IsoPath D:\images\ubuntu.iso -DiskNumber 3
    Writes and verifies, asking you to type the disk number to confirm.

.EXAMPLE
    .\ISO2HD.ps1 -IsoPath D:\images\tiger.iso -OutFile D:\vm\tiger-hdd.img
    Writes exactly what would go on a drive into an image file instead, for
    virtual machines or testing. Does not need Administrator rights.

.NOTES
    The ISO2HD app (ISO2HD.exe) runs this script with -Json (drive list and
    image details as JSON) and -ReportStatus (progress lines while writing).
#>
[CmdletBinding(DefaultParameterSetName = 'Gui')]
param(
    # With -ListDisks: the image to be written; the drive holding it is marked as not eligible.
    [Parameter(ParameterSetName = 'Cli', Mandatory = $true)]
    [Parameter(ParameterSetName = 'Export', Mandatory = $true)]
    [Parameter(ParameterSetName = 'List')]
    [string]$IsoPath,

    [Parameter(ParameterSetName = 'Cli', Mandatory = $true)]
    [int]$DiskNumber,

    [Parameter(ParameterSetName = 'Export', Mandatory = $true)]
    [string]$OutFile,

    [Parameter(ParameterSetName = 'Cli')]
    [Parameter(ParameterSetName = 'Export')]
    [switch]$NoVerify,

    [Parameter(ParameterSetName = 'Cli')]
    [switch]$ZeroRemainder,

    [Parameter(ParameterSetName = 'Cli')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateRange(0, 100000)]
    [int]$PadSectors = 0,

    [Parameter(ParameterSetName = 'Cli')]
    [Parameter(ParameterSetName = 'Export')]
    [switch]$NoBootPatch,

    [Parameter(ParameterSetName = 'Cli')]
    [switch]$Force,

    # Print the log as plain lines plus "##PROGRESS|<percent>|<phase>|<status>", "##WAIT|start" /
    # "##WAIT|end" (waiting for the drive to respond) and, on success, "##RESULT|<json>".
    # Exit code 0 = written, 1 = failed, 2 = cancelled.
    [Parameter(ParameterSetName = 'Cli')]
    [switch]$ReportStatus,

    # Name of an event that cancels the write when it is set (used with -ReportStatus).
    [Parameter(ParameterSetName = 'Cli')]
    [string]$CancelEvent,

    [Parameter(ParameterSetName = 'List', Mandatory = $true)]
    [switch]$ListDisks,

    [Parameter(ParameterSetName = 'Inspect', Mandatory = $true)]
    [string]$Inspect,

    # Output -ListDisks / -Inspect as JSON; on failure, {"Error": "<message>"} and exit code 1.
    [Parameter(ParameterSetName = 'List')]
    [Parameter(ParameterSetName = 'Inspect')]
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
if ([Console]::IsOutputRedirected) { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) }

# ---------------------------------------------------------------------------
# Engine. Kept in a script block so the GUI can load it into a background
# runspace as well as the main session.
# ---------------------------------------------------------------------------
$EngineBlock = {
    $ErrorActionPreference = 'Stop'

    if (-not ('IsoDiskProbe' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public sealed class IsoRawDevice : IDisposable
{
    const uint GENERIC_READ = 0x80000000;
    const uint GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ = 0x1;
    const uint FILE_SHARE_WRITE = 0x2;
    const uint OPEN_EXISTING = 3;
    const uint FSCTL_LOCK_VOLUME = 0x00090018;
    const uint FSCTL_DISMOUNT_VOLUME = 0x00090020;
    const uint IOCTL_DISK_GET_LENGTH_INFO = 0x0007405C;
    const uint IOCTL_DISK_UPDATE_PROPERTIES = 0x00070140;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security,
        uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(SafeFileHandle h, byte[] buffer, int toRead, out int read, IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(SafeFileHandle h, byte[] buffer, int toWrite, out int written, IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFilePointerEx(SafeFileHandle h, long distance, out long newPosition, uint method);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool FlushFileBuffers(SafeFileHandle h);

    [DllImport("kernel32.dll", EntryPoint = "DeviceIoControl", SetLastError = true)]
    static extern bool IoctlNoData(SafeFileHandle h, uint code, IntPtr inBuf, int inSize,
        IntPtr outBuf, int outSize, out int returned, IntPtr overlapped);

    [DllImport("kernel32.dll", EntryPoint = "DeviceIoControl", SetLastError = true)]
    static extern bool IoctlInt64(SafeFileHandle h, uint code, IntPtr inBuf, int inSize,
        out long outBuf, int outSize, out int returned, IntPtr overlapped);

    readonly SafeFileHandle handle;
    public string Path { get; private set; }

    public IsoRawDevice(string path, bool write)
    {
        Path = path;
        uint access = GENERIC_READ | (write ? GENERIC_WRITE : 0);
        handle = CreateFileW(path, access, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (handle.IsInvalid) Fail("Open");
    }

    public void Seek(long offset)
    {
        long pos;
        if (!SetFilePointerEx(handle, offset, out pos, 0)) Fail("Seek");
    }

    public void Write(byte[] buffer, int count)
    {
        int written;
        if (!WriteFile(handle, buffer, count, out written, IntPtr.Zero)) Fail("Write");
        if (written != count)
            throw new System.IO.IOException(string.Format("Short write on {0}: {1} of {2} bytes.", Path, written, count));
    }

    public int Read(byte[] buffer, int count)
    {
        int read;
        if (!ReadFile(handle, buffer, count, out read, IntPtr.Zero)) Fail("Read");
        return read;
    }

    public void Flush()
    {
        if (!FlushFileBuffers(handle)) Fail("Flush");
    }

    public long GetLength()
    {
        long length; int returned;
        if (!IoctlInt64(handle, IOCTL_DISK_GET_LENGTH_INFO, IntPtr.Zero, 0, out length, 8, out returned, IntPtr.Zero))
            Fail("Query length");
        return length;
    }

    public bool TryLock(int attempts, int delayMs)
    {
        for (int i = 0; i < attempts; i++)
        {
            int returned;
            if (IoctlNoData(handle, FSCTL_LOCK_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out returned, IntPtr.Zero))
                return true;
            Thread.Sleep(delayMs);
        }
        return false;
    }

    public void Dismount()
    {
        int returned;
        if (!IoctlNoData(handle, FSCTL_DISMOUNT_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out returned, IntPtr.Zero))
            Fail("Dismount");
    }

    public void UpdateProperties()
    {
        int returned;
        IoctlNoData(handle, IOCTL_DISK_UPDATE_PROPERTIES, IntPtr.Zero, 0, IntPtr.Zero, 0, out returned, IntPtr.Zero);
    }

    void Fail(string operation)
    {
        int err = Marshal.GetLastWin32Error();
        throw new Win32Exception(err, string.Format("{0} failed on {1}: {2}", operation, Path, new Win32Exception(err).Message));
    }

    public void Dispose()
    {
        handle.Dispose();
    }
}

public sealed class IsoDiskInfo
{
    public int Number;
    public string Vendor;
    public string Product;
    public int BusType;
    public bool Removable;
    public long SizeBytes;
    public int LogicalSectorSize;
    public int PartitionStyle;      // 0 MBR, 1 GPT, 2 RAW, -1 unknown
    public bool IsOffline;
    public bool IsReadOnly;
}

// Disk and volume queries answered by Windows' disk, partition and volume drivers from data they
// already hold. Handles are opened with no read/write access, and nothing goes through the Storage
// Management (WMI) service, whose per-disk probing can wait a minute on a USB adapter that is slow
// to wake from power saving.
public static class IsoDiskProbe
{
    const uint FILE_SHARE_READ_WRITE = 0x3;
    const uint OPEN_EXISTING = 3;
    const uint IOCTL_STORAGE_QUERY_PROPERTY = 0x002D1400;
    const uint IOCTL_STORAGE_GET_DEVICE_NUMBER = 0x002D1080;
    const uint IOCTL_DISK_GET_DRIVE_GEOMETRY_EX = 0x000700A0;
    const uint IOCTL_DISK_GET_DRIVE_LAYOUT_EX = 0x00070050;
    const uint IOCTL_DISK_GET_DISK_ATTRIBUTES = 0x000700F0;
    const uint IOCTL_DISK_UPDATE_PROPERTIES = 0x00070140;
    const uint IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS = 0x00560000;
    const int ERROR_INSUFFICIENT_BUFFER = 122;
    const int ERROR_MORE_DATA = 234;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security,
        uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] inBuf, int inSize,
        byte[] outBuf, int outSize, out int returned, IntPtr overlapped);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr FindFirstVolumeW(StringBuilder name, int length);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool FindNextVolumeW(IntPtr find, StringBuilder name, int length);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool FindVolumeClose(IntPtr find);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool GetVolumePathNameW(string fileName, StringBuilder volumePath, int length);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool GetVolumeNameForVolumeMountPointW(string mountPoint, StringBuilder volumeName, int length);

    static SafeFileHandle OpenForQuery(string path)
    {
        return CreateFileW(path, 0, FILE_SHARE_READ_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
    }

    static byte[] Ioctl(SafeFileHandle h, uint code, byte[] input, int outSize, int maxSize)
    {
        while (true)
        {
            byte[] output = new byte[outSize];
            int returned;
            if (DeviceIoControl(h, code, input, input == null ? 0 : input.Length, output, outSize, out returned, IntPtr.Zero))
            {
                Array.Resize(ref output, returned);
                return output;
            }
            int err = Marshal.GetLastWin32Error();
            if ((err == ERROR_INSUFFICIENT_BUFFER || err == ERROR_MORE_DATA) && outSize < maxSize)
            {
                outSize *= 4;
                continue;
            }
            return null;
        }
    }

    static string AnsiAt(byte[] b, uint offset)
    {
        if (offset == 0 || offset >= b.Length) return "";
        int end = (int)offset;
        while (end < b.Length && b[end] != 0) end++;
        return Encoding.ASCII.GetString(b, (int)offset, end - (int)offset).Trim();
    }

    public static IsoDiskInfo[] GetDisks(int maxDisks)
    {
        List<IsoDiskInfo> disks = new List<IsoDiskInfo>();
        for (int n = 0; n < maxDisks; n++)
        {
            using (SafeFileHandle h = OpenForQuery(@"\\.\PhysicalDrive" + n))
            {
                if (h.IsInvalid) continue;
                IsoDiskInfo d = new IsoDiskInfo();
                d.Number = n;
                d.PartitionStyle = -1;

                byte[] number = Ioctl(h, IOCTL_STORAGE_GET_DEVICE_NUMBER, null, 12, 12);
                if (number != null && number.Length >= 8) d.Number = BitConverter.ToInt32(number, 4);

                byte[] desc = Ioctl(h, IOCTL_STORAGE_QUERY_PROPERTY, new byte[12], 1024, 16384);
                if (desc != null && desc.Length >= 32)
                {
                    d.Removable = desc[10] != 0;
                    d.Vendor = AnsiAt(desc, BitConverter.ToUInt32(desc, 12));
                    d.Product = AnsiAt(desc, BitConverter.ToUInt32(desc, 16));
                    d.BusType = BitConverter.ToInt32(desc, 28);
                }

                byte[] geometry = Ioctl(h, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, null, 256, 256);
                if (geometry != null && geometry.Length >= 32)
                {
                    d.LogicalSectorSize = BitConverter.ToInt32(geometry, 20);
                    d.SizeBytes = BitConverter.ToInt64(geometry, 24);
                }

                byte[] layout = Ioctl(h, IOCTL_DISK_GET_DRIVE_LAYOUT_EX, null, 16384, 1 << 20);
                if (layout != null && layout.Length >= 4) d.PartitionStyle = BitConverter.ToInt32(layout, 0);

                byte[] attributes = Ioctl(h, IOCTL_DISK_GET_DISK_ATTRIBUTES, null, 16, 16);
                if (attributes != null && attributes.Length >= 16)
                {
                    ulong a = BitConverter.ToUInt64(attributes, 8);
                    d.IsOffline = (a & 1) != 0;
                    d.IsReadOnly = (a & 2) != 0;
                }
                disks.Add(d);
            }
        }
        return disks.ToArray();
    }

    public static int[] GetVolumeDiskNumbers(string volumePath)
    {
        List<int> result = new List<int>();
        using (SafeFileHandle h = OpenForQuery(volumePath.TrimEnd('\\')))
        {
            if (h.IsInvalid) return result.ToArray();
            byte[] extents = Ioctl(h, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, null, 256, 65536);
            if (extents == null || extents.Length < 8) return result.ToArray();
            int count = BitConverter.ToInt32(extents, 0);
            for (int i = 0; i < count && 8 + 24 * i + 4 <= extents.Length; i++)
            {
                int disk = BitConverter.ToInt32(extents, 8 + 24 * i);
                if (!result.Contains(disk)) result.Add(disk);
            }
        }
        return result.ToArray();
    }

    public static string[] GetVolumes()
    {
        List<string> list = new List<string>();
        StringBuilder name = new StringBuilder(512);
        IntPtr find = FindFirstVolumeW(name, name.Capacity);
        if (find == new IntPtr(-1)) return list.ToArray();
        try
        {
            do { list.Add(name.ToString().TrimEnd('\\')); } while (FindNextVolumeW(find, name, name.Capacity));
        }
        finally
        {
            FindVolumeClose(find);
        }
        return list.ToArray();
    }

    public static string[] GetVolumesOnDisk(int diskNumber)
    {
        List<string> list = new List<string>();
        foreach (string volume in GetVolumes())
            if (Array.IndexOf(GetVolumeDiskNumbers(volume), diskNumber) >= 0) list.Add(volume);
        return list.ToArray();
    }

    public static int[] GetPathDiskNumbers(string path)
    {
        StringBuilder mountPoint = new StringBuilder(1024);
        if (!GetVolumePathNameW(path, mountPoint, mountPoint.Capacity)) return new int[0];
        StringBuilder volume = new StringBuilder(512);
        if (!GetVolumeNameForVolumeMountPointW(mountPoint.ToString(), volume, volume.Capacity)) return new int[0];
        return GetVolumeDiskNumbers(volume.ToString());
    }

    public static void UpdateDiskProperties(int diskNumber)
    {
        using (SafeFileHandle h = OpenForQuery(@"\\.\PhysicalDrive" + diskNumber))
        {
            if (!h.IsInvalid) Ioctl(h, IOCTL_DISK_UPDATE_PROPERTIES, null, 0, 0);
        }
    }
}
'@
    }

    function Format-IsoBytes {
        param([double]$Bytes)
        $units = 'B', 'KB', 'MB', 'GB', 'TB'
        $i = 0
        while ($Bytes -ge 1024 -and $i -lt $units.Count - 1) { $Bytes /= 1024; $i++ }
        '{0:N2} {1}' -f $Bytes, $units[$i]
    }

    function ConvertTo-IsoHex {
        param([byte[]]$Bytes)
        ([BitConverter]::ToString($Bytes)).Replace('-', '').ToLowerInvariant()
    }

    function Read-IsoFull {
        param([System.IO.Stream]$Stream, [byte[]]$Buffer, [int]$Count)
        $total = 0
        while ($total -lt $Count) {
            $n = $Stream.Read($Buffer, $total, $Count - $total)
            if ($n -le 0) { break }
            $total += $n
        }
        return $total
    }

    function Write-IsoLog {
        param([hashtable]$State, [string]$Message, [string]$Level = 'INFO')
        $line = '[{0:HH:mm:ss}] {1,-5} {2}' -f (Get-Date), $Level, $Message
        if ($State -and $State.ContainsKey('Log') -and $State.Log) { $State.Log.Enqueue($line) }
        if ($State -and $State.Report) { Write-Host $line }
        if ($State -and $State.Console) {
            $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'OK' { 'Green' } default { 'Gray' } }
            Write-Host $line -ForegroundColor $color
        }
    }

    function Set-IsoProgress {
        param([hashtable]$State, [string]$Phase, [long]$Done, [long]$Total, [System.Diagnostics.Stopwatch]$Clock)
        $pct = 0
        if ($Total -gt 0) { $pct = [int][Math]::Floor(100.0 * $Done / $Total) }
        $rate = 0.0
        $eta = ''
        $secs = $Clock.Elapsed.TotalSeconds
        if ($secs -gt 0.5 -and $Done -gt 0) {
            $rate = $Done / $secs
            if ($Total -gt $Done) { $eta = ', ETA ' + [TimeSpan]::FromSeconds(($Total - $Done) / $rate).ToString('hh\:mm\:ss') }
        }
        $status = '{0} of {1} ({2}/s{3})' -f (Format-IsoBytes $Done), (Format-IsoBytes $Total), (Format-IsoBytes $rate), $eta
        $State.Phase = $Phase
        $State.Percent = $pct
        $State.Status = $status
        if ($State.Console) { Write-Progress -Activity 'ISO2HD' -Status "$Phase - $status" -PercentComplete $pct }
        if ($State.Report) { Write-Host "##PROGRESS|$pct|$Phase|$status" }
    }

    function Set-IsoWaiting {
        # Marks the time spent waiting for a drive to answer, which the GUIs show as it goes.
        param([hashtable]$State, [bool]$Waiting)
        if ($Waiting) { $State.WaitingSince = [DateTime]::UtcNow } else { $State.WaitingSince = $null }
        if ($State.Report) { Write-Host "##WAIT|$(if ($Waiting) { 'start' } else { 'end' })" }
    }

    function Get-IsoPathDiskNumbers {
        # Disks holding the volume a local path lives on (empty for network paths).
        param([string]$Path)
        try {
            return @([IsoDiskProbe]::GetPathDiskNumbers((Resolve-Path -LiteralPath $Path).ProviderPath))
        } catch {
            return @()
        }
    }

    function Get-IsoProtectedDisks {
        # Boot disk = holds the Windows volume; system disk = holds the system (EFI/boot) partition.
        $boot = @([IsoDiskProbe]::GetPathDiskNumbers($env:SystemRoot))
        $system = @()
        try {
            $partition = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup' -Name SystemPartition -ErrorAction Stop).SystemPartition
            if ($partition) { $system = @([IsoDiskProbe]::GetVolumeDiskNumbers('\\?\GLOBALROOT' + $partition)) }
        } catch { }
        @{ Boot = $boot; System = $system }
    }

    function Get-MbrChs {
        # CHS triple for an MBR partition entry, using the conventional 255-head / 63-sector geometry.
        param([uint32]$Lba)
        $cyl = [int][Math]::Floor($Lba / (255 * 63))
        if ($cyl -gt 1023) { return [byte[]](0xFE, 0xFF, 0xFF) }
        $head = [int]([Math]::Floor($Lba / 63) % 255)
        $sector = [int]($Lba % 63) + 1
        [byte[]]($head, ($sector -bor (($cyl -shr 8) -shl 6)), ($cyl -band 0xFF))
    }

    function New-DarwinBiosMbr {
        <#
          Builds a 512-byte MBR for a Darwin/x86 disc written to a 512-byte-sector drive.

          Boot code (real mode, loaded at 0000:7C00, DL = BIOS boot drive):
            1. Probe INT 13h extensions (AH=41h); fall back to CHS (AH=08h geometry, AH=02h reads).
            2. Read Boot2Sectors 512-byte sectors starting at Boot2Lba into 2000:0200, one sector
               at a time with up to 5 attempts each.
            3. Jump to 2000:0200 with EDX = boot drive and ES = 0 - the same hand-off the disc's
               own cdboot stub makes to Darwin boot2.
          Partition table: entry 1 is active, type 0xAF (Apple HFS), covering the HFS+ volume.
        #>
        param(
            [Parameter(Mandatory = $true)][int]$Boot2Lba,
            [Parameter(Mandatory = $true)][int]$Boot2Sectors,
            [Parameter(Mandatory = $true)][uint32]$PartStart,
            [Parameter(Mandatory = $true)][uint32]$PartSectors,
            [uint32]$DiskSignature = 0x4F534932,
            [switch]$ForceChs
        )

        $code = New-Object System.Collections.Generic.List[byte]
        $labels = @{}
        $fixups = New-Object System.Collections.Generic.List[object]
        function Emit { foreach ($x in $args) { $code.Add([byte]$x) } }
        function Emit16([int]$Value) { $code.Add([byte]($Value -band 0xFF)); $code.Add([byte](($Value -shr 8) -band 0xFF)) }
        function Mark([string]$Name) { $labels[$Name] = $code.Count }
        function Jr8([int]$Opcode, [string]$Name) { $code.Add([byte]$Opcode); $fixups.Add(@('rel8', $code.Count, $Name, 0)); $code.Add(0) }
        function CallRel([string]$Name) { $code.Add(0xE8); $fixups.Add(@('rel16', $code.Count, $Name, 0)); $code.Add(0); $code.Add(0) }
        function Ref16([string]$Name, [int]$Add = 0) { $fixups.Add(@('abs16', $code.Count, $Name, $Add)); $code.Add(0); $code.Add(0) }

        Emit 0xFA                                   # cli
        Emit 0x31 0xC0                              # xor  ax,ax
        Emit 0x8E 0xD0                              # mov  ss,ax
        Emit 0xBC; Emit16 0x7C00                    # mov  sp,7C00h
        Emit 0xFB                                   # sti
        Emit 0xFC                                   # cld
        Emit 0x8E 0xD8                              # mov  ds,ax
        Emit 0x8E 0xC0                              # mov  es,ax
        Emit 0x88 0x16; Ref16 'drive'               # mov  [drive],dl
        if ($ForceChs) { Jr8 0xEB 'chs' }           # (test build: skip the extensions probe)

        Emit 0xB4 0x41                              # mov  ah,41h        ; extensions present?
        Emit 0xBB; Emit16 0x55AA                    # mov  bx,55AAh
        Emit 0xCD 0x13                              # int  13h
        Jr8 0x72 'chs'                              # jc   chs
        Emit 0x81 0xFB; Emit16 0xAA55               # cmp  bx,0AA55h
        Jr8 0x75 'chs'                              # jne  chs
        Emit 0xF6 0xC1 0x01                         # test cl,1          ; DAP packet reads supported
        Jr8 0x74 'chs'                              # jz   chs
        Emit 0xC6 0x06; Ref16 'edd'; Emit 0x01      # mov  byte [edd],1
        Jr8 0xEB 'load'                             # jmp  load

        Mark 'chs'
        Emit 0x8A 0x16; Ref16 'drive'               # mov  dl,[drive]
        Emit 0xB4 0x08                              # mov  ah,08h        ; drive geometry
        Emit 0x31 0xFF                              # xor  di,di         ; ES:DI = 0:0 (BIOS bug guard)
        Emit 0xCD 0x13                              # int  13h
        Jr8 0x72 'fail'                             # jc   fail
        Emit 0x30 0xED                              # xor  ch,ch
        Emit 0x83 0xE1 0x3F                         # and  cx,3Fh        ; sectors per track
        Jr8 0x74 'fail'                             # jz   fail
        Emit 0x89 0x0E; Ref16 'spt'                 # mov  [spt],cx
        Emit 0x88 0xF0                              # mov  al,dh         ; last head index
        Emit 0x30 0xE4                              # xor  ah,ah
        Emit 0x40                                   # inc  ax
        Emit 0xA3; Ref16 'heads'                    # mov  [heads],ax

        Mark 'load'
        Emit 0xB8; Emit16 0x2000                    # mov  ax,2000h
        Emit 0x8E 0xC0                              # mov  es,ax
        Emit 0xBE; Emit16 $Boot2Lba                 # mov  si,boot2 LBA
        Emit 0xBF; Emit16 0x0200                    # mov  di,0200h
        Mark 'next'
        Emit 0xBD; Emit16 5                         # mov  bp,5          ; attempts per sector
        Mark 'retry'
        CallRel 'readsec'                           # call readsec
        Jr8 0x73 'ok'                               # jnc  ok
        Emit 0x8A 0x16; Ref16 'drive'               # mov  dl,[drive]
        Emit 0x31 0xC0                              # xor  ax,ax         ; reset disk system
        Emit 0xCD 0x13                              # int  13h
        Emit 0x4D                                   # dec  bp
        Jr8 0x75 'retry'                            # jnz  retry
        Jr8 0xEB 'fail'                             # jmp  fail
        Mark 'ok'
        Emit 0x81 0xC7; Emit16 0x0200               # add  di,200h
        Emit 0x46                                   # inc  si
        Emit 0x81 0xFE; Emit16 ($Boot2Lba + $Boot2Sectors)  # cmp si,end LBA
        Jr8 0x72 'next'                             # jb   next

        Emit 0x8A 0x16; Ref16 'drive'               # mov  dl,[drive]
        Emit 0x66 0x0F 0xB6 0xD2                    # movzx edx,dl
        Emit 0x31 0xC0                              # xor  ax,ax
        Emit 0x8E 0xC0                              # mov  es,ax
        Emit 0xEA; Emit16 0x0200; Emit16 0x2000     # jmp  2000h:0200h   ; Darwin boot2

        Mark 'fail'
        Emit 0xBE; Ref16 'message'                  # mov  si,message
        Mark 'print'
        Emit 0xAC                                   # lodsb
        Emit 0x84 0xC0                              # test al,al
        Jr8 0x74 'hang'                             # jz   hang
        Emit 0xB4 0x0E                              # mov  ah,0Eh        ; teletype output
        Emit 0xBB; Emit16 0x0007                    # mov  bx,0007h
        Emit 0xCD 0x10                              # int  10h
        Jr8 0xEB 'print'                            # jmp  print
        Mark 'hang'
        Emit 0xFB                                   # sti
        Mark 'halt'
        Emit 0xF4                                   # hlt
        Jr8 0xEB 'halt'                             # jmp  halt

        Mark 'readsec'                              # in: SI = LBA, ES:DI = buffer; out: CF
        Emit 0x57 0x55 0x56                         # push di / push bp / push si
        Emit 0x80 0x3E; Ref16 'edd'; Emit 0x00      # cmp  byte [edd],0
        Jr8 0x74 'readchs'                          # je   readchs
        Emit 0xC7 0x06; Ref16 'dap' 2; Emit16 1     # mov  word [dap+2],1   ; sector count
        Emit 0x89 0x3E; Ref16 'dap' 4               # mov  [dap+4],di       ; buffer offset
        Emit 0x89 0x36; Ref16 'dap' 8               # mov  [dap+8],si       ; LBA (low word)
        Emit 0x8A 0x16; Ref16 'drive'               # mov  dl,[drive]
        Emit 0xB4 0x42                              # mov  ah,42h
        Emit 0xBE; Ref16 'dap'                      # mov  si,dap
        Emit 0xCD 0x13                              # int  13h
        Jr8 0xEB 'readdone'                         # jmp  readdone
        Mark 'readchs'
        Emit 0x89 0xF0                              # mov  ax,si
        Emit 0x31 0xD2                              # xor  dx,dx
        Emit 0xF7 0x36; Ref16 'spt'                 # div  word [spt]
        Emit 0x42                                   # inc  dx            ; sector (1-based)
        Emit 0x88 0xD1                              # mov  cl,dl
        Emit 0x31 0xD2                              # xor  dx,dx
        Emit 0xF7 0x36; Ref16 'heads'               # div  word [heads]
        Emit 0x88 0xD6                              # mov  dh,dl         ; head
        Emit 0x88 0xC5                              # mov  ch,al         ; cylinder
        Emit 0x8A 0x16; Ref16 'drive'               # mov  dl,[drive]
        Emit 0x89 0xFB                              # mov  bx,di
        Emit 0xB8; Emit16 0x0201                    # mov  ax,0201h      ; read 1 sector
        Emit 0xCD 0x13                              # int  13h
        Mark 'readdone'
        Emit 0x5E 0x5D 0x5F                         # pop  si / pop bp / pop di
        Emit 0xC3                                   # ret

        Mark 'drive'; Emit 0
        Mark 'edd'; Emit 0
        Mark 'spt'; Emit16 0
        Mark 'heads'; Emit16 0
        Mark 'dap'; Emit 0x10 0; Emit16 1; Emit16 0; Emit16 0x2000; Emit 0 0 0 0 0 0 0 0
        Mark 'message'
        foreach ($c in [System.Text.Encoding]::ASCII.GetBytes("ISO2HD: cannot load Darwin boot2")) { $code.Add($c) }
        Emit 0

        foreach ($f in $fixups) {
            $kind, $at, $name, $add = $f
            if (-not $labels.ContainsKey($name)) { throw "MBR assembler: unknown label '$name'." }
            $target = $labels[$name]
            switch ($kind) {
                'rel8' {
                    $disp = $target - ($at + 1)
                    if ($disp -lt -128 -or $disp -gt 127) { throw "MBR assembler: short jump to '$name' out of range ($disp)." }
                    $code[$at] = [byte]($disp -band 0xFF)
                }
                'rel16' {
                    $disp = ($target - ($at + 2)) -band 0xFFFF
                    $code[$at] = [byte]($disp -band 0xFF); $code[$at + 1] = [byte]($disp -shr 8)
                }
                'abs16' {
                    $addr = 0x7C00 + $target + $add
                    $code[$at] = [byte]($addr -band 0xFF); $code[$at + 1] = [byte]($addr -shr 8)
                }
            }
        }
        if ($code.Count -gt 440) { throw "MBR assembler: boot code is $($code.Count) bytes; the limit is 440." }

        $mbr = New-Object byte[] 512
        $code.CopyTo($mbr, 0)
        [BitConverter]::GetBytes($DiskSignature).CopyTo($mbr, 440)
        $e = 446
        $mbr[$e] = 0x80
        (Get-MbrChs $PartStart).CopyTo($mbr, $e + 1)
        $mbr[$e + 4] = 0xAF
        (Get-MbrChs ([uint32]($PartStart + $PartSectors - 1))).CopyTo($mbr, $e + 5)
        [BitConverter]::GetBytes($PartStart).CopyTo($mbr, $e + 8)
        [BitConverter]::GetBytes($PartSectors).CopyTo($mbr, $e + 12)
        $mbr[510] = 0x55
        $mbr[511] = 0xAA
        , $mbr
    }

    function Get-IsoBootPatch {
        # Returns a BIOS boot fix for discs that only boot through El Torito and whose layout
        # ISO2HD understands, or $null when no fix applies.
        param([Parameter(Mandatory = $true)][string]$Path, [switch]$ForceChs)
        $full = (Resolve-Path -LiteralPath $Path).ProviderPath
        $fs = [System.IO.File]::Open($full, 'Open', 'Read', 'Read')
        try {
            $ascii = [System.Text.Encoding]::ASCII
            $readAt = { param([long]$Offset, [int]$Count) $b = New-Object byte[] $Count; $fs.Position = $Offset; [void](Read-IsoFull $fs $b $Count); , $b }
            $be16 = { param($b, $o) ([int]$b[$o] -shl 8) -bor $b[$o + 1] }
            $be32 = { param($b, $o) [uint32]((([long]$b[$o]) -shl 24) -bor (([long]$b[$o + 1]) -shl 16) -bor (([long]$b[$o + 2]) -shl 8) -bor $b[$o + 3]) }
            $sha = [System.Security.Cryptography.SHA256]::Create()

            # ---- Darwin/x86: Apple partition map + HFS+ + El Torito cdboot + boot2 ----
            $s0 = & $readAt 0 1024
            if ($s0[510] -eq 0x55 -and $s0[511] -eq 0xAA) { return $null }      # already has a PC boot record
            if ($ascii.GetString($s0, 0, 2) -ne 'ER' -or $ascii.GetString($s0, 512, 2) -ne 'PM') { return $null }
            if ((& $be16 $s0 2) -ne 512) { return $null }

            $pvd = & $readAt (16 * 2048) 2048
            $brvd = & $readAt (17 * 2048) 2048
            if ($ascii.GetString($pvd, 1, 5) -ne 'CD001' -or $pvd[0] -ne 1) { return $null }
            if ($ascii.GetString($brvd, 1, 5) -ne 'CD001' -or $brvd[0] -ne 0 -or
                $ascii.GetString($brvd, 7, 23) -ne 'EL TORITO SPECIFICATION') { return $null }
            $cat = & $readAt ([long][BitConverter]::ToUInt32($brvd, 0x47) * 2048) 64
            if ($cat[0] -ne 1 -or $cat[1] -ne 0 -or $cat[30] -ne 0x55 -or $cat[31] -ne 0xAA) { return $null }
            if ($cat[32] -ne 0x88 -or ($cat[33] -band 0x0F) -ne 0) { return $null }  # bootable, no emulation
            $loadRba = [BitConverter]::ToUInt32($cat, 40)

            $rootLba = [BitConverter]::ToUInt32($pvd, 158)
            $rootLen = [BitConverter]::ToUInt32($pvd, 166)
            if ($rootLen -eq 0 -or $rootLen -gt 1MB) { return $null }
            $dir = & $readAt ([long]$rootLba * 2048) ([int]$rootLen)
            $files = @{}
            $o = 0
            while ($o -lt $dir.Length) {
                $len = $dir[$o]
                if ($len -eq 0) { $o = ([int][Math]::Floor($o / 2048) + 1) * 2048; continue }
                $name = ($ascii.GetString($dir, $o + 33, $dir[$o + 32]) -replace ';\d+$', '').TrimEnd('.').ToUpperInvariant()
                $files[$name] = @([BitConverter]::ToUInt32($dir, $o + 2), [BitConverter]::ToUInt32($dir, $o + 10))
                $o += $len
            }
            if (-not ($files.ContainsKey('CDBOOT') -and $files.ContainsKey('BOOT'))) { return $null }
            if ($files['CDBOOT'][0] -ne $loadRba) { return $null }
            $bootLba = [long]$files['BOOT'][0]
            $bootSize = [int]$files['BOOT'][1]
            if ($bootSize -le 0 -or $bootSize -gt 127 * 512) { return $null }
            $boot2 = & $readAt ($bootLba * 2048) $bootSize
            if ($ascii.GetString($boot2).IndexOf('Darwin/x86 boot') -lt 0) { return $null }
            # cdboot = 2048-byte stub + this exact boot2; that is what the CD path runs.
            $cdTail = & $readAt ([long]$loadRba * 2048 + 2048) $bootSize
            if ([BitConverter]::ToString($sha.ComputeHash($boot2)) -ne [BitConverter]::ToString($sha.ComputeHash($cdTail))) { return $null }

            $part = $null
            $mapEntries = & $be32 $s0 516
            for ($i = 1; $i -le [Math]::Min([long]$mapEntries, 63); $i++) {
                $entry = & $readAt ([long]$i * 512) 512
                if ($ascii.GetString($entry, 0, 2) -ne 'PM') { break }
                if ($ascii.GetString($entry, 48, 32).Trim([char]0) -ne 'Apple_HFS') { continue }
                $start = & $be32 $entry 8
                $count = & $be32 $entry 12
                $vh = & $readAt ([long]$start * 512 + 1024) 512
                $sig = $ascii.GetString($vh, 0, 2)
                if ($sig -eq 'H+' -or $sig -eq 'HX') {
                    $uuidLow = [BitConverter]::ToUInt32($vh, 108)
                    $part = @($start, $count, $ascii.GetString($entry, 16, 32).Trim([char]0), $uuidLow)
                    break
                }
            }
            if (-not $part) { return $null }
            if (([long]$part[0] + $part[1]) -gt [uint32]::MaxValue) { return $null }

            $boot2Lba = [int]($bootLba * 4)
            $boot2Sectors = [int][Math]::Ceiling($bootSize / 512)
            if ($boot2Lba + $boot2Sectors -gt 0xFFFF) { return $null }
            $diskSig = [uint32]$part[3]
            if ($diskSig -eq 0) { $diskSig = [uint32]0x4F534932 }
            $mbr = New-DarwinBiosMbr -Boot2Lba $boot2Lba -Boot2Sectors $boot2Sectors -PartStart $part[0] `
                -PartSectors $part[1] -DiskSignature $diskSig -ForceChs:$ForceChs

            [pscustomobject]@{
                Kind             = 'Darwin/x86'
                Description      = ("MBR loads Darwin boot2 from 512-byte sectors {0}-{1}; active type 0xAF partition '{2}' at sector {3}, {4} sectors" -f
                    $boot2Lba, ($boot2Lba + $boot2Sectors - 1), $part[2], $part[0], $part[1])
                Boot2Lba         = $boot2Lba
                Boot2Sectors     = $boot2Sectors
                PartitionStart   = [uint32]$part[0]
                PartitionSectors = [uint32]$part[1]
                Mbr              = $mbr
            }
        } finally {
            $fs.Dispose()
        }
    }

    function Get-IsoInfo {
        param([Parameter(Mandatory = $true)][string]$Path)
        $full = (Resolve-Path -LiteralPath $Path).ProviderPath
        $fs = [System.IO.File]::Open($full, 'Open', 'Read', 'Read')
        try {
            $size = $fs.Length
            $buf = New-Object byte[] 2048
            $ascii = [System.Text.Encoding]::ASCII
            $iso9660 = $false; $udf = $false; $elTorito = $false; $mbr = $false; $rawSync = $false
            $label = ''; $declared = [long]0

            if ((Read-IsoFull $fs $buf 512) -eq 512) {
                $mbr = ($buf[510] -eq 0x55 -and $buf[511] -eq 0xAA)
                $rawSync = ($buf[0] -eq 0 -and $buf[11] -eq 0 -and @($buf[1..10] | Where-Object { $_ -ne 0xFF }).Count -eq 0)
            }

            # Volume descriptors / UDF volume recognition sequence start at sector 16.
            for ($s = 16; $s -lt 64; $s++) {
                $fs.Position = [long]$s * 2048
                if ((Read-IsoFull $fs $buf 2048) -lt 2048) { break }
                $id = $ascii.GetString($buf, 1, 5)
                if ($id -eq 'CD001') {
                    $iso9660 = $true
                    if ($buf[0] -eq 0 -and $ascii.GetString($buf, 7, 23) -eq 'EL TORITO SPECIFICATION') {
                        $elTorito = $true
                    } elseif ($buf[0] -eq 1) {
                        $label = $ascii.GetString($buf, 40, 32).Trim([char[]]@([char]0, ' '))
                        $declared = [long][BitConverter]::ToUInt32($buf, 80) * [BitConverter]::ToUInt16($buf, 128)
                    }
                } elseif ($id -eq 'NSR02' -or $id -eq 'NSR03') {
                    $udf = $true
                } elseif ($id -eq 'TEA01') {
                    break
                } elseif ($id -ne 'BEA01' -and ($iso9660 -or $udf)) {
                    break
                }
            }

            $warnings = New-Object System.Collections.Generic.List[string]
            if (-not ($iso9660 -or $udf)) {
                if ($rawSync) {
                    $warnings.Add('Image starts with a CD sync pattern: this is a raw 2352-byte BIN, not a 2048-byte ISO. A burner would need its CUE sheet; writing it as-is will not produce a readable volume.')
                } else {
                    $warnings.Add('No ISO 9660 or UDF volume descriptors found. The file will be written as a raw data track exactly as a burner would, but it may not be a disc image.')
                }
            }
            if ($size % 2048 -ne 0) {
                $warnings.Add("Image size is not a multiple of 2048 bytes; the last sector will be zero-padded (burners do the same).")
            }
            if ($declared -gt $size) {
                $warnings.Add("Image appears truncated: volume declares $(Format-IsoBytes $declared) but file is $(Format-IsoBytes $size).")
            }
            $patch = $null
            try { $patch = Get-IsoBootPatch -Path $full } catch { }
            $biosBoot = 'Not bootable'
            if ($mbr -and ($iso9660 -or $udf)) {
                $biosBoot = 'Hybrid MBR - boots from a hard drive as-is'
            } elseif ($patch) {
                $biosBoot = "$($patch.Kind) - ISO2HD adds a BIOS boot record"
            } elseif ($elTorito) {
                $biosBoot = 'CD-only - will not boot from a hard drive'
                $warnings.Add('El Torito (CD-boot) image without an MBR, and no known boot fix for it: data will be identical, but PC firmware will not boot it from a hard drive.')
            }

            [pscustomobject]@{
                Path          = $full
                SizeBytes     = [long]$size
                Size          = Format-IsoBytes $size
                Sectors       = [long][Math]::Ceiling($size / 2048)
                VolumeLabel   = $label
                IsIso9660     = $iso9660
                IsUdf         = $udf
                IsElTorito    = $elTorito
                HasMbr        = $mbr
                IsHybrid      = ($mbr -and ($iso9660 -or $udf))
                BiosBoot      = $biosBoot
                BootPatch     = $patch
                DeclaredBytes = $declared
                Warnings      = [string[]]$warnings.ToArray()
            }
        } finally {
            $fs.Dispose()
        }
    }

    function Get-IsoTargetDisk {
        param([string]$ExcludePath)
        $busNames = @{ 0 = 'Unknown'; 1 = 'SCSI'; 2 = 'ATAPI'; 3 = 'ATA'; 4 = '1394'; 5 = 'SSA'; 6 = 'Fibre Channel'; 7 = 'USB'
            8 = 'RAID'; 9 = 'iSCSI'; 10 = 'SAS'; 11 = 'SATA'; 12 = 'SD'; 13 = 'MMC'; 14 = 'Virtual'; 15 = 'File Backed Virtual'
            16 = 'Storage Spaces'; 17 = 'NVMe'; 18 = 'SCM'; 19 = 'UFS' }
        $styles = @{ 0 = 'MBR'; 1 = 'GPT'; 2 = 'RAW' }

        $protected = Get-IsoProtectedDisks
        if ($protected.Boot.Count -eq 0) {
            throw 'Could not identify the disk that holds Windows, so no drives are listed (this keeps the system disk from ever being offered as a target).'
        }
        $isoDisks = @()
        if ($ExcludePath -and (Test-Path -LiteralPath $ExcludePath)) { $isoDisks = @(Get-IsoPathDiskNumbers $ExcludePath) }

        foreach ($d in ([IsoDiskProbe]::GetDisks(64) | Sort-Object Number)) {
            $reason = @()
            if ($protected.Boot -contains $d.Number) { $reason += 'boot disk' }
            if ($protected.System -contains $d.Number) { $reason += 'system disk' }
            if ($d.IsReadOnly) { $reason += 'read-only' }
            if ($d.SizeBytes -le 0) { $reason += 'no media' }
            if ($isoDisks -contains $d.Number) { $reason += 'contains the source image' }
            $name = (@($d.Vendor, $d.Product) | Where-Object { $_ }) -join ' '
            if (-not $name) { $name = "Disk $($d.Number)" }
            $bus = $busNames[$d.BusType]
            if (-not $bus) { $bus = "Bus type $($d.BusType)" }
            $style = $styles[$d.PartitionStyle]
            if (-not $style) { $style = 'Unknown' }
            [pscustomobject]@{
                Number            = [int]$d.Number
                Name              = $name
                SizeBytes         = [long]$d.SizeBytes
                Size              = Format-IsoBytes $d.SizeBytes
                BusType           = $bus
                Removable         = [bool]$d.Removable
                LogicalSectorSize = [int]$d.LogicalSectorSize
                PartitionStyle    = $style
                Offline           = [bool]$d.IsOffline
                Eligible          = ($reason.Count -eq 0)
                Reason            = ($reason -join ', ')
            }
        }
    }

    function Invoke-IsoImageWrite {
        param(
            [Parameter(Mandatory = $true)][string]$IsoPath,
            [int]$DiskNumber = -1,
            [string]$OutFile,
            [bool]$Verify = $true,
            [bool]$ZeroRemainder = $false,
            [int]$PadSectors = 0,
            [bool]$BootPatch = $true,
            [hashtable]$State
        )

        if (-not $State) { $State = [hashtable]::Synchronized(@{}) }
        if (-not $State.ContainsKey('Cancel')) { $State.Cancel = $false }

        $CdSector = 2048      # user-data bytes per Mode 1 / DVD / BD sector
        $MinTrack = 300       # minimum track length: 4 seconds x 75 sectors
        $Chunk = 1MB          # multiple of every common logical sector size
        $total = [Diagnostics.Stopwatch]::StartNew()

        $IsoPath = (Resolve-Path -LiteralPath $IsoPath).ProviderPath
        $iso = Get-IsoInfo -Path $IsoPath
        $fsNames = @()
        if ($iso.IsIso9660) { $fsNames += 'ISO 9660' }
        if ($iso.IsUdf) { $fsNames += 'UDF' }
        if (-not $fsNames) { $fsNames += 'unrecognized' }
        Write-IsoLog $State "Image: $($iso.Path)"
        Write-IsoLog $State "  Label '$($iso.VolumeLabel)', $($iso.Size) ($($iso.SizeBytes) bytes), file system: $($fsNames -join ' + '), El Torito: $($iso.IsElTorito), MBR: $($iso.HasMbr)"
        foreach ($w in $iso.Warnings) { Write-IsoLog $State $w 'WARN' }

        Write-IsoLog $State "  BIOS boot: $($iso.BiosBoot)"
        if ($OutFile) {
            $OutFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
            if ($OutFile -eq $IsoPath) { throw 'The output file cannot be the source image.' }
            $target = [pscustomobject]@{ Name = $OutFile; LogicalSectorSize = 512 }
            $lss = 512
            Write-IsoLog $State "Target: image file $OutFile (512-byte sectors)"
        } else {
            if ($DiskNumber -lt 0) { throw 'Specify a disk number or an output file.' }
            $target = Get-IsoTargetDisk -ExcludePath $IsoPath | Where-Object Number -eq $DiskNumber
            if (-not $target) { throw "Disk $DiskNumber was not found." }
            if (-not $target.Eligible) { throw "Disk $DiskNumber cannot be used: $($target.Reason)." }
            $lss = $target.LogicalSectorSize
            Write-IsoLog $State "Target: Disk $DiskNumber - $($target.Name), $($target.Size), $($target.BusType), $lss-byte logical sectors"
        }

        $patch = $null
        if ($iso.BootPatch -and $BootPatch) {
            $patch = $iso.BootPatch
            if ($lss -ne 512) {
                throw "The $($patch.Kind) BIOS boot fix needs a drive with 512-byte logical sectors; this drive uses $lss. Use -NoBootPatch to write the unmodified image."
            }
            Write-IsoLog $State "BIOS boot fix ($($patch.Kind)): replacing sector 0 with a PC boot record. $($patch.Description)"
        } elseif ($iso.BootPatch) {
            Write-IsoLog $State 'A BIOS boot fix is available for this image but was turned off; writing it unmodified.' 'WARN'
        }

        # Track layout exactly as a burner lays out a single-session data disc.
        $isoSectors = [long][Math]::Ceiling($iso.SizeBytes / $CdSector)
        $trackSectors = [Math]::Max($isoSectors, [long]$MinTrack) + [long]$PadSectors
        $trackBytes = $trackSectors * $CdSector
        $writeBytes = [long][Math]::Ceiling($trackBytes / $lss) * $lss
        Write-IsoLog $State ("Track 1 (data): LBA 0-{0}, {1} x {2} bytes = {3} bytes (image {4} sectors, pad {5})" -f `
                ($trackSectors - 1), $trackSectors, $CdSector, $trackBytes, $isoSectors, ($trackSectors - $isoSectors))
        if ($writeBytes -ne $trackBytes) {
            Write-IsoLog $State "Aligned to device sector size: $writeBytes bytes" 'WARN'
        }

        $volumes = New-Object System.Collections.Generic.List[object]
        $dev = $null; $src = $null; $sha = $null; $isoSha = $null
        $ok = $false
        try {
            if ($OutFile) {
                [System.IO.File]::Open($OutFile, 'Create', 'ReadWrite', 'None').Dispose()
                $dev = [IsoRawDevice]::new($OutFile, $true)
                $diskBytes = $writeBytes
            } else {
                # A drive that has idled - common with USB adapters - can take a long time to answer
                # its first command. Say so up front, and let the GUI show how long it has waited.
                Write-IsoLog $State 'Preparing drive (a USB drive waking from power saving can take up to a minute to respond)...'
                Set-IsoWaiting $State $true
                $wait = [Diagnostics.Stopwatch]::StartNew()
                $dev = [IsoRawDevice]::new("\\.\PhysicalDrive$DiskNumber", $true)
                $diskBytes = $dev.GetLength()
                $diskBytes -= $diskBytes % $lss
                if ($writeBytes -gt $diskBytes) {
                    throw "Image does not fit: track needs $(Format-IsoBytes $writeBytes) but the drive holds $(Format-IsoBytes $diskBytes)."
                }
                # Reading sector 0 wakes the drive before its volumes are locked and the write starts.
                $wake = New-Object byte[] $lss
                $dev.Seek(0)
                [void]$dev.Read($wake, $lss)

                # Take every mounted volume on the drive away from Windows so raw writes are allowed.
                foreach ($vp in [IsoDiskProbe]::GetVolumesOnDisk($DiskNumber)) {
                    $v = [IsoRawDevice]::new($vp, $true)
                    $volumes.Add($v)
                    if (-not $v.TryLock(20, 250)) {
                        throw "Could not lock volume $vp. Close programs and Explorer windows using the drive, then retry."
                    }
                    $v.Dismount()
                    Write-IsoLog $State "Locked and dismounted $vp"
                }
                Set-IsoWaiting $State $false
                if ($wait.Elapsed.TotalSeconds -ge 2) {
                    Write-IsoLog $State ('Drive responded after {0:N0} s.' -f $wait.Elapsed.TotalSeconds) 'WARN'
                }
            }

            # --- Write the track -------------------------------------------------
            $buf = New-Object byte[] $Chunk
            $src = [System.IO.FileStream]::new($IsoPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::Read, $Chunk, [System.IO.FileOptions]::SequentialScan)
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $isoSha = [System.Security.Cryptography.SHA256]::Create()

            Write-IsoLog $State 'Writing track...'
            $dev.Seek(0)
            $done = [long]0
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $tick = [Diagnostics.Stopwatch]::StartNew()
            while ($done -lt $writeBytes) {
                if ($State.Cancel) { throw [OperationCanceledException]::new('Cancelled by user.') }
                $want = [int][Math]::Min([long]$Chunk, $writeBytes - $done)
                $got = Read-IsoFull $src $buf $want
                if ($got -gt 0) { [void]$isoSha.TransformBlock($buf, 0, $got, $null, 0) }
                if ($got -lt $want) { [Array]::Clear($buf, $got, $want - $got) }
                if ($done -eq 0 -and $patch) { [Array]::Copy($patch.Mbr, 0, $buf, 0, 512) }
                $dev.Write($buf, $want)
                [void]$sha.TransformBlock($buf, 0, $want, $null, 0)
                $done += $want
                if ($tick.ElapsedMilliseconds -ge 250 -or $done -eq $writeBytes) {
                    Set-IsoProgress $State 'Writing track' $done $writeBytes $clock
                    $tick.Restart()
                }
            }
            [void]$sha.TransformFinalBlock([byte[]]::new(0), 0, 0)
            [void]$isoSha.TransformFinalBlock([byte[]]::new(0), 0, 0)
            $trackHash = ConvertTo-IsoHex $sha.Hash
            $imageHash = ConvertTo-IsoHex $isoSha.Hash
            Write-IsoLog $State 'Synchronizing cache...'
            $dev.Flush()
            Write-IsoLog $State "Track written in $($clock.Elapsed.ToString('hh\:mm\:ss')). Image SHA-256: $imageHash" 'OK'

            # --- Clear what lies past the track (no stale partition tables) ------
            if ($writeBytes -lt $diskBytes) {
                if ($ZeroRemainder) {
                    $zStart = $writeBytes
                    $phase = 'Erasing remainder of drive'
                } else {
                    $zStart = [Math]::Max($writeBytes, $diskBytes - 1MB)
                    $phase = 'Clearing end-of-drive metadata'
                }
                Write-IsoLog $State "$phase ($(Format-IsoBytes ($diskBytes - $zStart)))..."
                $zero = New-Object byte[] $Chunk
                $dev.Seek($zStart)
                $pos = $zStart
                $clock.Restart(); $tick.Restart()
                while ($pos -lt $diskBytes) {
                    if ($State.Cancel) { throw [OperationCanceledException]::new('Cancelled by user.') }
                    $want = [int][Math]::Min([long]$Chunk, $diskBytes - $pos)
                    $dev.Write($zero, $want)
                    $pos += $want
                    if ($tick.ElapsedMilliseconds -ge 250 -or $pos -eq $diskBytes) {
                        Set-IsoProgress $State $phase ($pos - $zStart) ($diskBytes - $zStart) $clock
                        $tick.Restart()
                    }
                }
                $dev.Flush()
            }
            $dev.UpdateProperties()

            # --- Verify -----------------------------------------------------------
            $verified = $false
            if ($Verify) {
                Write-IsoLog $State 'Verifying track...'
                $vsha = [System.Security.Cryptography.SHA256]::Create()
                try {
                    $dev.Seek(0)
                    $done = [long]0
                    $clock.Restart(); $tick.Restart()
                    while ($done -lt $writeBytes) {
                        if ($State.Cancel) { throw [OperationCanceledException]::new('Cancelled by user.') }
                        $want = [int][Math]::Min([long]$Chunk, $writeBytes - $done)
                        $n = $dev.Read($buf, $want)
                        if ($n -ne $want) { throw "Short read during verify at byte $done ($n of $want)." }
                        [void]$vsha.TransformBlock($buf, 0, $want, $null, 0)
                        $done += $want
                        if ($tick.ElapsedMilliseconds -ge 250 -or $done -eq $writeBytes) {
                            Set-IsoProgress $State 'Verifying' $done $writeBytes $clock
                            $tick.Restart()
                        }
                    }
                    [void]$vsha.TransformFinalBlock([byte[]]::new(0), 0, 0)
                    $readHash = ConvertTo-IsoHex $vsha.Hash
                } finally {
                    $vsha.Dispose()
                }
                if ($readHash -ne $trackHash) {
                    throw "VERIFY FAILED: track written $trackHash, read back $readHash."
                }
                $verified = $true
                Write-IsoLog $State "Verify OK. Track SHA-256: $trackHash" 'OK'
            }

            $ok = $true
            Write-IsoLog $State "Burn complete in $($total.Elapsed.ToString('hh\:mm\:ss'))." 'OK'
            $State.Phase = 'Complete'
            $State.Percent = 100
            [pscustomobject]@{
                IsoPath        = $IsoPath
                DiskNumber     = $(if ($OutFile) { $null } else { $DiskNumber })
                DiskName       = $target.Name
                BiosBootFix    = $(if ($patch) { $patch.Kind } else { 'none' })
                ImageBytes     = $iso.SizeBytes
                TrackSectors   = $trackSectors
                BytesWritten   = $writeBytes
                ImageSha256    = $imageHash
                TrackSha256    = $trackHash
                Verified       = $verified
                RemainderZeroed = [bool]$ZeroRemainder
                Elapsed        = $total.Elapsed
            }
        } finally {
            if ($src) { $src.Dispose() }
            if ($sha) { $sha.Dispose() }
            if ($isoSha) { $isoSha.Dispose() }
            if ($dev) { $dev.Dispose() }
            for ($i = $volumes.Count - 1; $i -ge 0; $i--) { $volumes[$i].Dispose() }
            if ($State.Console) { Write-Progress -Activity 'ISO2HD' -Completed }
            if ($State.WaitingSince) { Set-IsoWaiting $State $false }
            if (-not $ok) { Write-IsoLog $State "The target may now hold an incomplete image." 'WARN' }
            if (-not $OutFile) { [IsoDiskProbe]::UpdateDiskProperties($DiskNumber) }
        }
    }
}

. $EngineBlock

function Test-IsAdmin {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------
$WorkerScript = @'
try {
    $State.Result = Invoke-IsoImageWrite -IsoPath $IsoPath -DiskNumber $DiskNumber -Verify $Verify `
        -ZeroRemainder $ZeroRemainder -PadSectors $PadSectors -BootPatch $BootPatch -State $State
} catch {
    $State.Error = $_.Exception.Message
    Write-IsoLog $State $_.Exception.Message 'ERROR'
} finally {
    $State.Done = $true
}
'@

function Show-IsoBurnerGui {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    if (-not ('IsoDeviceWatcher' -as [type])) {
        $refs = @([System.Windows.Forms.Form].Assembly.Location, [System.Windows.Forms.Message].Assembly.Location) | Select-Object -Unique
        Add-Type -ReferencedAssemblies $refs -TypeDefinition @'
using System;
using System.Windows.Forms;

// Raises DevicesChanged when Windows broadcasts that devices were added or removed.
public sealed class IsoDeviceWatcher : NativeWindow, IDisposable
{
    const int WM_DEVICECHANGE = 0x0219;
    const int DBT_DEVNODES_CHANGED = 0x0007;
    const int DBT_DEVICEARRIVAL = 0x8000;
    const int DBT_DEVICEREMOVECOMPLETE = 0x8004;

    public event EventHandler DevicesChanged;

    public IsoDeviceWatcher(IntPtr windowHandle)
    {
        AssignHandle(windowHandle);
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_DEVICECHANGE)
        {
            long code = m.WParam.ToInt64();
            if (code == DBT_DEVNODES_CHANGED || code == DBT_DEVICEARRIVAL || code == DBT_DEVICEREMOVECOMPLETE)
            {
                EventHandler handler = DevicesChanged;
                if (handler != null) handler(this, EventArgs.Empty);
            }
        }
        base.WndProc(ref m);
    }

    public void Dispose()
    {
        ReleaseHandle();
    }
}
'@
    }

    $ui = @{
        Disks = @(); State = $null; Burning = $false; Watcher = $null
        IsoPath = ''; IsoInfo = $null; IsoJob = $null; IsoJobPath = $null
        DiskJob = $null; ScanPath = $null; RescanPending = $false
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'ISO2HD - Burn ISO to Hard Drive'
    $form.ClientSize = New-Object System.Drawing.Size(640, 626)
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $bold = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    function New-Ctl([string]$Type, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Text) {
        $c = New-Object "System.Windows.Forms.$Type"
        $c.Location = New-Object System.Drawing.Point($X, $Y)
        $c.Size = New-Object System.Drawing.Size($W, $H)
        if ($Text) { $c.Text = $Text }
        $form.Controls.Add($c)
        $c
    }

    $h1 = New-Ctl Label 12 12 616 20 '1. Source image'; $h1.Font = $bold
    $txtIso = New-Ctl TextBox 12 34 520 24
    $txtIso.AllowDrop = $true
    $btnBrowse = New-Ctl Button 540 32 88 27 'Browse...'
    $lblIso = New-Ctl Label 12 64 616 52 'No image selected.'
    $lblIso.ForeColor = [System.Drawing.Color]::DimGray

    $h2 = New-Ctl Label 12 120 616 20 '2. Target drive'; $h2.Font = $bold
    $cboDisk = New-Ctl ComboBox 12 142 520 24
    $cboDisk.DropDownStyle = 'DropDownList'
    $btnRefresh = New-Ctl Button 540 140 88 27 'Refresh'
    $lblDisk = New-Ctl Label 12 172 616 36 ''
    $lblDisk.ForeColor = [System.Drawing.Color]::DimGray

    $h3 = New-Ctl Label 12 212 616 20 '3. Options'; $h3.Font = $bold
    $chkVerify = New-Ctl CheckBox 12 234 616 22 'Verify after burn (read the track back and compare SHA-256)'
    $chkVerify.Checked = $true
    $chkZero = New-Ctl CheckBox 12 258 616 22 'Erase the entire remainder of the drive, like blank media (slow)'
    $chkBoot = New-Ctl CheckBox 12 282 616 22 'Make BIOS-bootable when ISO2HD has a boot fix for the disc (replaces sector 0 only)'
    $chkBoot.Checked = $true
    [void](New-Ctl Label 12 312 350 20 'Extra zero pad sectors after the track (2048 bytes each):')
    $numPad = New-Ctl NumericUpDown 366 309 80 24
    $numPad.Maximum = 100000

    $progress = New-Ctl ProgressBar 12 346 616 22
    $lblStatus = New-Ctl Label 12 372 616 20 'Ready.'
    $txtLog = New-Ctl TextBox 12 396 616 176
    $txtLog.Multiline = $true
    $txtLog.ReadOnly = $true
    $txtLog.ScrollBars = 'Vertical'
    $txtLog.Font = New-Object System.Drawing.Font('Consolas', 8.5)

    $btnBurn = New-Ctl Button 348 584 90 30 'Burn'
    $btnBurn.Font = $bold
    $btnCancel = New-Ctl Button 443 584 90 30 'Cancel'
    $btnCancel.Enabled = $false
    $btnClose = New-Ctl Button 538 584 90 30 'Close'

    # Drive scans and image inspection run in background runspaces, never on the window's thread,
    # so a drive that is slow to answer cannot freeze the window.
    $ui.Pool = [runspacefactory]::CreateRunspacePool(1, 3)
    $ui.Pool.Open()
    $ui.EngineText = $EngineBlock.ToString()

    $startJob = {
        # One script: the engine definitions followed by the command, which reads its inputs from $args.
        # (Chaining them as separate statements with AddStatement() left pooled jobs running forever.)
        param([string]$Command, [object[]]$Arguments)
        $ps = [powershell]::Create()
        $ps.RunspacePool = $ui.Pool
        [void]$ps.AddScript($ui.EngineText + "`n" + $Command)
        foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
        @{ PS = $ps; Async = $ps.BeginInvoke(); Clock = [Diagnostics.Stopwatch]::StartNew() }
    }

    $innerMessage = {
        param($Exception)
        while ($Exception.InnerException) { $Exception = $Exception.InnerException }
        $Exception.Message
    }

    $updateControls = {
        $idle = -not $ui.Burning
        $scanning = [bool]$ui.DiskJob
        foreach ($c in @($txtIso, $btnBrowse, $chkVerify, $chkZero, $chkBoot, $numPad, $btnClose)) { $c.Enabled = $idle }
        $cboDisk.Enabled = $idle -and -not $scanning
        $btnRefresh.Enabled = $idle -and -not $scanning
        $btnBurn.Enabled = $idle -and -not $scanning
        $btnCancel.Enabled = [bool]$ui.Burning
    }

    $showDiskInfo = {
        if ($cboDisk.SelectedIndex -lt 0) { return }
        $d = $ui.Disks[$cboDisk.SelectedIndex]
        $fit = ''
        if ($ui.IsoInfo) {
            $need = [Math]::Max([long][Math]::Ceiling($ui.IsoInfo.SizeBytes / 2048), 300) * 2048
            $fit = if ($need -le $d.SizeBytes) { '   Image fits: yes' } else { '   Image fits: NO - drive too small' }
        }
        $lblDisk.Text = "Capacity: $($d.SizeBytes) bytes   Logical sector: $($d.LogicalSectorSize) bytes   Current layout: $($d.PartitionStyle)$fit"
    }

    $showIsoInfo = {
        $i = $ui.IsoInfo
        $fsNames = @()
        if ($i.IsIso9660) { $fsNames += 'ISO 9660' }
        if ($i.IsUdf) { $fsNames += 'UDF' }
        if (-not $fsNames) { $fsNames += 'unrecognized' }
        $text = "Label: $($i.VolumeLabel)   Size: $($i.Size) ($($i.Sectors) sectors)`r`nFile system: $($fsNames -join ' + ')   BIOS boot: $($i.BiosBoot)"
        if ($i.Warnings.Count -gt 0) { $text += "`r`nNote: $($i.Warnings[0])" }
        $lblIso.Text = $text
    }

    $startIsoInfo = {
        if ($ui.IsoJob) { return }      # when it finishes, the job handler starts again if the path changed
        if (-not $ui.IsoPath) { $lblIso.Text = 'No image selected.'; return }
        $ui.IsoJobPath = $ui.IsoPath
        $lblIso.Text = 'Reading image...'
        $ui.IsoJob = & $startJob '$path = $args[0]; if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "File not found: $path" }; Get-IsoInfo -Path $path' @($ui.IsoPath)
        $jobTimer.Start()
    }

    $startDiskScan = {
        if ($ui.DiskJob) { $ui.RescanPending = $true; return }
        $ui.RescanPending = $false
        $ui.ScanPath = $ui.IsoPath
        $lblDisk.Text = 'Scanning drives...'
        $ui.DiskJob = & $startJob 'Get-IsoTargetDisk -ExcludePath $args[0]' @($ui.IsoPath)
        & $updateControls
        $jobTimer.Start()
    }

    $onIsoPathChanged = {
        $p = $txtIso.Text.Trim('"', ' ')
        if ($p -eq $ui.IsoPath) { return }
        $ui.IsoPath = $p
        $ui.IsoInfo = $null
        & $startIsoInfo
        & $startDiskScan                # the drive holding the image is left out of the target list
    }

    $jobTimer = New-Object System.Windows.Forms.Timer
    $jobTimer.Interval = 200
    $jobTimer.Add_Tick({
            $job = $ui.IsoJob
            if ($job -and $job.Async.IsCompleted) {
                $ui.IsoJob = $null
                $info = $null
                $failure = $null
                try {
                    $info = $job.PS.EndInvoke($job.Async) | Select-Object -Last 1
                } catch {
                    $failure = & $innerMessage $_.Exception
                } finally {
                    $job.PS.Dispose()
                }
                if ($ui.IsoJobPath -ne $ui.IsoPath) {
                    & $startIsoInfo
                } elseif ($failure -or -not $info) {
                    if (-not $failure) { $failure = 'no information returned' }
                    $lblIso.Text = "Cannot read image: $failure"
                } else {
                    $ui.IsoInfo = $info
                    & $showIsoInfo
                    & $showDiskInfo
                }
            }

            $job = $ui.DiskJob
            if ($job -and $job.Async.IsCompleted) {
                $ui.DiskJob = $null
                $list = @()
                $failure = $null
                try {
                    $list = @($job.PS.EndInvoke($job.Async))
                } catch {
                    $failure = & $innerMessage $_.Exception
                } finally {
                    $job.PS.Dispose()
                }
                $prev = -1
                if ($cboDisk.SelectedIndex -ge 0) { $prev = $ui.Disks[$cboDisk.SelectedIndex].Number }
                $cboDisk.Items.Clear()
                $lblDisk.Text = ''
                $ui.Disks = @($list | Where-Object { $_.Eligible })
                foreach ($d in $ui.Disks) {
                    [void]$cboDisk.Items.Add(('Disk {0}: {1}   [{2}, {3}]' -f $d.Number, $d.Name, $d.Size, $d.BusType))
                }
                for ($i = 0; $i -lt $ui.Disks.Count; $i++) {
                    if ($ui.Disks[$i].Number -eq $prev) { $cboDisk.SelectedIndex = $i }
                }
                if ($failure) {
                    $lblDisk.Text = "Drive scan failed: $failure"
                } elseif ($ui.Disks.Count -eq 0) {
                    $lblDisk.Text = 'No eligible drives found. Boot/system drives and the drive holding the image are never listed.'
                }
                if ($ui.RescanPending -or $ui.ScanPath -ne $ui.IsoPath) { & $startDiskScan }
                & $updateControls
            } elseif ($job -and $job.Clock.Elapsed.TotalSeconds -ge 5) {
                $lblDisk.Text = ("Still scanning drives ({0:N0} s). Windows is waiting for a drive to respond - often a USB adapter waking from power saving.`r`nWait, or unplug and replug that drive." -f $job.Clock.Elapsed.TotalSeconds)
            }

            if (-not $ui.IsoJob -and -not $ui.DiskJob) { $jobTimer.Stop() }
        })

    # Device arrivals and removals come in bursts; rescan once things settle.
    $devTimer = New-Object System.Windows.Forms.Timer
    $devTimer.Interval = 1500
    $devTimer.Add_Tick({
            $devTimer.Stop()
            if (-not $ui.Burning) { & $startDiskScan }
        })

    $btnBrowse.Add_Click({
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Filter = 'Disc images (*.iso;*.img)|*.iso;*.img|All files (*.*)|*.*'
            $dlg.Title = 'Select disc image'
            if ($dlg.ShowDialog($form) -eq 'OK') {
                $txtIso.Text = $dlg.FileName
                & $onIsoPathChanged
            }
        })
    $txtIso.Add_Leave({ & $onIsoPathChanged })
    $txtIso.Add_DragEnter({
            if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy' }
        })
    $txtIso.Add_DragDrop({
            $files = $_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
            if ($files) { $txtIso.Text = $files[0]; & $onIsoPathChanged }
        })
    $btnRefresh.Add_Click({ & $startDiskScan })
    $cboDisk.Add_SelectedIndexChanged({ & $showDiskInfo })
    $btnClose.Add_Click({ $form.Close() })
    $btnCancel.Add_Click({
            if ($ui.State) {
                $ui.State.Cancel = $true
                $btnCancel.Enabled = $false
                $lblStatus.Text = 'Cancelling...'
            }
        })

    $btnBurn.Add_Click({
            $iso = $txtIso.Text.Trim('"', ' ')
            if (-not ($iso -and (Test-Path -LiteralPath $iso -PathType Leaf))) {
                [void][System.Windows.Forms.MessageBox]::Show($form, 'Select an image file first.', 'ISO2HD', 'OK', 'Information')
                return
            }
            if ($cboDisk.SelectedIndex -lt 0) {
                [void][System.Windows.Forms.MessageBox]::Show($form, 'Select a target drive first.', 'ISO2HD', 'OK', 'Information')
                return
            }
            $d = $ui.Disks[$cboDisk.SelectedIndex]
            $msg = "ALL DATA on this drive will be permanently destroyed:`r`n`r`n" +
            "    Disk $($d.Number): $($d.Name)`r`n    $($d.Size), $($d.BusType)`r`n`r`nBurn '$([IO.Path]::GetFileName($iso))' to it?"
            $answer = [System.Windows.Forms.MessageBox]::Show($form, $msg, 'Confirm burn', 'YesNo', 'Warning', 'Button2')
            if ($answer -ne 'Yes') { return }

            $txtLog.Clear()
            $progress.Value = 0
            $state = [hashtable]::Synchronized(@{
                    Console = $false; Cancel = $false; Done = $false; Error = $null; Result = $null
                    Percent = 0; Phase = 'Starting'; Status = ''
                    Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
                })
            $ui.State = $state

            $rs = [runspacefactory]::CreateRunspace()
            $rs.Open()
            $vars = @{
                State = $state; IsoPath = $iso; DiskNumber = [int]$d.Number; Verify = [bool]$chkVerify.Checked
                ZeroRemainder = [bool]$chkZero.Checked; PadSectors = [int]$numPad.Value; BootPatch = [bool]$chkBoot.Checked
            }
            foreach ($kv in $vars.GetEnumerator()) { $rs.SessionStateProxy.SetVariable($kv.Key, $kv.Value) }
            $ps = [powershell]::Create()
            $ps.Runspace = $rs
            [void]$ps.AddScript($EngineBlock.ToString() + "`n" + $WorkerScript)
            $ui.PS = $ps
            $ui.RS = $rs
            $ui.Async = $ps.BeginInvoke()
            $ui.Burning = $true
            & $updateControls
            $timer.Start()
        })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200
    $timer.Add_Tick({
            $s = $ui.State
            if (-not $s) { return }
            $line = $null
            while ($s.Log.TryDequeue([ref]$line)) { $txtLog.AppendText($line + "`r`n") }
            $progress.Value = [Math]::Max(0, [Math]::Min(100, [int]$s.Percent))
            if (-not $s.Cancel) {
                if ($s.WaitingSince) {
                    $waited = [int]([DateTime]::UtcNow - $s.WaitingSince).TotalSeconds
                    $lblStatus.Text = if ($waited -ge 3) {
                        "Waiting for the drive to respond ($waited s). If this passes a minute, unplug and replug the drive and start again."
                    } else { 'Preparing drive...' }
                } else {
                    $lblStatus.Text = "$($s.Phase)   $($s.Status)"
                }
            }

            if ($s.Done -or $ui.Async.IsCompleted) {
                $timer.Stop()
                try { [void]$ui.PS.EndInvoke($ui.Async) } catch { if (-not $s.Error) { $s.Error = $_.Exception.Message } }
                if (-not $s.Error -and -not $s.Result) {
                    $s.Error = 'The burn stopped unexpectedly.'
                    if ($ui.PS.Streams.Error.Count -gt 0) { $s.Error = $ui.PS.Streams.Error[0].ToString() }
                }
                while ($s.Log.TryDequeue([ref]$line)) { $txtLog.AppendText($line + "`r`n") }
                $ui.PS.Dispose()
                $ui.RS.Dispose()
                $ui.State = $null
                $ui.Burning = $false
                & $updateControls

                if ($s.Error) {
                    $lblStatus.Text = "Failed: $($s.Error)"
                    [void][System.Windows.Forms.MessageBox]::Show($form, $s.Error, 'Burn failed', 'OK', 'Error')
                } else {
                    $r = $s.Result
                    $progress.Value = 100
                    $lblStatus.Text = 'Burn complete.'
                    $v = if ($r.Verified) { 'Verified OK' } else { 'Not verified' }
                    [void][System.Windows.Forms.MessageBox]::Show($form,
                        "Burn complete ($v).`r`n`r`nTrack: $($r.TrackSectors) sectors, $($r.BytesWritten) bytes`r`nImage SHA-256:`r`n$($r.ImageSha256)",
                        'ISO2HD', 'OK', 'Information')
                }
                & $startDiskScan
            }
        })

    $form.Add_FormClosing({
            if ($ui.State) {
                [void][System.Windows.Forms.MessageBox]::Show($form, 'A burn is in progress. Cancel it and wait for it to stop before closing.', 'ISO2HD', 'OK', 'Warning')
                $_.Cancel = $true
            }
        })
    $form.Add_Shown({
            # Rescan automatically when drives are plugged in or removed.
            $ui.Watcher = [IsoDeviceWatcher]::new($form.Handle)
            $ui.Watcher.add_DevicesChanged({ $devTimer.Stop(); $devTimer.Start() })
            & $startDiskScan
        })

    [void]$form.ShowDialog()
    $timer.Dispose()
    $jobTimer.Dispose()
    $devTimer.Dispose()
    if ($ui.Watcher) { $ui.Watcher.Dispose() }
    if ($ui.DiskJob -or $ui.IsoJob) {
        # A query still waiting on an unresponsive drive cannot be interrupted. Leave it behind and
        # let the process exit rather than hang waiting for it.
        $script:IsoGuiAbandonedWork = $true
    } else {
        $ui.Pool.Dispose()
    }
    $form.Dispose()
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
function Write-IsoJson {
    # -Json output: the query's result, or {"Error": "..."} and exit code 1.
    param([scriptblock]$Query)
    try {
        $value = & $Query
    } catch {
        ConvertTo-Json -InputObject @{ Error = $_.Exception.Message } -Compress
        exit 1
    }
    ConvertTo-Json -InputObject $value -Compress -Depth 4
}

function Start-IsoCancelWatch {
    # Sets $State.Cancel when the named event is set. The engine checks it between 1 MiB blocks.
    param([string]$Name, [hashtable]$State)
    $cancelEvent = [System.Threading.EventWaitHandle]::OpenExisting($Name)
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
            param($CancelEvent, $State)
            while (-not $State.StopWatch) {
                if ($CancelEvent.WaitOne(250)) { $State.Cancel = $true; break }
            }
        }).AddArgument($cancelEvent).AddArgument($State)
    @{ PS = $ps; Async = $ps.BeginInvoke(); Event = $cancelEvent }
}

switch ($PSCmdlet.ParameterSetName) {
    'List' {
        if ($Json) {
            Write-IsoJson { , @(Get-IsoTargetDisk -ExcludePath $IsoPath) }
            return
        }
        Get-IsoTargetDisk -ExcludePath $IsoPath |
            Format-Table Number, Name, Size, BusType, LogicalSectorSize, PartitionStyle, Eligible, Reason -AutoSize
    }
    'Inspect' {
        if ($Json) {
            Write-IsoJson {
                if (-not (Test-Path -LiteralPath $Inspect -PathType Leaf)) { throw "File not found: $Inspect" }
                $info = Get-IsoInfo -Path $Inspect
                $info | Select-Object * -ExcludeProperty BootPatch
            }
            return
        }
        $info = Get-IsoInfo -Path $Inspect
        $info | Select-Object * -ExcludeProperty BootPatch | Format-List
        if ($info.BootPatch) { "BIOS boot fix ($($info.BootPatch.Kind)): $($info.BootPatch.Description)" }
    }
    'Export' {
        $state = [hashtable]::Synchronized(@{ Console = $true; Cancel = $false })
        Invoke-IsoImageWrite -IsoPath $IsoPath -OutFile $OutFile -Verify (-not $NoVerify) -PadSectors $PadSectors `
            -BootPatch (-not $NoBootPatch) -State $state | Format-List
    }
    'Cli' {
        if ($ReportStatus) {
            # Run by the ISO2HD app, which has already asked for confirmation.
            $state = [hashtable]::Synchronized(@{ Console = $false; Report = $true; Cancel = $false; StopWatch = $false })
            $watch = $null
            try {
                if (-not (Test-IsAdmin)) { throw 'Writing to a drive requires Administrator rights.' }
                if ($CancelEvent) { $watch = Start-IsoCancelWatch -Name $CancelEvent -State $state }
                $r = Invoke-IsoImageWrite -IsoPath $IsoPath -DiskNumber $DiskNumber -Verify (-not $NoVerify) `
                    -ZeroRemainder $ZeroRemainder.IsPresent -PadSectors $PadSectors -BootPatch (-not $NoBootPatch) -State $state
                $summary = [pscustomobject]@{
                    DiskName = $r.DiskName; BiosBootFix = $r.BiosBootFix; TrackSectors = $r.TrackSectors
                    BytesWritten = $r.BytesWritten; ImageSha256 = $r.ImageSha256; TrackSha256 = $r.TrackSha256
                    Verified = $r.Verified; Elapsed = $r.Elapsed.ToString('hh\:mm\:ss')
                }
                Write-Host "##RESULT|$(ConvertTo-Json -InputObject $summary -Compress)"
            } catch {
                if ($state.Cancel) { exit 2 }
                Write-IsoLog $state $_.Exception.Message 'ERROR'
                exit 1
            } finally {
                if ($watch) {
                    $state.StopWatch = $true
                    [void]$watch.PS.EndInvoke($watch.Async)
                    $watch.PS.Dispose()
                    $watch.Event.Dispose()
                }
            }
            exit 0
        }
        if (-not (Test-IsAdmin)) { throw 'Writing to a drive requires an elevated (Run as Administrator) PowerShell.' }
        $target = Get-IsoTargetDisk -ExcludePath $IsoPath | Where-Object Number -eq $DiskNumber
        if (-not $target) { throw "Disk $DiskNumber was not found." }
        if (-not $target.Eligible) { throw "Disk $DiskNumber cannot be used: $($target.Reason)." }
        if (-not $Force) {
            Write-Host ''
            Write-Host "ALL DATA on Disk $($target.Number) will be permanently destroyed:" -ForegroundColor Red
            Write-Host "    $($target.Name), $($target.Size), $($target.BusType)" -ForegroundColor Red
            Write-Host ''
            $answer = Read-Host "Type the disk number ($DiskNumber) to continue"
            if ($answer.Trim() -ne "$DiskNumber") { Write-Host 'Aborted.'; return }
        }
        $state = [hashtable]::Synchronized(@{ Console = $true; Cancel = $false })
        Invoke-IsoImageWrite -IsoPath $IsoPath -DiskNumber $DiskNumber -Verify (-not $NoVerify) `
            -ZeroRemainder $ZeroRemainder.IsPresent -PadSectors $PadSectors -BootPatch (-not $NoBootPatch) -State $state | Format-List
    }
    'Gui' {
        if (-not (Test-IsAdmin)) {
            $exe = (Get-Process -Id $PID).Path
            try {
                Start-Process -FilePath $exe -Verb RunAs -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Minimized', '-File', "`"$PSCommandPath`"")
            } catch {
                Write-Warning 'ISO2HD needs Administrator rights to write to drives.'
            }
            return
        }
        Show-IsoBurnerGui
        if ($script:IsoGuiAbandonedWork) { [Environment]::Exit(0) }
    }
}
