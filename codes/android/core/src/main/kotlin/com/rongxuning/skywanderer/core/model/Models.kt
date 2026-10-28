package com.rongxuning.skywanderer.core.model

enum class SportKind {
    Hiking,
    Running,
    ;

    val title: String
        get() = when (this) {
            Hiking -> "徒步"
            Running -> "跑步"
        }

    companion object {
        fun fromStored(value: String): SportKind =
            entries.firstOrNull { it.name.equals(value, ignoreCase = true) } ?: Hiking
    }
}

data class GeoPoint(
    val latitude: Double,
    val longitude: Double,
    val altitudeMeters: Double = 0.0,
)

/** Android stand-in for the iOS `WorkoutOrigin` cases. Health Connect replaces HealthKit. */
enum class WorkoutOrigin {
    Sample,
    HealthConnect,
    Simulated,
}

data class WorkoutRecord(
    val id: String,
    val sport: SportKind,
    val origin: WorkoutOrigin,
    val distanceMeters: Double,
    val durationSeconds: Long,
)
