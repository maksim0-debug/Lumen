#ifndef RUNNER_WINDOWS_STARTUP_H_
#define RUNNER_WINDOWS_STARTUP_H_

#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <windows.h>

#include <memory>

constexpr UINT kActivateLumenWindowMessage = WM_APP + 73;

void ActivateLumenWindow(HWND window);

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateWindowsStartupChannel(flutter::BinaryMessenger* messenger, HWND window,
                            const bool* manually_activated);

#endif  // RUNNER_WINDOWS_STARTUP_H_
