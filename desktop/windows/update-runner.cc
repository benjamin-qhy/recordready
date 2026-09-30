#include <windows.h>
#include <string>
#include <fstream>
#include <filesystem>

// Runs from the per-user update cache, never from the installation being replaced.
// Inherits the application environment (including isolated acceptance data roots).
int wmain(int argc, wchar_t** argv) {
  if (argc != 4) return 2;
  const std::wstring installer = argv[2], executable = argv[3];
  const auto directory = std::filesystem::path(executable).parent_path().wstring();
  std::ofstream log(std::filesystem::path(installer + L".log"), std::ios::app);
  auto record = [&](const char* event, DWORD code) { log << event << " " << code << std::endl; };
  const DWORD parentId = wcstoul(argv[1], nullptr, 10);
  if (!parentId || installer.find(L'"') != std::wstring::npos || executable.find(L'"') != std::wstring::npos) return 2;
  HANDLE parent = OpenProcess(SYNCHRONIZE, FALSE, parentId);
  if (!parent) { record("parent-unavailable", GetLastError()); return 3; }
  // The host waits for this acknowledgement before quitting, avoiding an OpenProcess race.
  { std::ofstream ready(std::filesystem::path(installer + L".ready")); ready << "ready"; }
  const DWORD ended = WaitForSingleObject(parent, 60000);
  CloseHandle(parent);
  if (ended != WAIT_OBJECT_0) { record("shutdown-timeout", ended); return 4; }
  auto launch = [&](const std::wstring& file, std::wstring command, PROCESS_INFORMATION& process) {
    STARTUPINFOW startup{}; startup.cb = sizeof(startup);
    return CreateProcessW(file.c_str(), command.data(), nullptr, nullptr, FALSE,
      CREATE_NO_WINDOW, nullptr, directory.c_str(), &startup, &process);
  };
  PROCESS_INFORMATION setup{};
  // /D must be the final, unquoted argument, as required by NSIS.
  if (!launch(installer, L"\"" + installer + L"\" /S /currentuser --updated /D=" + directory, setup)) {
    record("installer-launch-failed", GetLastError()); return 5;
  }
  record("installer-started", setup.dwProcessId);
  CloseHandle(setup.hThread);
  // Full Runtime installation can take several minutes on Windows machines.
  // Do not abandon the restart while NSIS is still extracting dependencies.
  const DWORD completed = WaitForSingleObject(setup.hProcess, 1800000);
  DWORD code = 1;
  GetExitCodeProcess(setup.hProcess, &code);
  CloseHandle(setup.hProcess);
  record("installer-exit", code);
  if (completed != WAIT_OBJECT_0 || code != 0) return 6;
  PROCESS_INFORMATION app{};
  if (!launch(executable, L"\"" + executable + L"\" --updated", app)) {
    record("restart-failed", GetLastError()); return 7;
  }
  record("restarted", app.dwProcessId);
  CloseHandle(app.hThread); CloseHandle(app.hProcess);
  return 0;
}
