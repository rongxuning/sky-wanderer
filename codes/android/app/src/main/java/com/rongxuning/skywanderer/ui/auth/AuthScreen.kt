package com.rongxuning.skywanderer.ui.auth

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import com.rongxuning.skywanderer.R
import com.rongxuning.skywanderer.ui.PlaceholderScreen

@Composable
fun AuthScreen(onBack: () -> Unit) {
    PlaceholderScreen(
        title = stringResource(R.string.auth_title),
        body = stringResource(R.string.auth_body),
        actionLabel = stringResource(R.string.action_back),
        onAction = onBack,
    )
}
