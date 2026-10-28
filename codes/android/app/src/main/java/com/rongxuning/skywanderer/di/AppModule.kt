package com.rongxuning.skywanderer.di

import android.content.Context
import androidx.room.Room
import com.rongxuning.skywanderer.coros.CorosPartnerClient
import com.rongxuning.skywanderer.data.local.RecordDao
import com.rongxuning.skywanderer.data.local.SkyWandererDatabase
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object AppModule {
    @Provides
    @Singleton
    fun database(@ApplicationContext context: Context): SkyWandererDatabase =
        Room.databaseBuilder(
            context,
            SkyWandererDatabase::class.java,
            "sky-wanderer.db",
        ).build()

    @Provides
    fun recordDao(database: SkyWandererDatabase): RecordDao = database.recordDao()

    @Provides
    @Singleton
    fun corosPartnerClient(): CorosPartnerClient = CorosPartnerClient()
}
