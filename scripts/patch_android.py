"""Adjusts the Android project that `flutter create` generates during CI.

Fails loudly (exit 1) if an expected spot isn't found, so a template change
shows up as a clear build error instead of a broken app.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent / "android"
MANIFEST = ROOT / "app/src/main/AndroidManifest.xml"

PERMISSIONS = [
    "android.permission.INTERNET",
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_DATA_SYNC",
]

# Foreground service from flutter_local_notifications: keeps the app's network
# alive while uploads / AI calls run with the app in the background.
SERVICE = (
    '        <service\n'
    '            android:name="com.dexterous.flutterlocalnotifications.ForegroundService"\n'
    '            android:exported="false"\n'
    '            android:stopWithTask="false"\n'
    '            android:foregroundServiceType="dataSync" />\n'
)


def fail(msg: str) -> None:
    print(f"patch_android: {msg}", file=sys.stderr)
    sys.exit(1)


def patch_manifest() -> None:
    text = MANIFEST.read_text()
    for perm in PERMISSIONS:
        if perm not in text:
            text = text.replace(
                "<application",
                f'<uses-permission android:name="{perm}"/>\n    <application',
                1,
            )
    if "flutterlocalnotifications.ForegroundService" not in text:
        if "</application>" not in text:
            fail("no </application> in manifest")
        text = text.replace("</application>", SERVICE + "    </application>", 1)
    text = text.replace('android:label="receipt_tracker"', 'android:label="Receipts"')
    MANIFEST.write_text(text)


def patch_gradle() -> None:
    kts = ROOT / "app/build.gradle.kts"
    groovy = ROOT / "app/build.gradle"
    path = kts if kts.exists() else groovy
    if not path.exists():
        fail("no app build.gradle(.kts)")
    text = path.read_text()
    is_kts = path.suffix == ".kts"

    # minSdk 26 (Android 8+).
    text, n = re.subn(r"minSdk(?:Version)?\s*=?\s*flutter\.minSdkVersion", "minSdk = 26", text)
    if n == 0 and "minSdk = 26" not in text:
        fail("could not set minSdk")

    # Java 17 (required by flutter_local_notifications).
    text = text.replace("VERSION_11", "VERSION_17").replace("JVM_11", "JVM_17")
    text = re.sub(r'jvmTarget\s*=\s*"11"', 'jvmTarget = "17"', text)

    # Core library desugaring (required by flutter_local_notifications).
    if "CoreLibraryDesugaringEnabled" not in text and "coreLibraryDesugaringEnabled" not in text:
        flag = "isCoreLibraryDesugaringEnabled = true" if is_kts else "coreLibraryDesugaringEnabled true"
        text, n = re.subn(r"compileOptions\s*\{", "compileOptions {\n        " + flag, text, count=1)
        if n == 0:
            fail("no compileOptions block")
    if "desugar_jdk_libs" not in text:
        dep = (
            'coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")'
            if is_kts
            else "coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'"
        )
        text += "\ndependencies {\n    " + dep + "\n}\n"
    path.write_text(text)


if __name__ == "__main__":
    patch_manifest()
    patch_gradle()
    print(MANIFEST.read_text())
    gradle = ROOT / "app/build.gradle.kts"
    print((gradle if gradle.exists() else ROOT / "app/build.gradle").read_text())
