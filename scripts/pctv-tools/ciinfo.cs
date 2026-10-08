// ciinfo.cs — report the kernel Code Integrity / test-signing state.
//
// NtQuerySystemInformation(SystemCodeIntegrityInformation = 103) returns a
// SYSTEM_CODEINTEGRITY_INFORMATION { ULONG Length; ULONG CodeIntegrityOptions; }.
//   0x01 CODEINTEGRITY_OPTION_ENABLED
//   0x02 CODEINTEGRITY_OPTION_TESTSIGN
//   0x04 CODEINTEGRITY_OPTION_UMCI_ENABLED
//
// Build in the guest:
//   C:\Windows\Microsoft.NET\Framework64\v3.5\csc.exe /nologo /platform:x64 ^
//     /out:C:\Users\Chris\ciinfo.exe C:\Users\Chris\ciinfo.cs

using System;
using System.Runtime.InteropServices;

class CiInfo
{
    [DllImport("ntdll.dll")]
    static extern int NtQuerySystemInformation(int cls, byte[] info, int len, IntPtr retlen);

    static int Main()
    {
        byte[] b = new byte[8];
        b[0] = 8; // Length
        int st = NtQuerySystemInformation(103, b, b.Length, IntPtr.Zero);
        if (st != 0) { Console.WriteLine("NtQuerySystemInformation -> 0x" + st.ToString("x")); return 1; }
        uint opt = (uint)(b[4] | b[5] << 8 | b[6] << 16 | b[7] << 24);
        Console.WriteLine("CodeIntegrityOptions = 0x" + opt.ToString("x"));
        Console.WriteLine("  ENABLED    : " + ((opt & 1) != 0));
        Console.WriteLine("  TESTSIGN   : " + ((opt & 2) != 0));
        Console.WriteLine("  UMCI       : " + ((opt & 4) != 0));
        return 0;
    }
}
