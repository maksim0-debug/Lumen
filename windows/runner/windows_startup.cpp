#include "windows_startup.h"

#include <appmodel.h>
#include <flutter/standard_method_codec.h>
#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Windows.Foundation.h>

namespace {
using flutter::EncodableValue;
using Result = flutter::MethodResult<EncodableValue>;
using winrt::Windows::ApplicationModel::StartupTask;
using winrt::Windows::ApplicationModel::StartupTaskState;
using winrt::Windows::Foundation::AsyncStatus;
using winrt::Windows::Foundation::IAsyncOperation;

void ReplyState(const std::shared_ptr<Result>& result, StartupTaskState state) {
  switch (state) {
    case StartupTaskState::Enabled:
      result->Success(EncodableValue("enabled"));
      break;
    case StartupTaskState::EnabledByPolicy:
      result->Success(EncodableValue("enabledByPolicy"));
      break;
    case StartupTaskState::Disabled:
      result->Success(EncodableValue("disabled"));
      break;
    case StartupTaskState::DisabledByUser:
      result->Success(EncodableValue("disabledByUser"));
      break;
    case StartupTaskState::DisabledByPolicy:
      result->Success(EncodableValue("disabledByPolicy"));
      break;
    default:
      result->Error("startup_unknown_state", "Unknown Windows startup state");
  }
}

void HandleStartupTask(bool update, bool enabled,
                       const std::shared_ptr<Result>& result) {
  try {
    // Async WinRT operations must not block Flutter's platform thread.
    StartupTask::GetAsync(L"LumenStartup").Completed(
        [result, update, enabled](const IAsyncOperation<StartupTask>& operation,
                                  AsyncStatus) {
          try {
            const auto task = operation.GetResults();
            if (!update) {
              ReplyState(result, task.State());
            } else if (!enabled) {
              task.Disable();
              ReplyState(result, task.State());
            } else if (task.State() == StartupTaskState::DisabledByUser) {
              result->Error("startup_disabled_by_user",
                            "Enable Lumen in Windows Startup Apps settings");
            } else if (task.State() == StartupTaskState::DisabledByPolicy) {
              result->Error("startup_disabled_by_policy",
                            "Windows policy prevents startup");
            } else {
              task.RequestEnableAsync().Completed(
                  [result](const IAsyncOperation<StartupTaskState>& request,
                           AsyncStatus) {
                    try {
                      ReplyState(result, request.GetResults());
                    } catch (const winrt::hresult_error& error) {
                      result->Error("startup_failed",
                                    winrt::to_string(error.message()));
                    }
                  });
            }
          } catch (const winrt::hresult_error& error) {
            result->Error("startup_failed", winrt::to_string(error.message()));
          }
        });
  } catch (const winrt::hresult_error& error) {
    result->Error("startup_failed", winrt::to_string(error.message()));
  }
}
}  // namespace

void ActivateLumenWindow(HWND window) {
  ::ShowWindow(window, SW_RESTORE);
  // STARTUPINFO can override the first ShowWindow call (for example when a
  // launcher requests a hidden window). Explicitly reveal a manual activation.
  ::SetWindowPos(window, HWND_TOP, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
  ::SetForegroundWindow(window);
}

std::unique_ptr<flutter::MethodChannel<EncodableValue>>
CreateWindowsStartupChannel(flutter::BinaryMessenger* messenger, HWND window,
                            const bool* manually_activated) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "lumen/windows_startup",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [window, manually_activated](const flutter::MethodCall<EncodableValue>& call,
               std::unique_ptr<Result> result) {
        if (call.method_name() == "showNormal") {
          ActivateLumenWindow(window);
          result->Success();
          return;
        }
        if (call.method_name() == "applyAutomaticStartupMode") {
          const auto mode = call.arguments()
                                ? std::get_if<std::string>(call.arguments())
                                : nullptr;
          if (!mode || (*mode != "tray" && *mode != "minimized")) {
            result->Error("invalid_arguments", "Expected tray or minimized");
            return;
          }
          // A manual activation received while Dart initializes takes priority
          // over the pending automatic startup, regardless of message order.
          if (*manually_activated) {
            ActivateLumenWindow(window);
          } else {
            // window_manager.show() restores and focuses first. Show minimized
            // directly to avoid a normal-window flash or stealing focus.
            ::ShowWindow(window, *mode == "tray" ? SW_HIDE : SW_SHOWMINNOACTIVE);
          }
          result->Success();
          return;
        }
        if (call.method_name() != "getStartupState" &&
            call.method_name() != "setStartupEnabled") {
          result->NotImplemented();
          return;
        }
        UINT32 length = 0;
        const LONG package_status = ::GetCurrentPackageFullName(&length, nullptr);
        if (package_status == APPMODEL_ERROR_NO_PACKAGE) {
          result->Success();
          return;
        }
        if (package_status != ERROR_INSUFFICIENT_BUFFER) {
          result->Error("startup_failed", "Cannot determine package identity");
          return;
        }
        const bool update = call.method_name() == "setStartupEnabled";
        const auto enabled = call.arguments()
                                 ? std::get_if<bool>(call.arguments())
                                 : nullptr;
        if (update && !enabled) {
          result->Error("invalid_arguments", "Expected a boolean");
          return;
        }
        HandleStartupTask(update, enabled && *enabled,
                          std::shared_ptr<Result>(std::move(result)));
      });
  return channel;
}
