// instclick.cs — run UpdateDriverForPlugAndPlayDevices from the INTERACTIVE session
// and auto-answer the Win7 "Code Integrity / Windows can't verify the publisher"
// dialog that appears for an unsigned driver package.
//
// Why: from an ssh session the process is non-interactive, so SetupAPI refuses to
// show the prompt and the driver-store import fails with
//   0xE000023F "Driver package does not contain a catalog file.
//               No error message will be displayed as client is running in
//               non-interactive mode."
// Running in the logged-on session + clicking "Install this driver software
// anyway" is what makes the install go through on Win7 x64.
//
// Build in the guest:
//   C:\Windows\Microsoft.NET\Framework64\v3.5\csc.exe /nologo /platform:x64 ^
//     /out:C:\Users\Chris\instclick.exe C:\Users\Chris\instclick.cs
// Run in the interactive session (schtasks /ru <logged-on user>, see below):
//   schtasks /create /f /tn pctvinst /tr "C:\Users\Chris\instclick.exe" /sc once /st 21:30 /ru "Chris-PC\Chris"
//   schtasks /run /tn pctvinst
//
// Writes C:\pctv2\instclick.log

using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;

class InstClick
{
    [DllImport("newdev.dll", EntryPoint = "UpdateDriverForPlugAndPlayDevicesW",
               CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    static extern bool UpdateDriverForPlugAndPlayDevices(
        IntPtr hwndParent, string HardwareId, string FullInfPath,
        uint InstallFlags, out bool bRebootRequired);

    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumWindowsProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr FindWindowW(string cls, string title);

    const uint BM_CLICK = 0x00F5;
    const uint INSTALLFLAG_FORCE = 1;

    static string LOG = @"C:\pctv2\instclick.log";
    static uint ourPid = (uint)System.Diagnostics.Process.GetCurrentProcess().Id;

    static void Log(string s)
    {
        string line = DateTime.Now.ToString("HH:mm:ss.fff") + "  " + s;
        Console.WriteLine(line);
        try { File.AppendAllText(LOG, line + "\r\n"); } catch { }
    }

    static string Text(IntPtr h)
    {
        var sb = new StringBuilder(512);
        GetWindowText(h, sb, sb.Capacity);
        return sb.ToString();
    }
    static string Class(IntPtr h)
    {
        var sb = new StringBuilder(256);
        GetClassName(h, sb, sb.Capacity);
        return sb.ToString();
    }

    static int clicks = 0;

    static bool ChildCb(IntPtr h, IntPtr l)
    {
        string t = Text(h), c = Class(h);
        if (t.Length == 0) return true;
        string low = t.ToLowerInvariant();
        int pass = l.ToInt32();
        // never click the negative choice ("Do&n't install this driver software")
        if (low.Contains("n't install") || low.Contains("do not install") ||
            low.Contains("cancel") || low.Contains("close") || low.Contains("back"))
            return true;
        bool hit = false;
        if (pass == 0)
        {
            // pass 0: the radio/link that lets an unsigned package through
            if (low.Contains("anyway") || low.Contains("install this driver")) hit = true;
        }
        else
        {
            // pass 1: the confirm button
            if (low == "ok" || low == "next" || low == "next >" || low == "finish" ||
                low == "install" || low == "yes") hit = true;
        }
        if (hit)
        {
            Log("  click(pass" + pass + "): class=" + c + " text=\"" + t + "\"");
            SendMessage(h, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
            clicks++;
            Thread.Sleep(400);
        }
        return true;
    }

    static bool TopCb(IntPtr h, IntPtr l)
    {
        if (!IsWindowVisible(h)) return true;
        uint pid; GetWindowThreadProcessId(h, out pid);
        string t = Text(h), c = Class(h);
        if (t.Length == 0) return true;
        // only touch dialogs that belong to the installer / newdev UI
        bool interesting =
            t.IndexOf("Code Integrity", StringComparison.OrdinalIgnoreCase) >= 0 ||
            t.IndexOf("driver", StringComparison.OrdinalIgnoreCase) >= 0 ||
            t.IndexOf("Found New Hardware", StringComparison.OrdinalIgnoreCase) >= 0 ||
            t.IndexOf("Program Compatibility", StringComparison.OrdinalIgnoreCase) >= 0 ||
            c == "#32770";
        if (!interesting) return true;
        Log("dialog: class=" + c + " title=\"" + t + "\" pid=" + pid + " (self=" + ourPid + ")");
        EnumChildWindows(h, ChildCb, new IntPtr(0));   // choose "install anyway"
        EnumChildWindows(h, ChildCb, new IntPtr(1));   // then confirm
        return true;
    }

    static volatile bool done = false;
    static bool result = false;
    static int lastErr = 0;

    static void Main(string[] argv)
    {
        string hwid = argv.Length > 0 ? argv[0] : "USB\\VID_2304&PID_022E";
        string inf = argv.Length > 1 ? argv[1] : @"C:\pctv2\PCTV320cx-mod7700.inf";
        try { File.WriteAllText(LOG, ""); } catch { }
        Log("=== instclick start hwid=" + hwid + " inf=" + inf + " ===");

        Thread t = new Thread(delegate ()
        {
            bool reboot;
            result = UpdateDriverForPlugAndPlayDevices(IntPtr.Zero, hwid, inf, INSTALLFLAG_FORCE, out reboot);
            lastErr = Marshal.GetLastWin32Error();
            Log("UpdateDriverForPlugAndPlayDevices -> " + result + " lasterr=0x" +
                lastErr.ToString("x") + " reboot=" + reboot);
            done = true;
        });
        t.IsBackground = true;
        t.Start();

        for (int i = 0; i < 240 && !done; i++)   // up to 2 minutes of dialog watching
        {
            EnumWindows(TopCb, IntPtr.Zero);
            Thread.Sleep(500);
        }
        t.Join(5000);
        Log("=== instclick done: ok=" + result + " lasterr=0x" + lastErr.ToString("x") +
            " clicks=" + clicks + " ===");
    }
}
