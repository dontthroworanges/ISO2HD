# ISO2HD

Writes an `.iso` to a hard drive, SSD, or USB drive with the same sector layout a CD/DVD/BD burning program puts on a disc.

## What "burned like a disc" means here

A burning program treats an ISO as a run of 2048-byte user-data sectors and writes them in order as one data track starting at LBA 0. ISO2HD does the same thing:

| Burner behaviour | ISO2HD |
|---|---|
| ISO sector *n* is written to disc LBA *n* | ISO byte offset = drive byte offset, starting at byte 0 |
| A partial last sector is zero-padded | Same |
| Minimum track length is 300 sectors (4 s) | Short images are padded to 300 × 2048 bytes |
| Optional pad sectors (`cdrecord -pad`) | `-PadSectors N` / "Extra zero pad sectors" |
| Sequential write, then synchronize cache | Sequential 1 MiB writes, then `FlushFileBuffers` |
| Verify pass | Reads the track back and compares SHA-256 |
| Nothing readable after the track | Clears the last 1 MiB of the drive (removes stale GPT backup); `-ZeroRemainder` erases everything after the track |

Some parts of an optical disc have no equivalent on a hard drive and aren't in the ISO file anyway: lead-in/TOC, EDC/ECC, subchannel data, and lead-out.

## Booting on legacy BIOS PCs

A legacy (non-UEFI) BIOS boots a hard drive by running the MBR in its first sector. What ISO2HD does depends on the image. `-Inspect` shows the result on its `BiosBoot` line.

| `BiosBoot` shows | What ISO2HD does |
|---|---|
| `Hybrid MBR - boots from a hard drive as-is` | Nothing extra. Most Linux ISOs are like this. |
| `Darwin/x86 - ISO2HD adds a BIOS boot record` | Replaces **only the first 512 bytes** with a PC boot record. Everything else still matches the disc. |
| `CD-only - will not boot from a hard drive` | Writes the image unchanged and warns you. There's no boot fix for this kind of disc yet. |

### Darwin/x86 boot fix
This covers OSx86 / Darwin install discs: an Apple partition map, an HFS+ volume, and an El Torito `CDBOOT` that is a 2048-byte stub followed by Darwin `boot`. ISO2HD's MBR does what `CDBOOT`'s stub does on a CD, but counted in 512-byte sectors:

1. It reads the disc's own Darwin boot2 (the `BOOT` file). It uses INT 13h extensions when available and falls back to CHS otherwise.
2. It jumps to boot2 the same way the CD stub does.
3. It includes one active partition entry, type `0xAF` (Apple HFS), covering the HFS+ volume. boot2 and the kernel use it to find the install volume.

What to know:
- **Drive:** needs 512-byte logical sectors, which almost every USB stick and hard drive has. ISO2HD refuses 4K-native drives rather than write something that won't boot.
- **Macs:** the patch overwrites Apple's 8-byte driver descriptor header. BIOS PCs don't use it, but Macs may no longer recognise the drive's Apple partition map.
- **Opting out:** add `-NoBootPatch`, or turn off **BIOS boot fix** in the app's Preferences, to write the disc byte-for-byte.
- **Hardware:** the PC still has to be hardware the disc's kernel supports, just as when booting the DVD.

### Testing in a virtual machine first
`-OutFile` writes exactly what would go on the drive into an image file. It doesn't need Administrator rights. Boot the file as a hard disk in QEMU, VirtualBox or VMware:

```powershell
.\ISO2HD.ps1 -IsoPath D:\images\tiger.iso -OutFile D:\vm\tiger-hdd.img
& 'C:\Program Files\qemu\qemu-system-x86_64.exe' -m 1024 -cpu core2duo -drive file=D:\vm\tiger-hdd.img,format=raw,if=ide,snapshot=on -boot c
```

## Things to know

- **Booting:** see [Booting on legacy BIOS PCs](#booting-on-legacy-bios-pcs).
- **Seeing the files in Windows:** Windows mounts ISO 9660 only on optical drives. It does mount UDF on hard drives, so ISO 9660 + UDF images will show up. Pure ISO 9660 images still read fine on Linux and macOS.
- **After a write**, Windows may say the drive "needs to be formatted". Click **Cancel**. Formatting would erase the image.
- **Safety:** Boot and system disks, read-only disks, and the disk that holds the ISO are never offered as targets. You must confirm before anything is written.

## Usage

Double-click **`ISO2HD.exe`** to open the app. It asks for Administrator rights (UAC) and follows the Windows light/dark setting.

- **Disc image:** type a path or click **Browse…**. The image's label, size, file system and BIOS boot result are shown below it. Dragging a file in from Explorer doesn't work, because Windows blocks drag and drop into apps running as Administrator.
- **Target drive:** only drives that are safe to write to are listed (see **Safety** above).
- **Preferences:** verify after writing, the BIOS boot fix, erasing the rest of the drive, extra pad sectors, and whether the output section is shown when the app starts. They are saved in `ISO2HD.settings.json` next to the exe.
- **Burn** asks you to confirm, then shows progress in the window and on the taskbar button. **Cancel** stops between 1 MiB blocks, which leaves an incomplete image on the drive.
- **Hide output** shrinks the window to just the controls.

About the exe:
- **Which script it runs:** `ISO2HD.ps1` from its own folder. All the drive and image work is done by the script. If you copy the exe somewhere on its own, it runs the copy of the script built into it, extracted to `%LOCALAPPDATA%\ISO2HD`.
- **Building it:** run `.\Source\Publish.ps1`. Building needs the .NET 8 SDK or later; people using the exe don't need to install anything. Run it again after changing `ISO2HD.ps1`, to refresh the built-in copy. The app's source is in `Source\ISO2HD`, and the icon artwork (SVG and all sizes) is in `Icons`.
- **Start-up time:** the first run of a new build takes longer while it unpacks to `%TEMP%\.net\ISO2HD` and antivirus scans it.

`ISO2HD.cmd` opens the script's own, simpler window instead.

## Drive detection and slow USB adapters

ISO2HD lists drives by asking Windows' disk drivers directly. The answers come from information the drivers already hold, so listing usually takes well under a second. It doesn't use the Storage Management service behind `Get-Disk`, which probes every disk and can wait about a minute on a USB-to-SATA adapter that is slow to wake from power saving.

In the app:
- **Background scanning:** drives are scanned in the background, so the window never freezes. If a scan takes more than 5 seconds, ISO2HD says a drive isn't responding. You can wait, or unplug and replug that drive.
- **Automatic refresh:** the list updates by itself when you plug in or remove a drive. **Refresh** is still there.
- **Waking the drive:** before writing, ISO2HD reads the drive's first sector to wake it. If the drive is slow to answer, the status line shows how long it has been waiting.

If a USB adapter keeps stalling, turn off power saving for it. In Device Manager, open its USB device or hub, go to the **Power Management** tab, and untick **Allow the computer to turn off this device to save power**. Adapters that support UAS generally don't have this problem.

Command line (run in an elevated PowerShell):

```powershell
.\ISO2HD.ps1 -ListDisks
.\ISO2HD.ps1 -Inspect D:\images\linux.iso
.\ISO2HD.ps1 -IsoPath D:\images\linux.iso -DiskNumber 3
.\ISO2HD.ps1 -IsoPath D:\images\linux.iso -DiskNumber 3 -ZeroRemainder -PadSectors 15
```

```powershell
.\ISO2HD.ps1 -IsoPath D:\images\tiger.iso -OutFile D:\vm\tiger-hdd.img   # image file, no admin needed
```

Other switches:
- `-NoVerify` skips the verify pass.
- `-NoBootPatch` writes the disc unmodified, even when a BIOS boot fix is available.
- `-Force` skips the type-the-disk-number prompt.
- `-Json` (with `-ListDisks` or `-Inspect`) and `-ReportStatus` / `-CancelEvent` (when writing) are what the app uses to run the script.

Works with Windows PowerShell 5.1 and PowerShell 7+.

## Test safely with a virtual disk (elevated PowerShell)

```powershell
$vhd = "$env:TEMP\iso2hd-test.vhdx"
"create vdisk file=`"$vhd`" maximum=256 type=expandable`nattach vdisk" | Set-Content "$env:TEMP\dp.txt"
diskpart /s "$env:TEMP\dp.txt"
.\ISO2HD.ps1 -ListDisks          # note the new disk number
.\ISO2HD.ps1 -IsoPath C:\path\to\image.iso -DiskNumber <N>
"select vdisk file=`"$vhd`"`ndetach vdisk" | Set-Content "$env:TEMP\dp.txt"
diskpart /s "$env:TEMP\dp.txt"; Remove-Item $vhd
```
