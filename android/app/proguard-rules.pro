# Ignore missing Play Core classes (not used, but referenced by Flutter)
-dontwarn com.google.android.play.core.splitcompat.**
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**

# Ignore missing javax.xml.stream (not used on Android)
-dontwarn javax.xml.stream.**

# The Go backend and FFmpeg plugin ship their JNI keep rules in their AARs.

# Keep native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Kotlin coroutines - expanded rules
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}
-keepclassmembers class kotlinx.coroutines.** {
    volatile <fields>;
}
-keepclassmembernames class kotlinx.** {
    volatile <fields>;
}
-dontwarn kotlinx.coroutines.**

# Runtime annotations used by serializers and generated bindings.
-keepattributes RuntimeVisibleAnnotations,AnnotationDefault
-dontwarn kotlin.**

# Android instantiates these components from the manifest. Preserve only their
# names and constructors; normal reachability can now shrink/optimize helpers,
# coroutine state machines, and unused members in the rest of the app package.
-keep,allowoptimization class com.zarz.spotiflac.MainActivity {
    public <init>();
}
-keep,allowoptimization class com.zarz.spotiflac.DownloadService {
    public <init>();
}
-keep,allowoptimization class com.zarz.spotiflac.DownloadQueueWidgetProvider {
    public <init>();
}

# Flutter's fragment builders instantiate this class through reflection.
-keep,allowoptimization class com.zarz.spotiflac.MainActivity$ImpellerAwareFlutterFragment {
    public <init>();
}

# Prevent R8 from removing metadata
-keepattributes *Annotation*
-keepattributes SourceFile,LineNumberTable
-keepattributes Signature
-keepattributes Exceptions
-keepattributes InnerClasses
-keepattributes EnclosingMethod

# Flutter invokes the generated registrant by name. Individual plugins are
# referenced by this class and retain their own consumer rules.
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }
