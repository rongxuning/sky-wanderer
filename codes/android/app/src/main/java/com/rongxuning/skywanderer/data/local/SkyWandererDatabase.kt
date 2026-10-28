package com.rongxuning.skywanderer.data.local

import androidx.room.Database
import androidx.room.RoomDatabase

@Database(entities = [RecordEntity::class], version = 1, exportSchema = false)
abstract class SkyWandererDatabase : RoomDatabase() {
    abstract fun recordDao(): RecordDao
}
