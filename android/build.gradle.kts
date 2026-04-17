allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
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

subprojects {
    val applyPluginWorkaround: (Project) -> Unit = { p ->
        if (p.name == "ar_flutter_plugin") {
            val androidExtension = p.extensions.findByName("android")
            if (androidExtension != null) {
                // Fix Namespace
                val setNamespaceMethod = androidExtension.javaClass.methods.find { it.name == "setNamespace" }
                setNamespaceMethod?.invoke(androidExtension, "io.carius.lars.ar_flutter_plugin")

                // Fix Java JVM Target
                try {
                    val getCompileOptions = androidExtension.javaClass.getMethod("getCompileOptions")
                    val compileOptions = getCompileOptions.invoke(androidExtension)
                    val setSourceCompatibility = compileOptions.javaClass.getMethod("setSourceCompatibility", JavaVersion::class.java)
                    val setTargetCompatibility = compileOptions.javaClass.getMethod("setTargetCompatibility", JavaVersion::class.java)
                    setSourceCompatibility.invoke(compileOptions, JavaVersion.VERSION_17)
                    setTargetCompatibility.invoke(compileOptions, JavaVersion.VERSION_17)
                } catch (e: Exception) {}
            }

            // Fix Kotlin JVM Target
            p.tasks.configureEach {
                if (name.contains("compile", ignoreCase = true) && name.contains("Kotlin", ignoreCase = true)) {
                    try {
                        val getKotlinOptions = this.javaClass.getMethod("getKotlinOptions")
                        val kotlinOptions = getKotlinOptions.invoke(this)
                        val setJvmTarget = kotlinOptions.javaClass.getMethod("setJvmTarget", String::class.java)
                        setJvmTarget.invoke(kotlinOptions, "17")
                    } catch (e: Exception) {}
                }
            }
        }
    }

    if (project.state.executed) {
        applyPluginWorkaround(project)
    } else {
        project.afterEvaluate {
            applyPluginWorkaround(project)
        }
    }
}
