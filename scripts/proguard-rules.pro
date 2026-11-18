# Copied to android/app/proguard-rules.pro during the build.
#
# ML Kit (document scanner) looks some of its classes up at runtime; the
# release shrinker (R8) removed them, so the scanner crashed with a
# NullPointerException in GmsDocumentScanning.getClient. Keep them.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_document_scanner.** { *; }
-keep class com.google.android.gms.internal.mlkit_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class com.google.android.gms.common.internal.** { *; }

# ML Kit / Firebase component discovery creates these by name.
-keep class * implements com.google.firebase.components.ComponentRegistrar { <init>(); }
-keep class com.google.firebase.components.** { *; }

# Notifications plugin stores scheduled data with Gson.
-keep class com.dexterous.** { *; }
-keepattributes Signature, *Annotation*
