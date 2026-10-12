using System.Diagnostics;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace EpicVM.Control;

record Policy(bool paused = false, int maxSeats = 0, int width = 1920, int height = 1080, int fps = 60, bool normalEnabled = true, bool localEnabled = true);

sealed class ControlService : ServiceBase
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafePipeHandle CreateNamedPipe(string name, uint openMode, uint pipeMode, uint instances, uint outSize, uint inSize, uint timeout, ref SecurityAttributes attributes);
    [StructLayout(LayoutKind.Sequential)]
    struct SecurityAttributes { public int Length; public IntPtr Descriptor; public int Inherit; }
    static NamedPipeServerStream LocalPipe(PipeSecurity security)
    {
        var descriptor = security.GetSecurityDescriptorBinaryForm();
        var pinned = GCHandle.Alloc(descriptor, GCHandleType.Pinned);
        try {
            var attributes = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), Descriptor = pinned.AddrOfPinnedObject() };
            // Reject SMB clients at creation while retaining the explicit operator ACL.
            var handle = CreateNamedPipe(@"\\.\pipe\EpicVM.HostControl", 3 | 0x40000000, 8, 1, 32768, 32768, 0, ref attributes);
            if (handle.IsInvalid) { handle.Dispose(); throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); }
            try { return new NamedPipeServerStream(PipeDirection.InOut, true, false, handle); }
            catch { handle.Dispose(); throw; }
        } finally { pinned.Free(); }
    }
    static readonly string DataRoot = StorageRoot();
    static readonly string Root = Path.Combine(DataRoot, "host-runtime");
    static string StorageRoot() {
        var defaultRoot=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),"EpicVM");
        var locator=Path.Combine(defaultRoot,"storage.json");
        if(!File.Exists(locator))return defaultRoot;
        var saved=JsonNode.Parse(File.ReadAllText(locator))!;
        var path=saved["dataRoot"]?.ToString()??"";
        if(saved["schema"]?.GetValue<int>()!=1 || !Regex.IsMatch(path,@"^[A-Za-z]:\\") || path.Contains("..") || path.Contains('"'))throw new IOException("Invalid protected data location.");
        path=Path.GetFullPath(path).TrimEnd('\\');
        if(path.Length<4 || !Directory.Exists(path))throw new IOException("Selected EpicVM data drive is unavailable.");
        for(var dir=new DirectoryInfo(path);dir!=null;dir=dir.Parent)if((dir.Attributes&FileAttributes.ReparsePoint)!=0)throw new IOException("Data location cannot traverse links.");
        return path;
    }
    static readonly string AgentRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "EpicVM", "agent");
    readonly CancellationTokenSource stop = new();
    readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(5) };
    static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };
    public ControlService() { ServiceName = "EpicVMHostControl"; }
    protected override void OnStart(string[] args) { _ = Task.Run(Serve); }
    protected override void OnStop() { stop.Cancel(); }
    static JsonObject ReadObject(string path) => JsonNode.Parse(File.ReadAllText(path))!.AsObject();
    static JsonObject? OptionalObject(string path) { try { return File.Exists(path) ? ReadObject(path) : null; } catch { return null; } }
    static Policy ReadPolicy() => File.Exists(Path.Combine(Root, "hosting-policy.json")) ? JsonSerializer.Deserialize<Policy>(File.ReadAllText(Path.Combine(Root, "hosting-policy.json")), JsonOptions)! : new();
    static void Write(string path, string text) { File.WriteAllText(path + ".new", text, new UTF8Encoding(false)); File.Move(path + ".new", path, true); }
    static string ServiceState(string name) { try { using var service = new ServiceController(name); return service.Status.ToString(); } catch { return "Unavailable"; } }
    async Task<JsonNode?> MultiSeat(HttpMethod method, string path)
    {
        using var req = new HttpRequestMessage(method, "http://127.0.0.1:9550/api/" + path);
        req.Headers.Add("X-MultiSeat-Key", File.ReadAllText(@"C:\ProgramData\MultiSeat\api-key.txt").Trim());
        using var response = await http.SendAsync(req, stop.Token);
        response.EnsureSuccessStatusCode();
        var text = await response.Content.ReadAsStringAsync();
        return string.IsNullOrWhiteSpace(text) ? null : JsonNode.Parse(text);
    }
    static bool Managed(string account)
    {
        var path = Path.Combine(DataRoot,"host-gaming","local-account-assignments.json");
        var mappings = File.Exists(path) ? ReadObject(path) : new JsonObject();
        foreach (var entry in mappings) {
            if (!string.Equals(entry.Value?["accountName"]?.ToString(), account, StringComparison.OrdinalIgnoreCase)) continue;
            if (!Regex.IsMatch(entry.Key, @"^portal:[a-zA-Z0-9_.@-]{1,128}$")) return false;
            try {
                var sid = (SecurityIdentifier)new NTAccount(Environment.MachineName, account).Translate(typeof(SecurityIdentifier));
                return sid.Value == entry.Value?["accountSid"]?.ToString();
            } catch (IdentityNotMappedException) { return false; }
        }
        return Regex.IsMatch(account, @"^(evseat_[0-9a-f]{13}|EpicVM_[a-z0-9_]{1,13})$", RegexOptions.IgnoreCase);
    }
    async Task<JsonArray> Seats()
    {
        var result = new JsonArray();
        var seats = (await MultiSeat(HttpMethod.Get, "seats/"))?.AsArray() ?? new();
        foreach (var node in seats)
        {
            var seat = node!.AsObject();
            if (!Managed(seat["accountName"]?.ToString() ?? "")) continue;
            var clean = new JsonObject();
            foreach (var key in new[] { "id", "accountName", "status", "sessionId", "portBase" }) clean[key] = seat[key]?.DeepClone();
            result.Add(clean);
        }
        return result;
    }
    async Task<JsonObject> Status()
    {
        JsonNode? runtime = null;
        try { runtime = ReadObject(Path.Combine(Root, "runtime-status.json")); } catch { }
        JsonArray seats;
        string? seatError = null;
        try { seats = await Seats(); } catch { seats = new(); seatError = "MultiSeat status is unavailable."; }
        var runtimeConfig = ReadObject(Path.Combine(Root, "host-runtime.json"));
        var routes = ReadObject(Path.Combine(Root, "routes.json"));
        var resources = new JsonArray();
        foreach (var route in routes) resources.Add(new JsonObject { ["route"] = route.Key, ["enabled"] = route.Value?["enabled"]?.DeepClone() });
        JsonNode games = new JsonArray();
        try { games = JsonNode.Parse(File.ReadAllText(Path.Combine(DataRoot,"host-gaming","games.json")))!; } catch { }
        using var hostService = new ServiceController("EpicVMHostRuntime");
        var events = new JsonArray();
        var auditPath = Path.Combine(Root, "control-audit.log");
        if (File.Exists(auditPath)) {
            foreach (var line in File.ReadLines(auditPath).TakeLast(50))
                if (Regex.IsMatch(line, @"^[0-9T:.+Z-]+ (policy|settings|startup|runtime-start|runtime-stop|repair|seat-end|game-save|game-remove)$")) events.Add(line);
        }
        return new JsonObject {
            ["release"] = OptionalObject(@"C:\Program Files\EpicVM\release.json")?["version"]?.DeepClone() ?? JsonValue.Create("Legacy install"),
            ["controlVersion"] = JsonValue.Create(typeof(ControlService).Assembly.GetName().Version?.ToString()),
            ["lastUpdate"] = OptionalObject(@"C:\ProgramData\EpicVM\updates\host-releases\last-update.json"),
            ["rollbackUpdate"] = OptionalObject(@"C:\ProgramData\EpicVM\updates\host-releases\last-successful-update.json"),
            ["runtime"] = runtime, ["services"] = new JsonObject { ["Runtime"] = ServiceState("EpicVMHostRuntime"), ["Agent"] = ServiceState("EpicVMRemoteAgent"), ["MultiSeat"] = ServiceState("MultiSeatService"), ["Tailscale"] = ServiceState("Tailscale") },
            ["startAtBoot"] = hostService.StartType == ServiceStartMode.Automatic,
            ["policy"] = JsonSerializer.SerializeToNode(ReadPolicy()), ["seats"] = seats, ["seatError"] = seatError,
            ["games"] = games, ["resources"] = resources,
            ["recentOperations"] = events,
            ["hostId"] = runtimeConfig["hostId"]?.DeepClone(), ["publicOrigin"] = runtimeConfig["publicOrigin"]?.DeepClone(),
            ["lan"] = File.Exists(Path.Combine(Root, "local-gateway.json")) ? ReadObject(Path.Combine(Root, "local-gateway.json")) : null
        };
    }
    static async Task Run(string exe, params string[] args)
    {
        var info = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true };
        foreach (var arg in args) info.ArgumentList.Add(arg);
        using var process = Process.Start(info)!;
        var output = process.StandardOutput.ReadToEndAsync(); var errors = process.StandardError.ReadToEndAsync();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        try { await process.WaitForExitAsync(timeout.Token); }
        catch { process.Kill(true); throw new InvalidOperationException("Operation timed out."); }
        await output; await errors;
        if (process.ExitCode != 0) throw new InvalidOperationException($"Host operation failed (exit {process.ExitCode}).");
    }
    async Task<JsonObject> Execute(JsonObject req, bool administrator)
    {
        var op = req["operation"]?.ToString();
        if (op == "status" || op == "diagnostics") return await Status();
        if (!administrator) throw new UnauthorizedAccessException("Administrator approval is required for host changes.");
        switch (op)
        {
            case "settings":
            case "policy":
                var policy = req["policy"]!.Deserialize<Policy>(JsonOptions)!;
                if (policy.maxSeats < 0 || policy.maxSeats > 64 || !new[] { 1280, 1600, 1920, 2560, 3840 }.Contains(policy.width) || !new[] { 720, 900, 1080, 1440, 2160 }.Contains(policy.height) || !new[] { 30, 60, 120 }.Contains(policy.fps)) throw new ArgumentException("Choose supported desktop limits and dimensions.");
                if (op == "settings") await Run("sc.exe", "config", "EpicVMHostRuntime", "start=", req["startAtBoot"]!.GetValue<bool>() ? "auto" : "demand");
                Write(Path.Combine(Root, "hosting-policy.json"), JsonSerializer.Serialize(policy));
                break;
            case "startup":
                await Run("sc.exe", "config", "EpicVMHostRuntime", "start=", req["enabled"]!.GetValue<bool>() ? "auto" : "demand");
                break;
            case "runtime-start":
                using (var service = new ServiceController("EpicVMHostRuntime")) { if (service.Status == ServiceControllerStatus.Stopped) service.Start(); }
                break;
            case "runtime-stop":
                using (var service = new ServiceController("EpicVMHostRuntime")) { if (service.Status != ServiceControllerStatus.Stopped) service.Stop(); }
                break;
            case "repair":
                var route = req["route"]!.ToString();
                if (!Regex.IsMatch(route, @"^(seat-[0-9a-f]{24}|vm-[a-z0-9][a-z0-9._-]{0,62})$")) throw new ArgumentException("Invalid stream resource.");
                var cfg = ReadObject(Path.Combine(Root, "host-runtime.json"));
                await Run(cfg["pythonExe"]!.ToString(), Path.Combine(cfg["scriptsRoot"]!.ToString(), "manage_host_runtime.py"), Path.Combine(Root, "host-runtime.json"), route);
                break;
            case "seat-end":
                var id = req["seatId"]!.ToString();
                if (!Guid.TryParse(id, out _) || !(await Seats()).Any(s => s?["id"]?.ToString() == id)) throw new ArgumentException("Seat is not managed by EpicVM.");
                await MultiSeat(HttpMethod.Delete, "seats/" + id);
                break;
            case "game-save":
            case "game-remove":
                var gameId = req["id"]!.ToString();
                if (!Regex.IsMatch(gameId, "^[a-z0-9][a-z0-9-]{0,63}$")) throw new ArgumentException("Invalid game ID.");
                var catalogPath = Path.Combine(DataRoot,"host-gaming","games.json");
                var catalogText = File.Exists(catalogPath) ? File.ReadAllText(catalogPath) : "";
                var catalog = string.IsNullOrWhiteSpace(catalogText) ? new JsonArray() : JsonNode.Parse(catalogText)!.AsArray();
                var updated = new JsonArray(catalog.Where(g => g?["id"]?.ToString() != gameId).Select(g => g!.DeepClone()).ToArray());
                if (op == "game-save") {
                    var title = req["title"]!.ToString(); var path = Path.GetFullPath(req["executable"]!.ToString());
                    if (string.IsNullOrWhiteSpace(title) || title.Length > 120 || !File.Exists(path) || !path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || Regex.IsMatch(path, @"\\(Users|AppData|Windows)\\", RegexOptions.IgnoreCase) || path.StartsWith(@"\\")) throw new ArgumentException("Choose a machine-installed game executable.");
                    updated.Add(new JsonObject { ["id"] = gameId, ["title"] = title, ["executable"] = path });
                }
                Directory.CreateDirectory(Path.GetDirectoryName(catalogPath)!); Write(catalogPath, updated.ToJsonString());
                break;
            default: throw new ArgumentException("Unsupported operation.");
        }
        File.AppendAllText(Path.Combine(Root, "control-audit.log"), $"{DateTimeOffset.UtcNow:O} {op}\n");
        return new JsonObject { ["message"] = "Saved. Existing Windows desktops are preserved unless you explicitly ended a seat." };
    }
    async Task Serve()
    {
        while (!stop.IsCancellationRequested)
        {
            var security = new PipeSecurity();
            foreach (var sid in new[] { new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), new SecurityIdentifier(File.ReadAllText(Path.Combine(Root, "operator.sid")).Trim()) })
                security.AddAccessRule(new PipeAccessRule(sid, PipeAccessRights.ReadWrite, AccessControlType.Allow));
            using var pipe = LocalPipe(security);
            try {
                await pipe.WaitForConnectionAsync(stop.Token);
                bool admin = false;
                pipe.RunAsClient(() => admin = new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator));
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(stop.Token); deadline.CancelAfter(TimeSpan.FromSeconds(15));
                var buffer = new List<byte>(); var one = new byte[1];
                while (buffer.Count <= 32768 && await pipe.ReadAsync(one, deadline.Token) == 1 && one[0] != 10) buffer.Add(one[0]);
                if (buffer.Count > 32768) throw new ArgumentException("Request too large.");
                var req = JsonNode.Parse(Encoding.UTF8.GetString(buffer.ToArray()))!.AsObject();
                JsonObject response;
                try { response = new JsonObject { ["ok"] = true, ["data"] = await Execute(req, admin) }; }
                catch (Exception ex) {
                    File.AppendAllText(Path.Combine(Root, "control-errors.log"), $"{DateTimeOffset.UtcNow:O} {req["operation"]} {ex.GetType().Name}\n");
                    response = new JsonObject { ["ok"] = false, ["error"] = ex is ArgumentException or UnauthorizedAccessException or InvalidOperationException ? ex.Message : "Host operation failed. Check diagnostics and service readiness." };
                }
                var encoded = Encoding.UTF8.GetBytes(response.ToJsonString() + "\n");
                await pipe.WriteAsync(encoded, deadline.Token);
            } catch (OperationCanceledException) { } catch (IOException) { } catch (JsonException) { } catch (ArgumentException) { }
        }
    }
    static void Main() => ServiceBase.Run(new ControlService());
}
