package com.rongxuning.skywanderer.di

import com.rongxuning.skywanderer.coros.CorosPartnerClient
import com.rongxuning.skywanderer.data.health.HealthConnectGateway
import com.rongxuning.skywanderer.data.settings.SettingsStore
import com.rongxuning.skywanderer.domain.RecordRepository
import javax.inject.Inject
import javax.inject.Singleton

/** Holds the scaffold graph so Hilt must resolve Room, DataStore, Health Connect, and COROS. */
@Singleton
class AppBootstrap @Inject constructor(
    recordRepository: RecordRepository,
    healthConnect: HealthConnectGateway,
    settings: SettingsStore,
    coros: CorosPartnerClient,
) {
    val graphReady: Boolean = listOf(recordRepository, healthConnect, settings, coros).isNotEmpty()
}
