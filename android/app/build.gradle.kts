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
        }
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    // Release keystore — reads from Codemagic encrypted env vars:
    //   CM_KEYSTORE_PASSWORD, CM_KEY_ALIAS, CM_KEY_PASSWORD
    // The keystore file is decoded to /tmp/cruise-release.keystore by the CI script.
    val ksFile = file("/tmp/cruise-release.keystore")
    val ksPassword = System.getenv("CM_KEYSTORE_PASSWORD") ?: ""
    val keyAlias   = System.getenv("CM_KEY_ALIAS")         ?: ""
    val keyPass    = System.getenv("CM_KEY_PASSWORD")      ?: ""
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

        manifestPlaceholders["MAPS_API_KEY"] =
            localProperties.getProperty("MAPS_API_KEY", "")

        applicationId = "com.cruiseinride.app"
        minSdk = flutter.minSdkVersion
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
