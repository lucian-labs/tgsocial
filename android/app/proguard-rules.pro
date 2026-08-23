# tgsocial — minify is off for 1.0; rules kept for when it turns on.
# TDLib's consumer rules (org.drinkless.tdlib.JsonClient natives) ship inside the tdl-coroutines AAR.
-keepattributes Signature, InnerClasses, EnclosingMethod
-keep class ca.lucianlabs.tgsocial.BuildConfig { *; }
# kotlinx.serialization
-keepclassmembers class ca.lucianlabs.tgsocial.** {
    *** Companion;
}
-keepclasseswithmembers class ca.lucianlabs.tgsocial.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-dontwarn org.slf4j.**
