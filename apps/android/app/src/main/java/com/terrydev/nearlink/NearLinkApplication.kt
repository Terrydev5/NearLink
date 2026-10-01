package com.terrydev.nearlink

import android.app.Application

class NearLinkApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        NearLinkDiagnostics.install(this)
        NearLinkDiagnostics.event("Application.onCreate completed")
    }
}
