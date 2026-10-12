"""Apply the additive ephemeral local-account extension to MultiSeat v0.6.7."""
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1])
manager = root / 'src/MultiSeat.Service/Accounts/AccountManager.cs'
text = manager.read_text(encoding='utf-8-sig')
if 'UseEpicVMTemporaryCredential' not in text:
    anchor = '    private readonly bool _grantAdministrator;'
    extension = '''    // Separate RAM-only store: never enumerated by persistence or credential reveal.
    private readonly ConcurrentDictionary<string, string> _epicvmTemporary = new(StringComparer.OrdinalIgnoreCase);
    public IDisposable UseEpicVMTemporaryCredential(string username, string password)
    {
        if (_managedAccounts.ContainsKey(username))
            throw new InvalidOperationException("Account is already managed or linked.");
        if (!_epicvmTemporary.TryAdd(username, password))
            throw new InvalidOperationException("Account is already being provisioned.");
        return new EpicVMTemporaryLease(() => {
            _epicvmTemporary.TryRemove(username, out _);
        });
    }
    public bool IsEpicVMTemporaryAccount(string username) => _epicvmTemporary.ContainsKey(username);
    sealed class EpicVMTemporaryLease(Action release) : IDisposable
    {
        public void Dispose() => release();
    }

'''
    assert text.count(anchor) == 1
    text = text.replace(anchor, extension + anchor)
    text = text.replace('_managedAccounts.ContainsKey(username);', '_managedAccounts.ContainsKey(username) || _epicvmTemporary.ContainsKey(username);')
    text = text.replace('_credentials.GetValueOrDefault(username);', '_credentials.GetValueOrDefault(username) ?? _epicvmTemporary.GetValueOrDefault(username);', 1)
    text = text.replace('public void ApplySeatGroupMembership(string username)\n    {', 'public void ApplySeatGroupMembership(string username)\n    {\n        if (_epicvmTemporary.ContainsKey(username)) { AddToGroup(username, RemoteDesktopUsersGroup); return; }')
    # Keep generic account mutations from racing the temporary credential scope.
    for signature in ['public AccountInfo CreateAccount(string username, string? password = null)', 'public AccountInfo LinkExistingAccount(string username, string password)', 'public void DeleteAccount(string username)']:
        anchor = signature + '\n    {'
        assert text.count(anchor) == 1
        text = text.replace(anchor, anchor + '\n        if (_epicvmTemporary.ContainsKey(username)) throw new InvalidOperationException("Account is being provisioned.");')
    manager.write_text(text, encoding='utf-8')
if 'IsEpicVMTemporaryAccount' not in text:
    text = text.replace('    private readonly bool _grantAdministrator;', '    public bool IsEpicVMTemporaryAccount(string username) => _epicvmTemporary.ContainsKey(username);\n    private readonly bool _grantAdministrator;')
    manager.write_text(text, encoding='utf-8')
store = root / 'src/MultiSeat.Service/Sessions/RdpCredentialStore.cs'
text = store.read_text(encoding='utf-8-sig')
if 'bool sessionOnly' not in text:
    text = text.replace('string userName, string password)', 'string userName, string password, bool sessionOnly = false)')
    text = text.replace('Persist = CredApi.CRED_PERSIST_LOCAL_MACHINE,', 'Persist = sessionOnly ? 1u : CredApi.CRED_PERSIST_LOCAL_MACHINE,')
    store.write_text(text, encoding='utf-8')
launcher = root / 'src/MultiSeat.Service/Sessions/SessionLauncher.cs'
text = launcher.read_text(encoding='utf-8-sig')
if 'IsEpicVMTemporaryAccount' not in text:
    # Both creation and reconnect remove the Windows credential in their finally block.
    import re
    text, count = re.subn(r'(\$"\{machineName\}\\\\\{accountName\}", password)(\))', r'\1, _accounts.IsEpicVMTemporaryAccount(accountName)\2', text)
    assert count == 2
    launcher.write_text(text, encoding='utf-8')
program = root / 'src/MultiSeat.Service/Api/ApiServer.cs'
text = program.read_text(encoding='utf-8-sig')
if 'EpicVMExistingAccountEndpoints.Map' not in text:
    anchor = 'AccountEndpoints.Map(app);'
    assert text.count(anchor) == 1
    program.write_text(text.replace(anchor, anchor + '\nEpicVMExistingAccountEndpoints.Map(app);'), encoding='utf-8')
shutil.copy2(Path(__file__).with_name('EpicVMExistingAccountEndpoints.cs'), root / 'src/MultiSeat.Service/Api/EpicVMExistingAccountEndpoints.cs')
print('Applied temporary existing-local-account credential path')
