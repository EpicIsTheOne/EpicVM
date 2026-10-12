using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Security.Principal;
using MultiSeat.Service.Accounts;
using MultiSeat.Service.Sessions;
using MultiSeat.Shared.Models;

namespace MultiSeat.Service.Api;

public static class EpicVMExistingAccountEndpoints
{
    public sealed record Request(string AccountName, string AccountSid, string Password, int Width = 1920, int Height = 1080, int Fps = 60);
    static readonly ConcurrentDictionary<string, SemaphoreSlim> Gates = new();
    static readonly ConcurrentDictionary<string, (int Count, DateTime Until)> Failures = new();
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool LogonUser(string name, string domain, string password, int type, int provider, out IntPtr token);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr token);

    public static void Map(WebApplication app)
    {
        app.MapGet("/api/accounts/epicvm-existing-support", () => Results.Ok(new { ephemeralCredentials = true }));
        app.MapPost("/api/seats/epicvm-existing", async (Request request, AccountManager accounts, SeatManager seats, SessionLauncher sessions, CancellationToken ct) =>
        {
            if (!ApiInputValidation.IsValidAccountName(request.AccountName) || string.IsNullOrEmpty(request.Password) || request.Password.Length > 256)
                return Results.BadRequest(new { error = "Enter the Windows account password." });
            string sid;
            try { sid = ((SecurityIdentifier)new NTAccount(Environment.MachineName, request.AccountName).Translate(typeof(SecurityIdentifier))).Value; }
            catch { return Results.BadRequest(new { error = "The assigned local account is unavailable." }); }
            if (sid != request.AccountSid) return Results.BadRequest(new { error = "The local account identity changed." });
            var gate = Gates.GetOrAdd(sid, _ => new SemaphoreSlim(1, 1));
            if (!await gate.WaitAsync(TimeSpan.FromSeconds(5), ct)) return Results.Conflict(new { error = "This account is already being checked." });
            try
            {
                if (Failures.TryGetValue(sid, out var failed) && failed.Count >= 5 && failed.Until > DateTime.UtcNow)
                    return Results.Json(new { error = "Too many password attempts. Wait five minutes." }, statusCode: 429);
                if (!LogonUser(request.AccountName, Environment.MachineName, request.Password, 2, 0, out var token))
                {
                    var count = failed.Until > DateTime.UtcNow ? failed.Count + 1 : 1;
                    Failures[sid] = (count, DateTime.UtcNow.AddMinutes(5));
                    return Results.Json(new { error = "The Windows password was not accepted." }, statusCode: 403);
                }
                try {
                    using var identity = new WindowsIdentity(token);
                    if (identity.User?.Value != request.AccountSid)
                        return Results.BadRequest(new { error = "The local account identity changed." });
                } finally { CloseHandle(token); }
                Failures.TryRemove(sid, out _);
                var existing = seats.GetAllSeats().Where(s => string.Equals(s.AccountName, request.AccountName, StringComparison.OrdinalIgnoreCase)).ToArray();
                if (existing.Length == 1 && existing[0].Status is SeatStatus.Ready or SeatStatus.Streaming)
                    return Results.Ok(existing[0]);
                if (existing.Length > 0) return Results.Conflict(new { error = "This account's desktop needs recovery." });
                // Never take over, reconnect, or log off a person's unrelated Windows session.
                if (sessions.FindExistingSession(request.AccountName) >= 0)
                    return Results.Conflict(new { error = "Sign out of this account's other Windows session before opening its EpicVM desktop." });
                using var credential = accounts.UseEpicVMTemporaryCredential(request.AccountName, request.Password);
                var seat = await seats.ProvisionSeatAsync(new SeatRequest { AccountName = request.AccountName, Width = request.Width, Height = request.Height, Fps = request.Fps }, ct);
                return Results.Ok(seat);
            }
            catch (InvalidOperationException) { return Results.Conflict(new { error = "The existing account could not start a desktop." }); }
            finally { gate.Release(); }
        });
    }
}
