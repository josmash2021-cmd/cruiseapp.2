# Stripe push provisioning classes (referenced by React Native bridge but not used in Flutter)
-dontwarn com.stripe.android.pushProvisioning.**
-dontwarn com.reactnativestripesdk.pushprovisioning.**
-keep class com.stripe.android.pushProvisioning.** { *; }

# Google ML Kit text recognition — keep all language-specific recognizer classes
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
-keep class com.google.mlkit.vision.text.** { *; }

# Jackson / SLF4J — referenced by Stripe Terminal but not available on Android
-dontwarn java.beans.ConstructorProperties
-dontwarn java.beans.Transient
-dontwarn org.slf4j.impl.StaticLoggerBinder
-dontwarn org.slf4j.impl.StaticMDCBinder

# ── R8 full-mode keeps (2026-10-17, R8 re-enabled locally; Codemagic's 8 GB
# builder OOM'd on it 2026-09-05 — the store AAB with R8 is built locally).
# Method channels and plugin registration use reflection: keep the bridge.

# Flutter engine + embedding
-keep class io.flutter.** { *; }
-dontwarn io.flutter.**
# Every plugin entry point (FlutterPlugin / ActivityAware / method channels)
-keep class ** implements io.flutter.embedding.engine.plugins.FlutterPlugin { *; }
-keep class ** implements io.flutter.embedding.engine.plugins.activity.ActivityAware { *; }
-keep class ** implements io.flutter.plugin.common.PluginRegistry** { *; }
-keep class ** extends io.flutter.embedding.android.FlutterActivity { *; }
-keep class ** extends io.flutter.embedding.android.FlutterFragmentActivity { *; }

# Firebase / Play services
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.android.gms.**
-keep class com.google.android.play.core.** { *; }

# Mapbox
-keep class com.mapbox.** { *; }
-dontwarn com.mapbox.**

# ML Kit (face detection + text recognition)
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**

# Stripe (SDK + Terminal)
-keep class com.stripe.** { *; }
-dontwarn com.stripe.**

# Geolocator / camera / audioplayers and the rest ship consumer rules of
# their own; these keep their entry classes regardless.
-keep class com.baseflow.** { *; }
-keep class io.github.ponnamkarthik.toast.fluttertoast.** { *; }
-keep class xyz.luan.audioplayers.** { *; }
-keep class io.flutter.plugins.camera.** { *; }
-keep class com.bugsnag.** { *; }
-keep class io.sentry.** { *; }
