// drvinstall.cs — force-install a specific INF for a hardware id, from the console.
//
// Wraps SetupAPI's UpdateDriverForPlugAndPlayDevices(), i.e. exactly what
// Device Manager's "Update Driver Software -> Have Disk -> (include subfolders)"
// does, but non-interactively and with INSTALLFLAG_FORCE so it replaces the
// driver already bound to the node.
//
// Build inside the guest (64-bit, must match the kernel bitness for the PnP call
// to be honoured the same way Device Manager would do it):
//   C:\Windows\Microsoft.NET\Framework64\v3.5\csc.exe /nologo /platform:x64 /out:C:\Users\Chris\drvinstall.exe C:\Users\Chris\drvinstall.cs
//
// Usage:
//   drvinstall.exe <HardwareId> <full\path\to\inf> [force|readonly] [ni]
//     force  = INSTALLFLAG_FORCE           (replace the current driver)
//     readonly = INSTALLFLAG_READONLY      (just report whether it WOULD install)
//     ni     = INSTALLFLAG_NONINTERACTIVE  (no UI; fails if a prompt is required)
//
// Example (the mod7700.sys 3.12.4.0 experiment on the PCTV 320cx):
//   drvinstall.exe USB\VID_2304&PID_022E C:\pctv2\PCTV320cx-mod7700.inf force

using System;
using System.Runtime.InteropServices;

class DrvInstall
{
    // UpdateDriverForPlugAndPlayDevices lives in newdev.dll (not setupapi.dll),
    // and only the W entry point is exported.
    [DllImport("newdev.dll", EntryPoint = "UpdateDriverForPlugAndPlayDevicesW",
               CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    static extern bool UpdateDriverForPlugAndPlayDevices(
        IntPtr hwndParent, string HardwareId, string FullInfPath,
        uint InstallFlags, out bool bRebootRequired);

    const uint INSTALLFLAG_FORCE          = 1;
    const uint INSTALLFLAG_READONLY       = 2;
    const uint INSTALLFLAG_NONINTERACTIVE = 4;

    static int Main(string[] argv)
    {
        if (argv.Length < 2)
        {
            Console.WriteLine("usage: drvinstall <HardwareId> <inf path> [force|readonly] [ni]");
            return 2;
        }
        string hwid = argv[0];
        string inf = argv[1];
        uint flags = 0;
        for (int i = 2; i < argv.Length; i++)
        {
            string a = argv[i].ToLower();
            if (a == "force") flags |= INSTALLFLAG_FORCE;
            else if (a == "readonly") flags |= INSTALLFLAG_READONLY;
            else if (a == "ni") flags |= INSTALLFLAG_NONINTERACTIVE;
        }
        if ((flags & (INSTALLFLAG_FORCE | INSTALLFLAG_READONLY)) == 0) flags |= INSTALLFLAG_FORCE;

        Console.WriteLine("UpdateDriverForPlugAndPlayDevices(hwid=" + hwid + ", inf=" + inf +
                          ", flags=0x" + flags.ToString("x") + ")");
        bool reboot;
        bool ok = UpdateDriverForPlugAndPlayDevices(IntPtr.Zero, hwid, inf, flags, out reboot);
        int err = Marshal.GetLastWin32Error();
        Console.WriteLine("  -> return=" + ok + "  lasterr=" + err +
                          " (0x" + err.ToString("x") + ")  rebootRequired=" + reboot);
        if (!ok)
        {
            // common codes: 0x279d ERROR_NO_MORE_ITEMS (no matching device / no install section),
            //               0xe0000228 ERROR_DRIVER_INSTALL_POLICY_FAILURE (signature policy),
            //               0x5 access denied, 0x3f1 ERROR_INSTALL_UNAUTHORISED
            Console.WriteLine("  note: 0x279d = no device matched or the INF has no section for this id");
            Console.WriteLine("        0xe0000228/0x3f1 = driver signing/install policy blocked it");
        }
        return ok ? 0 : 1;
    }
}
