#ifndef PIRATE_OWNED_PROCESS_JOB_H_
#define PIRATE_OWNED_PROCESS_JOB_H_

#include <windows.h>
#include <vector>

// The job contains this application and only its descendants. The handle is
// deliberately kept until ExitProcess: closing it earlier would kill us too.
// Kernel handle cleanup also covers Task Manager, a crash, and a failed engine.
inline HANDLE& OwnedProcessJobHandle() {
  static HANDLE job = nullptr;
  return job;
}

inline bool InitializeOwnedProcessJob() {
  if (OwnedProcessJobHandle()) return true;
  HANDLE job = CreateJobObjectW(nullptr, nullptr);
  if (!job) return false;
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                              &limits, sizeof(limits)) ||
      !AssignProcessToJobObject(job, GetCurrentProcess())) {
    const DWORD error = GetLastError();
    CloseHandle(job);
    SetLastError(error);
    return false;
  }
  OwnedProcessJobHandle() = job;
  return true;
}

// Stop children before Flutter tears down its engine. Check job membership on
// the opened handle so a reused PID can never kill an unrelated application.
inline void StopOwnedChildProcesses() {
  HANDLE job = OwnedProcessJobHandle();
  if (!job) return;
  std::vector<unsigned char> storage(4096);
  for (;;) {
    auto* list = reinterpret_cast<JOBOBJECT_BASIC_PROCESS_ID_LIST*>(storage.data());
    if (QueryInformationJobObject(job, JobObjectBasicProcessIdList, list,
                                 static_cast<DWORD>(storage.size()), nullptr)) {
      for (DWORD i = 0; i < list->NumberOfProcessIdsInList; ++i) {
        const DWORD pid = static_cast<DWORD>(list->ProcessIdList[i]);
        if (pid == GetCurrentProcessId()) continue;
        HANDLE process = OpenProcess(PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION,
                                     FALSE, pid);
        if (!process) continue;
        BOOL member = FALSE;
        if (IsProcessInJob(process, job, &member) && member) {
          TerminateProcess(process, 0);
        }
        CloseHandle(process);
      }
      return;
    }
    if (GetLastError() != ERROR_MORE_DATA || storage.size() >= 1024 * 1024) return;
    storage.resize(storage.size() * 2);
  }
}

#endif
