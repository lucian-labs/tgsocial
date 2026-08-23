import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

// Telegram api_id / api_hash come from android/secrets.properties (gitignored; see secrets.properties.example).
val secrets = Properties().apply {
    val f = rootProject.file("secrets.properties")
    if (f.exists()) f.inputStream().use { load(it) }
    else logger.warn("android/secrets.properties missing — copy secrets.properties.example and fill in TG_API_ID / TG_API_HASH")
}
val tgApiId: String = secrets.getProperty("TG_API_ID", "0")
val tgApiHash: String = secrets.getProperty("TG_API_HASH", "")

android {
    namespace = "ca.lucianlabs.tgsocial"
    compileSdk = 35

    defaultConfig {
        applicationId = "ca.lucianlabs.tgsocial"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0.0"

        buildConfigField("int", "TG_API_ID", tgApiId)
        buildConfigField("String", "TG_API_HASH", "\"$tgApiHash\"")
        buildConfigField("String", "TDLIB_VERSION", "\"1.8.65\"")
    }

    val releaseKeystore = rootProject.file("release.keystore")
    signingConfigs {
        if (releaseKeystore.exists()) {
            create("release") {
                storeFile = releaseKeystore
                storePassword = secrets.getProperty("RELEASE_STORE_PASSWORD", "")
                keyAlias = secrets.getProperty("RELEASE_KEY_ALIAS", "tgsocial")
                keyPassword = secrets.getProperty("RELEASE_KEY_PASSWORD", "")
            }
        }
    }

    buildTypes {
        debug {
            // all ABIs so emulators (x86_64) work
        }
        release {
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = if (releaseKeystore.exists()) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
            ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }
        }
    }

    buildFeatures {
        buildConfig = true
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // The House Pour kit (tokens + hand-written HP* composables) lives in design/kotlin and compiles into this module.
    sourceSets["main"].kotlin.srcDir("../../design/kotlin")

    packaging {
        resources.excludes += setOf("META-INF/AL2.0", "META-INF/LGPL2.1")
    }

    lint {
        abortOnError = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        freeCompilerArgs.add("-Xcontext-parameters")
    }
}

// The window background (painted before Compose's first frame) is the only colour Android needs as an XML resource.
// It is generated from design/tokens.json so no hex value lives in the tree.
val generateBackdropColor by tasks.registering {
    val tokens = rootProject.file("../design/tokens.json")
    val out = layout.buildDirectory.file("generated/hpres/values/hp_backdrop.xml")
    inputs.file(tokens)
    outputs.file(out)
    doLast {
        @Suppress("UNCHECKED_CAST")
        val json = groovy.json.JsonSlurper().parse(tokens) as Map<String, Any>
        @Suppress("UNCHECKED_CAST")
        val color = (json["color"] as Map<String, String>).getValue("backdropTop")
        out.get().asFile.apply {
            parentFile.mkdirs()
            writeText("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<resources>\n    <!-- GENERATED from design/tokens.json color.backdropTop — do not edit. -->\n    <color name=\"hp_backdrop\">$color</color>\n</resources>\n")
        }
    }
}
android.sourceSets["main"].res.srcDir(layout.buildDirectory.dir("generated/hpres"))
tasks.matching { it.name.startsWith("generate") && it.name.endsWith("Resources") }.configureEach { dependsOn(generateBackdropColor) }
tasks.matching { it.name.startsWith("merge") && it.name.endsWith("Resources") }.configureEach { dependsOn(generateBackdropColor) }
tasks.matching { it.name.startsWith("map") && it.name.endsWith("SourceSetPaths") }.configureEach { dependsOn(generateBackdropColor) }
tasks.matching { it.name.startsWith("package") && it.name.endsWith("Resources") }.configureEach { dependsOn(generateBackdropColor) }
tasks.matching { it.name.startsWith("process") && it.name.endsWith("Resources") }.configureEach { dependsOn(generateBackdropColor) }

// docs/card-vectors.json is the single source for protocol test vectors; copy it into the test resources before every test run.
val copyCardVectors by tasks.registering(Copy::class) {
    from(rootProject.file("../docs/card-vectors.json"))
    into(layout.buildDirectory.dir("generated/testResources"))
}
android.sourceSets["test"].resources.srcDir(layout.buildDirectory.dir("generated/testResources"))
tasks.matching { it.name.startsWith("process") && it.name.endsWith("UnitTestJavaRes") }.configureEach { dependsOn(copyCardVectors) }
tasks.withType<Test>().configureEach { dependsOn(copyCardVectors) }

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.10.01")
    implementation(composeBom)
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-text")
    implementation("androidx.compose.animation:animation")

    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.core:core-ktx:1.16.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.4")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    implementation("androidx.datastore:datastore-preferences:1.1.7")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")

    implementation("dev.g000sha256:tdl-coroutines:13.0.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
}
