package com.rongxuning.skywanderer

import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
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
        // Light status icons on the light canvas; light nav icons on the starry-gray tab bar.
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )
        check(bootstrap.graphReady)
        setContent {
            SkyWandererTheme {
                SkyWandererRoot()
            }
        }
    }
}
