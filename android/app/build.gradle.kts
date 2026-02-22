import java.util.Properties // Importação essencial para lidar com arquivos de propriedades

// 1. ESTE BLOCO É O QUE ESTÁ FALTANDO NO SEU ARQUIVO:
val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    localPropertiesFile.inputStream().use { localProperties.load(it) }
}

// 1. No topo, adicione a leitura do arquivo de chaves
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}


plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}
android {
    namespace = "com.frankito.router_zone"
    compileSdk = 36 
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.frankito.router_zone"
        minSdk = flutter.minSdkVersion 
        targetSdk = 36 
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        
        // Ponte para a chave do Google Maps
        manifestPlaceholders["MAPS_API_KEY"] = localProperties.getProperty("MAPS_API_KEY") ?: ""
    }

    // 1. PRIMEIRO: Definimos como o app é assinado
    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = keystoreProperties["storeFile"]?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String
        }
    }

    // 2. DEPOIS: Configuramos os tipos de construção
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            
            // ✅ ESTAS DUAS LINHAS RESOLVEM O SEU ERRO:
            isMinifyEnabled = false
            isShrinkResources = false 
            
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

flutter {
    source = "../.."
}

/*subprojects {
    afterEvaluate {
        val android = extensions.findByName("android") as? com.android.build.gradle.BaseExtension
        android?.let {
            if (it.namespace == null) {
                // Isso "inventa" um namespace para pacotes que esqueceram de colocar
                it.namespace = it.defaultConfig.applicationId ?: "temp.namespace.${project.name}"
            }
        }
    }
}*/


