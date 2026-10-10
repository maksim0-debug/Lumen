"""Build a separate Android QA package from the current Lumen implementation."""
import json
from pathlib import Path
import shutil
import subprocess
import uuid
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
QA = ROOT / "artifacts/snapshot-device-qa"


def main():
    flutter = shutil.which("flutter")
    if flutter is None:
        raise RuntimeError("Flutter must be on PATH")
    if not QA.exists():
        subprocess.run([flutter, "create", "--platforms", "android", "--org",
                        "ua.maksim0.lumenqa", "--project-name", "lumen_snapshot_qa",
                        "--no-pub", str(QA)], check=True, cwd=ROOT)
    (QA / "pubspec.yaml").write_text("""name: lumen_snapshot_qa
publish_to: none
version: 1.0.0+1
environment:
  sdk: ^3.8.0
dependencies:
  flutter:
    sdk: flutter
  lumen:
    path: ../..
flutter:
  uses-material-design: true
""")
    shutil.copyfile(ROOT / "pubspec.lock", QA / "pubspec.lock")
    shutil.copyfile(ROOT / "tool/schedule_snapshot_device_qa.dart", QA / "lib/harness.dart")
    (QA / "lib/main.dart").write_text("import 'harness.dart';\nvoid main() => runSnapshotQa();\n")
    (QA / "test/widget_test.dart").unlink(missing_ok=True)
    android = QA / "android"
    for name in ("settings.gradle", "build.gradle", "gradle.properties"):
        shutil.copyfile(ROOT / "android" / name, android / name)
    (android / "settings.gradle.kts").unlink(missing_ok=True)
    with (android / "gradle.properties").open("a") as file:
        file.write("\nkotlin.incremental=false\n")
    shutil.copyfile(ROOT / "android/gradle/wrapper/gradle-wrapper.properties",
                    android / "gradle/wrapper/gradle-wrapper.properties")
    build = (ROOT / "android/app/build.gradle").read_text()
    build = build.replace('    id "com.google.gms.google-services"\n', "")
    build = build.replace('applicationId "ua.maksim0.lumen"',
                          'applicationId "ua.maksim0.lumenqa.lumen_snapshot_qa"')
    (android / "app/build.gradle").write_text(build)
    (android / "app/build.gradle.kts").unlink(missing_ok=True)
    native = android / "app/src/main"
    shutil.copytree(ROOT / "android/app/src/main/res", native / "res", dirs_exist_ok=True)
    shutil.copytree(ROOT / "android/app/src/main/kotlin/ua/maksim0/lumen",
                    native / "kotlin/ua/maksim0/lumen", dirs_exist_ok=True)
    java = native / "java/ua/maksim0/lumen"
    java.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / "android/app/src/main/java/ua/maksim0/lumen/MainActivity.java",
                    java / "MainActivity.java")
    shutil.copyfile(ROOT / "tool/SnapshotQaActivity.java", java / "SnapshotQaActivity.java")
    manifest = (ROOT / "android/app/src/main/AndroidManifest.xml").read_text()
    manifest = manifest.replace('android:label="@string/app_name"',
                                'android:label="Lumen snapshot QA"')
    manifest = manifest.replace('android:name=".MainActivity"',
                                'android:name="ua.maksim0.lumen.SnapshotQaActivity"')
    for i in range(1, 13):
        suffix = "" if i == 1 else str(i)
        manifest = manifest.replace(f'android:name=".LightScheduleWidgetProvider{suffix}"',
                                    f'android:name="ua.maksim0.lumen.LightScheduleWidgetProvider{suffix}"')
    (native / "AndroidManifest.xml").write_text(manifest)
    config = json.loads((ROOT / "android/app/google-services.json").read_text())
    client, project = config["client"][0], config["project_info"]
    # Public Firebase client configuration, not service-account/admin credentials.
    values = {"google_app_id": client["client_info"]["mobilesdk_app_id"],
              "google_api_key": client["api_key"][0]["current_key"],
              "gcm_defaultSenderId": project["project_number"],
              "project_id": project["project_id"],
              "google_storage_bucket": project["storage_bucket"]}
    (native / "res/values/firebase_qa.xml").write_text("<resources>" + "".join(
        f'<string name="{key}" translatable="false">{escape(value)}</string>'
        for key, value in values.items()) + "</resources>")
    topic = "lumen_snapshot_qa_" + uuid.uuid4().hex
    output = QA
    output.mkdir(parents=True, exist_ok=True)
    (output / "snapshot-qa-topic.txt").write_text(topic)
    subprocess.run([flutter, "pub", "get"], check=True, cwd=QA)
    subprocess.run([flutter, "build", "apk", "--debug", "--dart-define=QA_TOPIC=" + topic],
                   check=True, cwd=QA)
    print("QA APK built. Install it as the separate package described in docs/schedule-push-sync.md")


if __name__ == "__main__":
    main()
