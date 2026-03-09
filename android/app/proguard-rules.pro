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
