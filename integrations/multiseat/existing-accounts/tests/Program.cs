using System.Collections.Concurrent;
using System.Reflection;
using System.Runtime.CompilerServices;
using MultiSeat.Service.Accounts;
using MultiSeat.Shared.Models;

// Avoid the production constructor and account store. Exercise the compiled
// credential boundary with fresh, isolated dictionaries and no Windows changes.
var manager = (AccountManager)RuntimeHelpers.GetUninitializedObject(typeof(AccountManager));
var persisted = new ConcurrentDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
Set("_credentials", persisted);
Set("_managedAccounts", new ConcurrentDictionary<string, AccountInfo>(StringComparer.OrdinalIgnoreCase));
Set("_epicvmTemporary", new ConcurrentDictionary<string, string>(StringComparer.OrdinalIgnoreCase));
using (manager.UseEpicVMTemporaryCredential("FixtureLocal", "fixture-secret"))
{
    Check(manager.AccountExists("fixturelocal"), "Account lookup during lease");
    Check(manager.GetCredential("FixtureLocal") == "fixture-secret", "Session credential lookup");
    Check(manager.GetManagedCredential("FixtureLocal") is null, "Credential reveal must refuse");
    Check(persisted.Count == 0 && manager.ListManagedAccounts().Count == 0, "Persistence must never see temporary credentials");
    try { manager.UseEpicVMTemporaryCredential("fixturelocal", "different"); throw new Exception("Duplicate lease accepted"); }
    catch (InvalidOperationException) { }
}
Check(manager.GetCredential("FixtureLocal") is null && !manager.AccountExists("FixtureLocal"), "Disposed lease must clear credential");
try
{
    using var lease = manager.UseEpicVMTemporaryCredential("FixtureLocal", "fixture-secret");
    throw new InvalidOperationException("Provisioning failed");
}
catch (InvalidOperationException) { }
Check(manager.GetCredential("FixtureLocal") is null && persisted.Count == 0, "Failed setup must also clear credential");
Console.WriteLine("Compiled credential lease checks passed; no Windows accounts or credential files touched.");
void Set(string name, object value) => typeof(AccountManager).GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(manager, value);
void Check(bool value, string message) { if (!value) throw new Exception(message); }
