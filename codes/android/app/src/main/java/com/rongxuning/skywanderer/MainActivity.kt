package com.rongxuning.skywanderer

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.rongxuning.skywanderer.di.AppBootstrap
import com.rongxuning.skywanderer.ui.SkyWandererRoot
import com.rongxuning.skywanderer.ui.theme.SkyWandererTheme
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    @Inject lateinit var bootstrap: AppBootstrap

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        check(bootstrap.graphReady)
        setContent {
            SkyWandererTheme {
                SkyWandererRoot()
            }
        }
    }
}
