package com.rongxuning.skywanderer.core.model

/** Mirrors iOS `SportKind`. Legacy stored `"running"` maps to outdoor running. */
enum class SportKind {
    OutdoorRunning,
    IndoorRunning,
    TrailRunning,
    OutdoorWalking,
    Hiking,
    FunctionalStrength,
    Hiit,
    Other,
    ;

    val title: String
        get() = when (this) {
            OutdoorRunning -> "户外跑步"
            IndoorRunning -> "室内跑步"
            TrailRunning -> "越野跑"
            OutdoorWalking -> "户外步行"
            Hiking -> "徒步"
            FunctionalStrength -> "功能性力量训练"
            Hiit -> "HIIT训练"
            Other -> "其他"
        }

    companion object {
        fun fromStored(value: String): SportKind =
            when (value.lowercase()) {
                "running", "outdoorrunning" -> OutdoorRunning
                "indoorrunning" -> IndoorRunning
                "trailrunning" -> TrailRunning
                "outdoorwalking" -> OutdoorWalking
                "hiking" -> Hiking
                "functionalstrength" -> FunctionalStrength
                "hiit" -> Hiit
                "other" -> Other
                else -> entries.firstOrNull { it.name.equals(value, ignoreCase = true) } ?: Other
            }
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
