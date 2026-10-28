package com.rongxuning.skywanderer.data.local

import androidx.room.Dao
import androidx.room.Entity
import androidx.room.PrimaryKey
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Entity(tableName = "records")
data class RecordEntity(
    @PrimaryKey val id: String,
    val sport: String,
    val distanceMeters: Double,
    val durationSeconds: Long,
)

@Dao
interface RecordDao {
    @Query("SELECT * FROM records")
    fun observeAll(): Flow<List<RecordEntity>>
}
