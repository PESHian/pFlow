function ConvertTo-PFlowArchitecture([int]$NativeArchitecture) {
    switch ($NativeArchitecture) {
        9 { return 'x64' }
        12 { return 'arm64' }
        0 { return 'x86' }
        default { throw 'This Windows processor architecture is not supported by pFlow.' }
    }
}

function Get-PFlowArchitecture {
    if (-not ('PFlowNativeSystemInfo' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class PFlowNativeSystemInfo {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct VersionInfo {
        public uint Size, Major, Minor, Build, Platform;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Description;
    }
    [DllImport("kernel32.dll")] static extern void GetNativeSystemInfo(IntPtr buffer);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int id);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder path, ref int length);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    public static string ProcessPath(int id) {
        IntPtr handle=OpenProcess(0x1000,false,id);
        if(handle==IntPtr.Zero)return null;
        try { var path=new StringBuilder(32768);int length=path.Capacity;return QueryFullProcessImageName(handle,0,path,ref length)?path.ToString():null; }
        finally { CloseHandle(handle); }
    }
    [DllImport("ntdll.dll", CharSet=CharSet.Unicode)] static extern int RtlGetVersion(ref VersionInfo info);
    public static uint WindowsBuild() {
        var info=new VersionInfo {Size=(uint)Marshal.SizeOf(typeof(VersionInfo)),Description=""};
        if(RtlGetVersion(ref info)!=0 || info.Major<10)return 0;
        return info.Build;
    }
    public static int Architecture() {
        try {
            ushort process, native;
            if(!IsWow64Process2(GetCurrentProcess(),out process,out native))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            switch(native){case 0x8664:return 9;case 0xAA64:return 12;case 0x014c:return 0;default:return -1;}
        } catch(EntryPointNotFoundException) { /* Windows 10 1607 predates Windows on ARM. */ }
        IntPtr buffer = Marshal.AllocHGlobal(64);
        try { GetNativeSystemInfo(buffer); return Marshal.ReadInt16(buffer); }
        finally { Marshal.FreeHGlobal(buffer); }
    }
}
'@
    }
    ConvertTo-PFlowArchitecture ([PFlowNativeSystemInfo]::Architecture())
}

function Get-PFlowExecutableArchitecture([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw 'Invalid Windows executable.' }
        $stream.Position = 60
        $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt $stream.Length - 6) { throw 'Invalid Windows executable header.' }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550) { throw 'Invalid Windows executable signature.' }
        switch ($reader.ReadUInt16()) {
            0x8664 { return 'x64' }
            0xAA64 { return 'arm64' }
            0x014C { return 'x86' }
            default { throw 'Unrecognized Windows executable architecture.' }
        }
    } finally { $reader.Dispose(); $stream.Dispose() }
}

function Assert-PFlowArchitecture([string]$Source, [string]$Expected = (Get-PFlowArchitecture)) {
    # x64 payloads also carry the AVX2 speech worker; without it dictation would silently run the slow baseline.
    $names = @('pFlow.exe', 'engine\whisper-cli.exe', 'engine\pflow-whisper.exe'); if ($Expected -eq 'x64') { $names += 'engine\pflow-whisper-avx2.exe' }
    foreach ($name in $names) {
        $path = Join-Path $Source $name
        if (!(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-PFlowExecutableArchitecture $path) -ne $Expected) {
            throw "This package does not match $Expected Windows. Download the universal Windows ZIP. Your installed app was not changed."
        }
    }
}

# Use .NET directly: Windows PowerShell may inherit a PowerShell 7 module path.
function Get-PFlowFileSha256([string]$Path) {
    $stream=[IO.File]::OpenRead($Path); $sha=$null
    try {
        $sha=[Security.Cryptography.SHA256]::Create()
        return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()
    } finally { if($sha){$sha.Dispose()}; $stream.Dispose() }
}
