import org.jetbrains.kotlin.gradle.tasks.KotlinCompile
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import com.android.build.gradle.LibraryExtension
import com.android.build.gradle.AppExtension
import javax.inject.Inject
import org.gradle.api.file.Directory

allprojects {
    repositories {
        google()
        mavenCentral()
    }
    
    subprojects {
        afterEvaluate {
            // Fix Kotlin JVM target
            if (project.plugins.hasPlugin("org.jetbrains.kotlin.android")) {
                tasks.withType<KotlinCompile> {
                    compilerOptions {
                        jvmTarget.set(JvmTarget.JVM_17)
                    }
                }
            }
            
            // Fix Android Library modules
            if (project.plugins.hasPlugin("com.android.library")) {
                configure<com.android.build.gradle.LibraryExtension> {
                    compileSdkVersion = "android-36"  // ← FULL SDK NAME
                    compileOptions {
                        sourceCompatibility = JavaVersion.VERSION_17
                        targetCompatibility = JavaVersion.VERSION_17
                    }
                }
            }
            
            // Fix Android App modules
            if (project.plugins.hasPlugin("com.android.application")) {
                configure<com.android.build.gradle.AppExtension> {
                    compileSdkVersion = "android-36"  // ← FULL SDK NAME
                    compileOptions {
                        sourceCompatibility = JavaVersion.VERSION_17
                        targetCompatibility = JavaVersion.VERSION_17
                    }
                }
            }
        }
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
