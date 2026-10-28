package com.rongxuning.skywanderer.ui.home

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import com.rongxuning.skywanderer.R
import com.rongxuning.skywanderer.ui.PlaceholderScreen

@Composable
fun HomeScreen(onSignIn: () -> Unit) {
    PlaceholderScreen(
        title = stringResource(R.string.home_title),
        body = stringResource(R.string.placeholder_body),
        actionLabel = stringResource(R.string.action_sign_in),
        onAction = onSignIn,
    )
}
