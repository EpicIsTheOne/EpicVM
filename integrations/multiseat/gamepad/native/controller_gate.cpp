// EpicVM controller ownership gate. Only allocation passes through the broker;
// input reports and vibration keep Apollo's original path.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winioctl.h>
#include <cstring>

using Io = decltype(&DeviceIoControl);
static Io original;
static bool installed;
constexpr DWORD plugin = CTL_CODE(0x2a, 0x801, METHOD_BUFFERED, FILE_WRITE_DATA);
constexpr DWORD unplug = CTL_CODE(0x2a, 0x802, METHOD_BUFFERED, FILE_WRITE_DATA);
struct Target { ULONG size, serial, type; USHORT vid, pid; };
struct Request { DWORD magic, command, serial; };
static_assert(sizeof(Target) == 16);

static DWORD request(DWORD command, DWORD serial) {
    Request message{0x45564731, command, serial};
    DWORD reply = 2, received = 0;
    const auto pipeName = L"\\\\.\\pipe\\EpicVM.ControllerGate.v1";
    if (!WaitNamedPipeW(pipeName, 5000)) return 2;
    HANDLE pipe = CreateFileW(pipeName, GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
    if (pipe == INVALID_HANDLE_VALUE) return 2;
    // A local user could create a pipe with our name. Trust only the process
    // currently registered by Windows SCM for the installed MultiSeat service.
    ULONG serverPid = 0;
    SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
    SC_HANDLE service = manager ? OpenServiceW(manager, L"MultiSeatService", SERVICE_QUERY_STATUS) : nullptr;
    SERVICE_STATUS_PROCESS status{};
    DWORD required = 0;
    bool trusted = service && GetNamedPipeServerProcessId(pipe, &serverPid) &&
        QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO, reinterpret_cast<BYTE*>(&status), sizeof(status), &required) &&
        status.dwCurrentState == SERVICE_RUNNING && status.dwProcessId == serverPid;
    if (service) CloseServiceHandle(service);
    if (manager) CloseServiceHandle(manager);
    if (trusted && WriteFile(pipe, &message, sizeof(message), &received, nullptr) && received == sizeof(message)) {
        if (!ReadFile(pipe, &reply, sizeof(reply), &received, nullptr) || received != sizeof(reply)) reply = 2;
    }
    CloseHandle(pipe);
    return reply;
}

static BOOL reject(LPOVERLAPPED overlapped, DWORD error) {
    if (overlapped) {
        overlapped->Internal = static_cast<ULONG_PTR>(0xc0000022); // STATUS_ACCESS_DENIED
        overlapped->InternalHigh = 0;
        if (overlapped->hEvent) SetEvent(overlapped->hEvent);
    }
    SetLastError(error);
    return FALSE;
}

static BOOL WINAPI gated(HANDLE device, DWORD code, LPVOID input, DWORD inputSize,
    LPVOID output, DWORD outputSize, LPDWORD bytes, LPOVERLAPPED overlapped) {
    if (code != plugin)
        return original(device, code, input, inputSize, output, outputSize, bytes, overlapped);
    if (!input || inputSize != sizeof(Target)) return reject(overlapped, ERROR_INVALID_PARAMETER);
    auto target = *static_cast<Target*>(input);
    if (target.size != sizeof(Target) || target.type != 0 || target.vid != 0x045e || target.pid != 0x028e)
        return reject(overlapped, ERROR_NOT_SUPPORTED);
    DWORD verdict = request(1, target.serial);
    if (verdict != 0) return reject(overlapped, verdict == 1 ? ERROR_INVALID_PARAMETER : ERROR_ACCESS_DENIED);

    BOOL result = original(device, code, input, inputSize, output, outputSize, bytes, overlapped);
    DWORD transferred = 0;
    if (!result && GetLastError() == ERROR_IO_PENDING && overlapped)
        result = GetOverlappedResult(device, overlapped, &transferred, TRUE);
    if (!result) return FALSE;
    if (request(2, target.serial) != 0) {
        struct { ULONG size, serial; } removal{8, target.serial};
        OVERLAPPED rollback{};
        rollback.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        original(device, unplug, &removal, sizeof(removal), nullptr, 0, &transferred, &rollback);
        GetOverlappedResult(device, &rollback, &transferred, TRUE);
        if (rollback.hEvent) CloseHandle(rollback.hEvent);
        return reject(overlapped, ERROR_ACCESS_DENIED);
    }
    return TRUE;
}

static bool patch() {
    auto base = reinterpret_cast<BYTE*>(GetModuleHandleW(nullptr));
    auto dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    auto nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
    auto dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!dir.VirtualAddress) return false;
    auto descriptor = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(base + dir.VirtualAddress);
    for (; descriptor->Name; ++descriptor) {
        if (!descriptor->OriginalFirstThunk) continue;
        auto names = reinterpret_cast<IMAGE_THUNK_DATA*>(base + descriptor->OriginalFirstThunk);
        auto slots = reinterpret_cast<IMAGE_THUNK_DATA*>(base + descriptor->FirstThunk);
        for (; names->u1.AddressOfData; ++names, ++slots) {
            if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
            auto name = reinterpret_cast<IMAGE_IMPORT_BY_NAME*>(base + names->u1.AddressOfData);
            if (std::strcmp(reinterpret_cast<char*>(name->Name), "DeviceIoControl")) continue;
            DWORD protection;
            if (!VirtualProtect(&slots->u1.Function, sizeof(ULONG_PTR), PAGE_READWRITE, &protection)) return false;
            original = reinterpret_cast<Io>(slots->u1.Function);
            InterlockedExchangePointer(reinterpret_cast<PVOID*>(&slots->u1.Function), reinterpret_cast<PVOID>(gated));
            DWORD ignored;
            VirtualProtect(&slots->u1.Function, sizeof(ULONG_PTR), protection, &ignored);
            return true;
        }
    }
    return false;
}

extern "C" __declspec(dllexport) DWORD WINAPI EpicVMGateStatus(LPVOID) {
    return installed ? 0x45564731 : 0;
}

BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
        installed = patch();
    }
    return TRUE;
}
