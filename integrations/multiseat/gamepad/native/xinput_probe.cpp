#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <Xinput.h>
#include <cstdio>
#include <cstdlib>
#include <string>

int wmain() {
    wchar_t directory[32768];
    if (!GetEnvironmentVariableW(L"LOCALAPPDATA", directory, 32768)) return 1;
    auto path = std::wstring(directory) + L"\\epicvm-xinput-native.json";
    DWORD session = 0;
    ProcessIdToSessionId(GetCurrentProcessId(), &session);
    for (int attempt = 0; attempt < 600; ++attempt) {
        FILE* file = nullptr;
        if (_wfopen_s(&file, path.c_str(), L"wb") != 0) return 2;
        fprintf(file, "{\"session\":%lu,\"sample\":%d,\"pads\":[", session, attempt);
        bool first = true;
        for (DWORD index = 0; index < 4; ++index) {
            XINPUT_STATE state{};
            if (XInputGetState(index, &state) != ERROR_SUCCESS) continue;
            auto& pad = state.Gamepad;
            fprintf(file, "%s{\"index\":%lu,\"packet\":%lu,\"buttons\":%u,\"lt\":%u,\"rt\":%u,\"lx\":%d,\"ly\":%d,\"rx\":%d,\"ry\":%d}",
                first ? "" : ",", index, state.dwPacketNumber, pad.wButtons, pad.bLeftTrigger, pad.bRightTrigger,
                pad.sThumbLX, pad.sThumbLY, pad.sThumbRX, pad.sThumbRY);
            first = false;
        }
        fprintf(file, "]}");
        fclose(file);
        Sleep(500);
    }
    return 0;
}
