using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace MultiSeat.Service.Input;

public static class ControllerGateInjector
{
    // Apollo is created suspended. No unconfined controller can be allocated
    // before the library is loaded and its import-table hook is verified.
    public static void Install(IntPtr process, int pid, string dll)
    {
        dll = Path.GetFullPath(dll);
        if (!File.Exists(dll)) throw new FileNotFoundException("Controller gate DLL missing", dll);
        var buffer = Encoding.Unicode.GetBytes(dll + '\0');
        var remote = VirtualAllocEx(process, IntPtr.Zero, (nuint)buffer.Length, 0x3000, 4);
        if (remote == IntPtr.Zero) throw Error();
        try
        {
            if (!WriteProcessMemory(process, remote, buffer, (nuint)buffer.Length, out var written) || written != (nuint)buffer.Length) throw Error();
            var kernel = GetModuleHandleW("kernel32.dll");
            var loader = GetProcAddress(kernel, "LoadLibraryW");
            using var target = Process.GetProcessById(pid);
            // A newly suspended process may still have only ntdll mapped. The
            // remote thread initializes Windows' shared system DLLs before its
            // start routine. Both processes are native x64 on this host. Reading
            // its module list before that initialization returns ERROR_PARTIAL_COPY.
            if (loader == IntPtr.Zero) throw Error();
            Run(process, loader, remote);
            target.Refresh();
            var module = target.Modules.Cast<ProcessModule>().SingleOrDefault(m => string.Equals(m.FileName, dll, StringComparison.OrdinalIgnoreCase))
                ?? throw new InvalidOperationException("Controller gate did not load in Apollo");
            // Map without running DllMain in the service itself.
            var local = LoadLibraryExW(dll, IntPtr.Zero, 1);
            if (local == IntPtr.Zero) throw Error();
            try
            {
                var status = GetProcAddress(local, "EpicVMGateStatus");
                if (status == IntPtr.Zero || Run(process, module.BaseAddress + checked((int)(status.ToInt64() - local.ToInt64())), IntPtr.Zero) != 0x45564731)
                    throw new InvalidOperationException("Apollo DeviceIoControl hook was not installed");
            }
            finally { FreeLibrary(local); }
        }
        finally { VirtualFreeEx(process, remote, 0, 0x8000); }
    }

    private static uint Run(IntPtr process, IntPtr routine, IntPtr argument)
    {
        var thread = CreateRemoteThread(process, IntPtr.Zero, 0, routine, argument, 0, out _);
        if (thread == IntPtr.Zero) throw Error();
        try
        {
            if (WaitForSingleObject(thread, 10000) != 0) throw new TimeoutException("Controller gate injection timed out");
            if (!GetExitCodeThread(thread, out var code)) throw Error();
            return code;
        }
        finally { CloseHandle(thread); }
    }
    public static void Resume(IntPtr thread)
    {
        if (ResumeThread(thread) == uint.MaxValue) throw Error();
    }
    private static Win32Exception Error() => new(Marshal.GetLastWin32Error());
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr GetModuleHandleW(string module);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)] private static extern IntPtr GetProcAddress(IntPtr module, string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll")] private static extern bool FreeLibrary(IntPtr module);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr VirtualAllocEx(IntPtr process, IntPtr address, nuint size, uint type, uint protection);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool VirtualFreeEx(IntPtr process, IntPtr address, nuint size, uint type);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool WriteProcessMemory(IntPtr process, IntPtr address, byte[] buffer, nuint size, out nuint written);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr CreateRemoteThread(IntPtr process, IntPtr attributes, nuint stack, IntPtr start, IntPtr argument, uint flags, out uint id);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetExitCodeThread(IntPtr thread, out uint code);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
}
