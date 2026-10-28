package com.rongxuning.skywanderer.data.settings

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

private val Context.settingsDataStore by preferencesDataStore(name = "sky_wanderer_settings")

@Singleton
class SettingsStore @Inject constructor(
    @param:ApplicationContext private val context: Context,
) {
    val displayName: Flow<String> = context.settingsDataStore.data.map { prefs ->
        prefs[DisplayName] ?: ""
    }

    suspend fun setDisplayName(name: String) {
        context.settingsDataStore.edit { prefs -> prefs[DisplayName] = name }
    }

    private companion object {
        val DisplayName = stringPreferencesKey("display_name")
    }
}
