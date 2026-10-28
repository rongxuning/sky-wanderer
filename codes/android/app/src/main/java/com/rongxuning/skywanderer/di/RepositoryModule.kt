package com.rongxuning.skywanderer.di

import com.rongxuning.skywanderer.domain.LocalRecordRepository
import com.rongxuning.skywanderer.domain.RecordRepository
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
abstract class RepositoryModule {
    @Binds
    @Singleton
    abstract fun recordRepository(impl: LocalRecordRepository): RecordRepository
}
