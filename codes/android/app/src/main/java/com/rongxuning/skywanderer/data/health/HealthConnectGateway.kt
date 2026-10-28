package com.rongxuning.skywanderer.data.health

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

enum class HealthConnectAvailability {
    Available,
    UpdateRequired,
    Unavailable,
}

/** Reads Health Connect availability only. Permission prompts are not in this scaffold. */
@Singleton
class HealthConnectGateway @Inject constructor(
    @param:ApplicationContext private val context: Context,
) {
    fun availability(): HealthConnectAvailability =
        when (HealthConnectClient.getSdkStatus(context)) {
            HealthConnectClient.SDK_AVAILABLE -> HealthConnectAvailability.Available
            HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED ->
                HealthConnectAvailability.UpdateRequired
            else -> HealthConnectAvailability.Unavailable
        }
}
