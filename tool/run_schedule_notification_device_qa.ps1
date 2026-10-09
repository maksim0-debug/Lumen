param(
    [Parameter(Mandatory = $true)][string]$DeviceId,
    [string]$AdbPath = "$env:LOCALAPPDATA/Android/sdk/platform-tools/adb.exe"
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$qaRoot = Join-Path $repoRoot 'artifacts/notification-device-qa'
$logRoot = Join-Path $repoRoot 'artifacts/notification-qa'
$packageName = 'ua.maksim0.lumenqa.lumen_notification_qa'
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null

function Assert-CommandSucceeded([string]$Operation) {
    if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE" }
}

Push-Location $repoRoot
try {
    flutter create --platforms android --org ua.maksim0.lumenqa --project-name lumen_notification_qa --no-pub $qaRoot *> "$logRoot/create.log"
    Assert-CommandSucceeded 'Creating isolated QA application'
    @"
name: lumen_notification_qa
publish_to: none
version: 1.0.0+1
environment:
  sdk: '>=3.10.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
  lumen:
    path: '../..'
  firebase_messaging: ^16.7.0
  flutter_local_notifications: 19.5.0
  shared_preferences: ^2.5.4
dev_dependencies:
  flutter_lints: ^2.0.0
flutter:
  uses-material-design: true
"@ | Set-Content -LiteralPath "$qaRoot/pubspec.yaml"
    Copy-Item -LiteralPath "$repoRoot/pubspec.lock" -Destination "$qaRoot/pubspec.lock" -Force
    Copy-Item -LiteralPath "$PSScriptRoot/schedule_notification_device_qa.dart" -Destination "$qaRoot/lib/main.dart" -Force
    # The generated counter example is unrelated to the device QA entry point.
    $counterTest = Join-Path $qaRoot 'test/widget_test.dart'
    if (Test-Path -LiteralPath $counterTest) {
        Remove-Item -LiteralPath $counterTest
    }
    Copy-Item -LiteralPath "$repoRoot/android/gradle/wrapper/gradle-wrapper.properties" -Destination "$qaRoot/android/gradle/wrapper/gradle-wrapper.properties" -Force
    $rootSettings = Get-Content -Raw "$repoRoot/android/settings.gradle"
    $agpVersion = [regex]::Match($rootSettings, 'id "com.android.application" version "([^"]+)"').Groups[1].Value
    $kotlinVersion = [regex]::Match($rootSettings, 'id "org.jetbrains.kotlin.android" version "([^"]+)"').Groups[1].Value
    if (!$agpVersion -or !$kotlinVersion) { throw 'Cannot determine the production Android toolchain' }
    $settingsPath = "$qaRoot/android/settings.gradle.kts"
    $settings = Get-Content -Raw $settingsPath
    $settings = $settings -replace '(id\("com.android.application"\) version )"[^"]+"', ('${1}"' + $agpVersion + '"')
    $settings = $settings -replace '(id\("org.jetbrains.kotlin.android"\) version )"[^"]+"', ('${1}"' + $kotlinVersion + '"')
    Set-Content -LiteralPath $settingsPath -Value $settings
    $appPath = "$qaRoot/android/app/build.gradle.kts"
    $app = Get-Content -Raw $appPath
    if (!$app.Contains('id("org.jetbrains.kotlin.android")')) {
        $app = $app.Replace('id("com.android.application")', 'id("com.android.application")' + "`n    " + 'id("org.jetbrains.kotlin.android")')
    }
    if (!$app.Contains('isCoreLibraryDesugaringEnabled')) {
        $app = $app.Replace('compileOptions {', "compileOptions {`n        isCoreLibraryDesugaringEnabled = true")
        $app += "`n" + 'dependencies { coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4") }'
    }
    Set-Content -LiteralPath $appPath -Value $app
    $manifestPath = "$qaRoot/android/app/src/main/AndroidManifest.xml"
    $manifest = Get-Content -Raw $manifestPath
    if (!$manifest.Contains('android.permission.POST_NOTIFICATIONS')) {
        $manifest = $manifest.Replace('<application', '<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>' + "`n    <application")
        Set-Content -LiteralPath $manifestPath -Value $manifest
    }
    Get-ChildItem -LiteralPath "$qaRoot/android/app/src/main/res" -Filter ic_launcher.png -Recurse | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $_.DirectoryName 'launcher_icon.png') -Force
    }
    Set-Location $qaRoot
    flutter pub get *> "$logRoot/device-pub.log"
    Assert-CommandSucceeded 'Resolving locked QA dependencies'
    flutter analyze *> "$logRoot/device-analyze.log"
    Assert-CommandSucceeded 'Analyzing isolated QA application'
    flutter build apk --debug *> "$logRoot/device-build.log"
    Assert-CommandSucceeded 'Building isolated QA APK'
    & $AdbPath -s $DeviceId install -r "$qaRoot/build/app/outputs/flutter-apk/app-debug.apk"
    Assert-CommandSucceeded 'Installing isolated QA APK'
    $androidSdk = [int](& $AdbPath -s $DeviceId shell getprop ro.build.version.sdk)
    if ($androidSdk -ge 33) {
        & $AdbPath -s $DeviceId shell pm grant $packageName android.permission.POST_NOTIFICATIONS
        Assert-CommandSucceeded 'Granting notifications to isolated QA package'
    }
    & $AdbPath -s $DeviceId shell am force-stop $packageName
    & $AdbPath -s $DeviceId shell am start -n "$packageName/.MainActivity"
    Assert-CommandSucceeded 'Starting QA'
    $deadline = (Get-Date).AddSeconds(90)
    do {
        Start-Sleep -Seconds 2
        $qaProcess = ((& $AdbPath -s $DeviceId shell pidof $packageName).Trim() -split '\s+')[0]
        if (!$qaProcess) { throw 'QA process exited before completion' }
        $results = & $AdbPath -s $DeviceId logcat --pid=$qaProcess -d -s flutter | Select-String 'LUMEN_NOTIFICATION_QA' | ForEach-Object { $_.Line }
        if ($results -match 'LUMEN_NOTIFICATION_QA: FAIL') { throw ($results -join "`n") }
        if ($results -match 'LUMEN_NOTIFICATION_QA: COMPLETE') {
            $results | Set-Content -LiteralPath "$logRoot/device-results.log"
            $results
            return
        }
    } while ((Get-Date) -lt $deadline)
    throw 'QA timed out; inspect the permission prompt and device-build.log'
} finally {
    Pop-Location
}
