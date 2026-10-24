#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shobjidl.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Set the Application User Model ID (AUMID) for the process.
  // This is required for Windows notifications to work correctly (persistence,
  // grouping). This ID must match the one used in the shortcut and MSIX
  // manifest.
  LPCWSTR aumid = L"Maksim0Debug.Lumen.App";
  SetCurrentProcessExplicitAppUserModelID(aumid);

  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  const bool automatic_start =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--autostart") != command_line_arguments.end();

  // Named mutex for single-instance enforcement and installer lifecycle synchronization
  HANDLE hMutex = ::CreateMutexW(nullptr, FALSE, L"Lumen_App_Mutex_maksim0");
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    // A delayed log-in startup must not reveal an already-running window.
    if (!automatic_start) {
      HWND existingHwnd = nullptr;
      // The first instance may still be creating its native window.
      for (int attempt = 0; attempt < 60 && !existingHwnd; ++attempt) {
        existingHwnd = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Люмен");
        if (!existingHwnd) {
          existingHwnd = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Lumen");
        }
        if (!existingHwnd) ::Sleep(50);
      }
      if (existingHwnd) {
        ::AllowSetForegroundWindow(ASFW_ANY);
        ::PostMessageW(existingHwnd, kActivateLumenWindowMessage, 0, 0);
        // Also support a previous Lumen version with no activation handler.
        ActivateLumenWindow(existingHwnd);
      }
    }
    if (hMutex) {
      ::CloseHandle(hMutex);
    }
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin = {10, 10};
  Win32Window::Size size = {900, 600};
  if (!window.Create(L"Lumen", origin, size)) {
    if (hMutex) {
      ::CloseHandle(hMutex);
    }
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  // window_manager 0.4.3 resizes with SetWindowPos without SWP_NOACTIVATE.
  // Center the initial native bounds here so background startup keeps focus.
  RECT bounds{};
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  const HWND hwnd = window.GetHandle();
  const HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  if (::GetWindowRect(hwnd, &bounds) &&
      ::GetMonitorInfoW(monitor, &monitor_info)) {
    const RECT& work = monitor_info.rcWork;
    const int x = work.left + ((work.right - work.left) -
                               (bounds.right - bounds.left)) / 2;
    const int y = work.top + ((work.bottom - work.top) -
                              (bounds.bottom - bounds.top)) / 2;
    ::SetWindowPos(hwnd, nullptr, x, y, 0, 0,
                   SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (hMutex) {
    ::CloseHandle(hMutex);
  }
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
