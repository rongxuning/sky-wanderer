package com.rongxuning.skywanderer.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val LightColors = lightColorScheme(
    primary = OmniCobalt,
    onPrimary = Color.White,
    primaryContainer = OmniIce,
    onPrimaryContainer = OmniDeep,
    secondary = OmniDeep,
    onSecondary = Color.White,
    background = OmniCanvas,
    onBackground = OmniInk,
    surface = Color.White,
    onSurface = OmniInk,
    surfaceVariant = OmniCanvas,
    onSurfaceVariant = OmniMuted,
    outline = OmniIdle,
    error = OmniCoral,
    onError = Color.White,
)

@Composable
fun SkyWandererTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = LightColors,
        typography = SkyWandererTypography,
        content = content,
    )
}
