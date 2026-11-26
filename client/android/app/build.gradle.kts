plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigning = listOf(
    "ANDROID_KEYSTORE_PATH",
    "ANDROID_STORE_PASSWORD",
    "ANDROID_KEY_ALIAS",
    "ANDROID_KEY_PASSWORD",
).associateWith { providers.environmentVariable(it).orNull?.takeIf(String::isNotBlank) }
val hasReleaseSigning = releaseSigning.values.any { it != null }
if (hasReleaseSigning) {
    val missing = releaseSigning.filterValues { it == null }.keys
    require(missing.isEmpty()) { "Missing Android release signing settings: ${missing.joinToString()}" }
}

android {
    namespace = "dev.pyvis.pyvis_editor"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.pyvis.pyvis_editor"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    if (hasReleaseSigning) {
        signingConfigs.create("production") {
            storeFile = file(releaseSigning.getValue("ANDROID_KEYSTORE_PATH")!!)
            storePassword = releaseSigning.getValue("ANDROID_STORE_PASSWORD")
            keyAlias = releaseSigning.getValue("ANDROID_KEY_ALIAS")
            keyPassword = releaseSigning.getValue("ANDROID_KEY_PASSWORD")
        }
    }

    buildTypes {
        release {
            // Keep local release-mode development available without publishing credentials.
            signingConfig = signingConfigs.getByName(if (hasReleaseSigning) "production" else "debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// Flutter's Android packager stages only files beneath flutter_assets.
// Copy the shared examples from the repository into Android assets.
val exampleAssets = layout.buildDirectory.dir("generated/pyvisExampleAssets")
val stageExamples = tasks.register<Sync>("stagePyvisExamples") {
    from(rootProject.file("../../examples")) {
        include("**/*.py")
        into("examples")
    }
    into(exampleAssets)
}
android.sourceSets.getByName("main").assets.srcDir(exampleAssets.get().asFile)
tasks.named("preBuild").configure { dependsOn(stageExamples) }

val pythonBundle = layout.buildDirectory.dir("generated/embeddedPython").get().asFile
val pythonTools = rootProject.file("../../tools")
val androidNdk = androidComponents.sdkComponents.ndkDirectory
val stagePython = tasks.register<Exec>("stagePyvisPython") {
    inputs.files(pythonTools.resolve("bundle_python.py"), pythonTools.resolve("android_python.c"))
    inputs.dir(rootProject.file("../../runtime/pyvis_runtime"))
    inputs.property("ndkVersion", android.ndkVersion ?: "")
    outputs.dir(pythonBundle)
    doFirst {
        commandLine(if (System.getProperty("os.name").startsWith("Windows")) "python" else "python3",
            pythonTools.resolve("bundle_python.py"), "android", pythonBundle, androidNdk.get().asFile)
    }
}
android.defaultConfig.ndk.abiFilters.addAll(listOf("arm64-v8a", "x86_64"))
android.packaging.jniLibs.useLegacyPackaging = true
android.sourceSets.getByName("main").apply {
    assets.srcDir(pythonBundle.resolve("assets"))
    jniLibs.srcDir(pythonBundle.resolve("jniLibs"))
}
tasks.named("preBuild").configure { dependsOn(stagePython) }
