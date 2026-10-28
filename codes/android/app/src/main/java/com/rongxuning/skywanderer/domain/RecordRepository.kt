package com.rongxuning.skywanderer.domain

import com.rongxuning.skywanderer.core.model.SportKind
import com.rongxuning.skywanderer.core.model.WorkoutOrigin
import com.rongxuning.skywanderer.core.model.WorkoutRecord
import com.rongxuning.skywanderer.data.local.RecordDao
import javax.inject.Inject
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

interface RecordRepository {
    fun observe(): Flow<List<WorkoutRecord>>
}

class LocalRecordRepository @Inject constructor(
    private val dao: RecordDao,
) : RecordRepository {
    override fun observe(): Flow<List<WorkoutRecord>> = dao.observeAll().map { rows ->
        rows.map { row ->
            WorkoutRecord(
                id = row.id,
                sport = SportKind.fromStored(row.sport),
                origin = WorkoutOrigin.HealthConnect,
                distanceMeters = row.distanceMeters,
                durationSeconds = row.durationSeconds,
            )
        }
    }
}
