plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

import java.util.Properties

flutter {
    source = "../.."
}

android {
    namespace = "com.cruiseinride.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    packaging {
        resources {
            excludes += "META-INF/DEPENDENCIES"
            // Stripe Terminal SDK pulls in BouncyCastle indirectly which
            // collides with another transitive dep. Pick the first copy
            // of these property files so the build doesn't fail with
            // "Duplicate file" errors.
            // https://github.com/stripe/stripe-terminal-android/issues/349
            pickFirsts += "org/bouncycastle/x509/CertPathReviewerMessages.properties"
            pickFirsts += "org/bouncycastle/x509/CertPathReviewerMessages_de.properties"
        }
    }

    // Exclude the bcprov-jdk15to18 module — Stripe Terminal already ships
    // a different BouncyCastle artifact and keeping both causes duplicate
    // class errors at compile time.
    configurations.all {
        exclude(group = "org.bouncycastle", module = "bcprov-jdk15to18")
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    // Release keystore — reads from key.properties (local) or CI env vars
    val keyProps = Properties()
    val keyPropsFile = rootProject.file("key.properties")
    if (keyPropsFile.exists()) {
        keyPropsFile.reader(Charsets.UTF_8).use { keyProps.load(it) }
    }

    // Local key.properties takes priority, then CI env vars
    val ksFilePath = keyProps.getProperty("storeFile")
        ?: System.getenv("CM_KEYSTORE_PATH")
        ?: "/tmp/cruise-release.keystore"
    val ksFile = file(ksFilePath)
    val ksPassword = keyProps.getProperty("storePassword")
        ?: System.getenv("CM_KEYSTORE_PASSWORD") ?: ""
    val keyAlias = keyProps.getProperty("keyAlias")
        ?: System.getenv("CM_KEY_ALIAS") ?: ""
    val keyPass = keyProps.getProperty("keyPassword")
        ?: System.getenv("CM_KEY_PASSWORD") ?: ""
    val hasKeystore = ksFile.exists() && ksPassword.isNotEmpty() && keyAlias.isNotEmpty()

    signingConfigs {
        if (hasKeystore) {
            create("release") {
                storeFile     = ksFile
                storePassword = ksPassword
                this.keyAlias = keyAlias
                keyPassword   = keyPass
            }
        }
    }

    defaultConfig {
        val localProperties = Properties()
        val localPropertiesFile = rootProject.file("local.properties")
        if (localPropertiesFile.exists()) {
            localPropertiesFile.reader(Charsets.UTF_8).use { localProperties.load(it) }
        }

        // Inject API keys from local.properties (dev) or CI env vars (prod)
        manifestPlaceholders["GOOGLE_MAPS_API_KEY"] =
            System.getenv("GOOGLE_MAPS_API_KEY")
                ?: localProperties.getProperty("GOOGLE_MAPS_API_KEY", "")
        manifestPlaceholders["MAPBOX_ACCESS_TOKEN"] =
            System.getenv("MAPBOX_ACCESS_TOKEN")
                ?: localProperties.getProperty("MAPBOX_ACCESS_TOKEN", "")

        applicationId = "com.cruiseinride.app"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = if (hasKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Stated rather than inherited. Both already defaulted to false,
            // but "the default is false" is not something you want to be
            // guessing at while a build dies of memory exhaustion — with
            // these off, R8 runs dex-only instead of whole-program, which is
            // the difference between fitting in 8 GB and not.
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
