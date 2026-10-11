param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$compilerRoot = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.44.35207'
$sdkRoot = 'C:\Program Files (x86)\Windows Kits\10'
$sdkVersion = '10.0.26100.0'
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $output | Out-Null
$source = Join-Path $PSScriptRoot 'native\controller_gate.cpp'
& "$compilerRoot\bin\Hostx64\x64\cl.exe" /nologo /std:c++17 /W4 /WX /O2 /MT /LD `
    "/I$compilerRoot\include" "/I$sdkRoot\Include\$sdkVersion\ucrt" `
    "/I$sdkRoot\Include\$sdkVersion\um" "/I$sdkRoot\Include\$sdkVersion\shared" `
    $source "/Fo$output\controller_gate.obj" /link `
    "/LIBPATH:$compilerRoot\lib\x64" "/LIBPATH:$sdkRoot\Lib\$sdkVersion\ucrt\x64" `
    "/LIBPATH:$sdkRoot\Lib\$sdkVersion\um\x64" kernel32.lib advapi32.lib `
    "/OUT:$output\EpicVM.ControllerGate.dll" /DYNAMICBASE /NXCOMPAT
if ($LASTEXITCODE -ne 0) { throw 'Controller gate native build failed' }
