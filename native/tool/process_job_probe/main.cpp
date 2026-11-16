#include "../../windows/runner/owned_process_job.h"
#include <chrono>
#include <cstdio>
#include <string>
#include <thread>

std::wstring Quote(const std::wstring& value) {
  std::wstring out = L"\"";
  size_t slashes = 0;
  for (const auto c : value) {
    if (c == L'\\') { ++slashes; continue; }
    if (c == L'\"') {
      out.append(slashes * 2 + 1, L'\\');
    } else {
      out.append(slashes, L'\\');
    }
    slashes = 0;
    out += c;
  }
  out.append(slashes * 2, L'\\');
  return out + L'\"';
}

int wmain(int argc, wchar_t** argv) {
  if (argc < 5 || !InitializeOwnedProcessJob()) {
    std::fprintf(stderr, "Cannot initialize process job: %lu\n", GetLastError());
    return 1;
  }
  std::wstring command;
  for (int i = 3; i < argc; ++i) command += Quote(argv[i]) + L" ";
  STARTUPINFOW startup{};
  startup.cb = static_cast<DWORD>(sizeof(startup));
  startup.dwFlags = STARTF_USESTDHANDLES;
  startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
  startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
  startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
  PROCESS_INFORMATION child{};
  if (!CreateProcessW(argv[3], command.data(), nullptr, nullptr, TRUE,
                      CREATE_NO_WINDOW, nullptr, nullptr, &startup, &child)) {
    std::fprintf(stderr, "Cannot start Dart child: %lu\n", GetLastError());
    return 2;
  }
  CloseHandle(child.hThread);
  const std::wstring go = std::wstring(argv[2]) + L".go";
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
  while (GetFileAttributesW(go.c_str()) == INVALID_FILE_ATTRIBUTES) {
    if (std::chrono::steady_clock::now() > deadline ||
        WaitForSingleObject(child.hProcess, 0) == WAIT_OBJECT_0) {
      std::fprintf(stderr, "Dart did not start its FFmpeg child\n");
      CloseHandle(child.hProcess);
      return 3;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  const std::wstring mode = argv[1];
  if (mode == L"window-close") StopOwnedChildProcesses();
  if (mode == L"crash") TerminateProcess(GetCurrentProcess(), 17);
  CloseHandle(child.hProcess);
  // Normal exit relies on the kernel closing the job, not a Dart finally block.
  return 0;
}
