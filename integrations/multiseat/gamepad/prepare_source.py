"""Apply EpicVM's opt-in controller extension to a MultiSeat v0.6.7 checkout."""
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1])
service = root / 'src/MultiSeat.Service'

def replace(file, before, after):
    path = service / file
    source = path.read_text(encoding='utf-8-sig')
    if after in source:
        return
    if source.count(before) != 1:
        raise RuntimeError(f'Unsupported MultiSeat layout: {file}')
    path.write_text(source.replace(before, after), encoding='utf-8')

replace('Configuration/MultiSeatOptions.cs',
        'public const string SectionName = "MultiSeat";',
        'public const string SectionName = "MultiSeat";\n'
        '    public bool EpicVMControllerGate { get; set; }\n'
        '    public string EpicVMControllerGateDll { get; set; } = "";')
replace('Sessions/ProcessInjector.cs',
        'private readonly SessionLauncher _sessionLauncher;',
        'private readonly SessionLauncher _sessionLauncher;\n'
        '    private readonly MultiSeat.Service.Input.ControllerGate? _controllerGate;')
replace('Sessions/ProcessInjector.cs',
        'SessionLauncher sessionLauncher)\n',
        'SessionLauncher sessionLauncher, MultiSeat.Service.Input.ControllerGate? controllerGate = null)\n')
replace('Sessions/ProcessInjector.cs',
        '_sessionLauncher = sessionLauncher;',
        '_sessionLauncher = sessionLauncher;\n        _controllerGate = controllerGate;')
replace('Sessions/ProcessInjector.cs',
        'bool allowConsoleSession = false)',
        'bool allowConsoleSession = false, string? controllerGateDll = null)')
replace('Sessions/ProcessInjector.cs',
        '// Step 4: Launch the process',
        'if (controllerGateDll != null) creationFlags |= 0x00000004; // CREATE_SUSPENDED\n\n'
        '            // Step 4: Launch the process')
replace('Sessions/ProcessInjector.cs',
        '// Close handles we don\'t need\n            Kernel32.CloseHandle(pi.hThread);',
        '''// Install before Apollo can create devices. A failure terminates it
            // instead of silently launching without isolation.
            try
            {
                if (controllerGateDll != null)
                {
                    MultiSeat.Service.Input.ControllerGateInjector.Install(pi.hProcess, pi.dwProcessId, controllerGateDll);
                    (_controllerGate ?? throw new InvalidOperationException("Controller broker missing"))
                        .Register(pi.dwProcessId, sessionId);
                    MultiSeat.Service.Input.ControllerGateInjector.Resume(pi.hThread);
                }
            }
            catch
            {
                Kernel32.TerminateProcess(pi.hProcess, 1);
                Kernel32.CloseHandle(pi.hProcess);
                throw;
            }
            finally { Kernel32.CloseHandle(pi.hThread); }''')
replace('Sessions/ProcessInjector.cs',
        'Path.GetDirectoryName(configPath),\n            ct);',
        'Path.GetDirectoryName(configPath),\n            ct, controllerGateDll: _options.EpicVMControllerGate ? _options.EpicVMControllerGateDll : null);')
replace('Program.cs',
        'builder.Services.AddHostedService<MultiSeatWorker>();',
        'builder.Services.AddSingleton<ControllerGate>();\n'
        'builder.Services.AddHostedService(sp => sp.GetRequiredService<ControllerGate>());\n'
        'builder.Services.AddHostedService<MultiSeatWorker>();')
replace('Streaming/ApolloConfigBuilder.cs',
        'sb.AppendLine("gamepad = auto");',
        'sb.AppendLine(_options.EpicVMControllerGate ? "gamepad = x360" : "gamepad = auto");')
replace('Input/HidHideConfigurator.cs',
        'public void ResetOnStartup()\n    {',
        'public void ResetOnStartup()\n    {\n        if (_options.EpicVMControllerGate) return; // Broker owns its exact journaled rules.')
for name in ('ControllerGate.cs', 'ControllerGateInjector.cs', 'ControllerGatePolicy.cs'):
    shutil.copyfile(Path(__file__).parent / name, service / 'Input' / name)
shutil.copyfile(Path(__file__).parent / 'ControllerGatePolicyTests.cs', root / 'src/MultiSeat.Tests/Input/ControllerGatePolicyTests.cs')
