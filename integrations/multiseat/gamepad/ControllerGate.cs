using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Options;
using Microsoft.Win32.SafeHandles;
using MultiSeat.Service.Configuration;

namespace MultiSeat.Service.Input;

// The injector registers the actual process before resuming Apollo. Clients never
// supply a session or PID. Reservations survive controller unplug/replug and are
// released only after their process exits and the PnP device disappears.
public sealed class ControllerGate : BackgroundService
{
    private readonly MultiSeatOptions options;
    private readonly ILogger<ControllerGate> logger;
    private readonly object gate = new();
    private readonly Dictionary<int, Process> processes = new();
    private readonly Dictionary<uint, Reservation> reservations = new();
    private HashSet<string> consoleRules = new(StringComparer.OrdinalIgnoreCase);
    private readonly string journal = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "MultiSeat", "controller-gate.json");
    public sealed record Reservation(int Pid, long Started, int Session, HashSet<string> Rules);

    public ControllerGate(IOptions<MultiSeatOptions> options, ILogger<ControllerGate> logger)
    {
        this.options = options.Value;
        this.logger = logger;
    }

    public void Register(int pid, int session)
    {
        if (!options.EpicVMControllerGate) return;
        var process = Process.GetProcessById(pid);
        if (process.SessionId != session || session <= 0 ||
            !string.Equals(process.MainModule?.FileName, Path.GetFullPath(options.ApolloExePath), StringComparison.OrdinalIgnoreCase))
        {
            process.Dispose();
            throw new InvalidOperationException("Controller gate process identity mismatch");
        }
        // Force acquisition of an OS process handle, protecting against PID reuse.
        _ = process.Handle;
        lock (gate) processes.Add(pid, process);
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!options.EpicVMControllerGate) return;
        lock (gate)
        {
            if (File.Exists(journal))
                foreach (var entry in JsonSerializer.Deserialize<Dictionary<uint, Reservation>>(File.ReadAllText(journal)) ?? new())
                    reservations.Add(entry.Key, entry.Value);
            if (File.Exists(journal + ".console"))
                consoleRules = new(JsonSerializer.Deserialize<string[]>(File.ReadAllText(journal + ".console")) ?? [], StringComparer.OrdinalIgnoreCase);
            ConfineConsoleControllers();
            using var driver = new Driver();
            driver.Validate(options.HidHideCliPath);
            Cleanup(driver);
        }
        // Multiple listeners keep a slow/malicious connection from monopolizing the pipe.
        await Task.WhenAll(Enumerable.Range(0, 4).Select(_ => Listen(stoppingToken)).Append(Maintain(stoppingToken)));
    }

    private async Task Maintain(CancellationToken ct)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(2));
        int tick = 0;
        while (await timer.WaitForNextTickAsync(ct))
        {
            try { lock (gate) { if (++tick % 5 == 0) ConfineConsoleControllers(); using var driver = new Driver(); Cleanup(driver); } }
            catch (Exception ex) { logger.LogWarning("Controller reservation cleanup deferred: {Reason}", ex.Message); }
        }
    }

    private void ConfineConsoleControllers()
    {
        // Read before opening the exclusive driver handle. Newly attached physical
        // pads are assigned to the local console; remote pads use the allocation gate.
        var read = new HidHideCli(logger, options.HidHideCliPath).Read("--dev-gaming");
        if (!read.Succeeded || !read.Answered || !read.Output.Contains('['))
            throw new InvalidOperationException("Cannot identify physical host controllers");
        var session = checked((int)WTSGetActiveConsoleSessionId());
        if (session <= 0) throw new InvalidOperationException("No console session for physical controllers");
        var paths = HidHideDeviceParser.Parse(read.Output)
            .Where(d => d.GamingDevice && d.Present && !HidHideSessionJail.IsEmulatedPad(d))
            .SelectMany(d => d.Nodes)
            // Keep known device paths confined while unplugged. Removing their
            // rules would let other sessions open them during the next hotplug.
            .Concat(consoleRules.Select(r => HidHideSessionJail.Split(r).Path))
            .Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        using var driver = new Driver();
        driver.Validate(options.HidHideCliPath);
        var rules = driver.List(2050);
        var original = new HashSet<string>(rules, StringComparer.OrdinalIgnoreCase);
        rules.ExceptWith(consoleRules);
        var merged = ControllerGatePolicy.MergeRules(rules, new(StringComparer.OrdinalIgnoreCase), paths, session);
        var next = new HashSet<string>(paths.Select(p => HidHideSessionJail.Confine(p, session)), StringComparer.OrdinalIgnoreCase);
        // Journal first; preserving the union covers a crash between driver update
        // and recording the final set when the console session changes.
        Directory.CreateDirectory(Path.GetDirectoryName(journal)!);
        File.WriteAllText(journal + ".console.new", JsonSerializer.Serialize(consoleRules.Union(next)));
        File.Move(journal + ".console.new", journal + ".console", true);
        if (!original.SetEquals(merged)) driver.SetList(2051, merged);
        driver.SetActive(true);
        consoleRules = next;
        File.WriteAllText(journal + ".console.new", JsonSerializer.Serialize(consoleRules));
        File.Move(journal + ".console.new", journal + ".console", true);
    }

    private async Task Listen(CancellationToken ct)
    {
        var acl = new PipeSecurity();
        acl.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
        acl.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.AuthenticatedUserSid, null), PipeAccessRights.ReadWrite, AccessControlType.Allow));
        while (!ct.IsCancellationRequested)
        {
            using var pipe = NamedPipeServerStreamAcl.Create("EpicVM.ControllerGate.v1", PipeDirection.InOut, 4,
                PipeTransmissionMode.Message, PipeOptions.Asynchronous, 4096, 4096, acl);
            try
            {
                await pipe.WaitForConnectionAsync(ct);
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
                timeout.CancelAfter(TimeSpan.FromSeconds(5));
                var request = new byte[12];
                await pipe.ReadExactlyAsync(request, timeout.Token);
                uint result = 2;
                if (pipe.IsMessageComplete && GetNamedPipeClientProcessId(pipe.SafePipeHandle, out var pid) &&
                    BitConverter.ToUInt32(request, 0) == 0x45564731)
                {
                    lock (gate)
                        result = Handle((int)pid, BitConverter.ToUInt32(request, 4), BitConverter.ToUInt32(request, 8));
                }
                await pipe.WriteAsync(BitConverter.GetBytes(result), timeout.Token);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { break; }
            catch (Exception ex) { logger.LogWarning("Controller allocation refused: {Reason}", ex.Message); }
        }
    }

    private uint Handle(int pid, uint command, uint serial)
    {
        if (!processes.TryGetValue(pid, out var process) || process.HasExited || serial is 0 or > 16 || command is not (1 or 2)) return 2;
        using var driver = new Driver();
        driver.Validate(options.HidHideCliPath);
        Cleanup(driver);
        var started = process.StartTime.ToUniversalTime().Ticks;
        var path = $@"USB\VID_045E&PID_028E\{serial:D2}";
        if (reservations.TryGetValue(serial, out var owner) && (owner.Pid != pid || owner.Started != started)) return 1;
        if (owner == null)
        {
            if (command != 1 || Present(path)) return 1;
            owner = new Reservation(pid, started, process.SessionId, new(StringComparer.OrdinalIgnoreCase));
            reservations.Add(serial, owner);
        }
        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { path };
        foreach (var child in DeviceIds())
        {
            if (!child.StartsWith(@"HID\VID_045E&PID_028E", StringComparison.OrdinalIgnoreCase)) continue;
            var parent = HidHideSessionJail.GetParentInstanceId(child);
            // The HID interface has a USB composite interface parent, whose parent is XUSB.
            if (string.Equals(parent, path, StringComparison.OrdinalIgnoreCase) ||
                (parent != null && string.Equals(HidHideSessionJail.GetParentInstanceId(parent), path, StringComparison.OrdinalIgnoreCase)))
                paths.Add(child);
        }
        var rules = driver.List(2050);
        var merged = ControllerGatePolicy.MergeRules(rules, owner.Rules, paths, owner.Session);
        owner.Rules.UnionWith(paths.Select(node => HidHideSessionJail.Confine(node, owner.Session)));
        // Persist our exact additions before touching the driver, so a crash cannot
        // leave anonymous rules that a later session would accidentally inherit.
        Save();
        merged.UnionWith(owner.Rules);
        driver.SetList(2051, merged);
        driver.SetActive(true);
        var verified = driver.List(2050);
        if (!owner.Rules.IsSubsetOf(verified)) throw new InvalidOperationException("HidHide rejected controller confinement");
        logger.LogInformation("Controller serial {Serial} confined to session {Session} (phase {Phase})", serial, owner.Session, command);
        return 0;
    }

    private void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(journal)!);
        File.WriteAllText(journal + ".new", JsonSerializer.Serialize(reservations));
        File.Move(journal + ".new", journal, true);
    }

    private void Cleanup(Driver driver)
    {
        var rules = driver.List(2050);
        bool changed = false;
        foreach (var (serial, owner) in reservations.ToArray())
        {
            bool alive = false;
            try
            {
                using var p = Process.GetProcessById(owner.Pid);
                alive = !p.HasExited && p.StartTime.ToUniversalTime().Ticks == owner.Started;
            }
            catch (ArgumentException) { }
            if (alive || Present($@"USB\VID_045E&PID_028E\{serial:D2}")) continue;
            rules.ExceptWith(owner.Rules);
            reservations.Remove(serial);
            changed = true;
        }
        foreach (var (pid, p) in processes.ToArray())
            if (p.HasExited) { processes.Remove(pid); p.Dispose(); }
        if (changed) { driver.SetList(2051, rules); Save(); }
    }

    private static bool Present(string path) => CM_Locate_DevNodeW(out _, path, 0) == 0;
    private static IEnumerable<string> DeviceIds()
    {
        if (CM_Get_Device_ID_List_SizeW(out uint length, null, 0) != 0) throw new InvalidOperationException("Cannot enumerate PnP device IDs");
        var chars = new char[length];
        if (CM_Get_Device_ID_ListW(null, chars, length, 0) != 0) throw new InvalidOperationException("Cannot enumerate PnP device IDs");
        return new string(chars).Split('\0', StringSplitOptions.RemoveEmptyEntries);
    }

    private sealed class Driver : IDisposable
    {
        private readonly SafeFileHandle handle;
        public Driver()
        {
            handle = CreateFileW(@"\\.\HidHide", 0x80000000, 7, IntPtr.Zero, 3, 0, IntPtr.Zero);
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot open HidHide control device");
        }
        private static uint Code(uint function) => (32769u << 16) | (1u << 14) | (function << 2);
        private uint Call(uint function, byte[]? input, byte[]? output)
        {
            if (!DeviceIoControl(handle, Code(function), input, (uint)(input?.Length ?? 0), output, (uint)(output?.Length ?? 0), out var bytes, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "HidHide controller policy operation failed");
            return bytes;
        }
        public HashSet<string> List(uint function)
        {
            var bytes = new byte[Call(function, null, null)];
            Call(function, null, bytes);
            return new(Encoding.Unicode.GetString(bytes).Split('\0', StringSplitOptions.RemoveEmptyEntries), StringComparer.OrdinalIgnoreCase);
        }
        public void SetList(uint function, HashSet<string> values) => Call(function, Encoding.Unicode.GetBytes(string.Join('\0', values.Order(StringComparer.OrdinalIgnoreCase)) + "\0\0"), null);
        public void SetActive(bool value)
        {
            var active = new byte[1];
            Call(2052, null, active);
            if ((active[0] != 0) != value)
                Call(2053, new byte[] { value ? (byte)1 : (byte)0 }, null);
        }
        public void Validate(string cliPath)
        {
            var inverse = new byte[1];
            Call(2054, null, inverse);
            var fullPath = Path.GetFullPath(cliPath);
            var device = new StringBuilder(32768);
            if (QueryDosDeviceW(Path.GetPathRoot(fullPath)!.TrimEnd('\\'), device, device.Capacity) == 0)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot resolve HidHide CLI image path");
            var cliImage = device.ToString() + fullPath[2..];
            // The CLI whitelists itself automatically; it is an admin-only tool.
            if (inverse[0] != 0 || List(2048).Any(p => !string.Equals(p, cliImage, StringComparison.OrdinalIgnoreCase)))
                throw new InvalidOperationException("Existing HidHide application bypass prevents session confinement");
        }
        public void Dispose() => handle.Dispose();
    }

    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint pid);
    [DllImport("kernel32.dll")] private static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern uint QueryDosDeviceW(string drive, StringBuilder target, int length);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool DeviceIoControl(SafeFileHandle handle, uint code, byte[]? input, uint inputSize, byte[]? output, uint outputSize, out uint bytes, IntPtr overlapped);
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] private static extern uint CM_Locate_DevNodeW(out uint node, string path, uint flags);
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] private static extern uint CM_Get_Device_ID_List_SizeW(out uint length, string? filter, uint flags);
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] private static extern uint CM_Get_Device_ID_ListW(string? filter, char[] buffer, uint length, uint flags);
}
