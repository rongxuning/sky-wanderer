package com.rongxuning.skywanderer.ui.me

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import com.rongxuning.skywanderer.R
import com.rongxuning.skywanderer.ui.PlaceholderScreen

@Composable
fun MeScreen() {
    PlaceholderScreen(
        title = stringResource(R.string.me_title),
        body = stringResource(R.string.placeholder_body),
    )
}