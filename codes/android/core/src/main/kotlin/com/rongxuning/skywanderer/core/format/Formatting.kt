package com.rongxuning.skywanderer.core.format

import java.util.Locale
import kotlin.math.roundToInt

/** Distance, pace, and duration text. Mirrors `codes/ios/Shared/Formatting.swift`. */
object Format {
    fun kilometers(meters: Double): String =
        String.format(Locale.US, "%.2f", meters / 1_000.0)

    fun pace(secondsPerKm: Double): String {
        if (!secondsPerKm.isFinite() || secondsPerKm <= 0.0 || secondsPerKm >= 3_600.0) {
            return "—"
        }
        val total = secondsPerKm.roundToInt()
        return String.format(Locale.US, "%d'%02d\"", total / 60, total % 60)
    }

    fun duration(seconds: Double): String {
        val whole = seconds.roundToInt().coerceAtLeast(0)
        val hours = whole / 3_600
        val minutes = (whole % 3_600) / 60
        return when {
            hours > 0 -> "$hours 小时 $minutes 分"
            minutes > 0 -> "$minutes 分钟"
            else -> "$whole 秒"
        }
    }

    fun clock(seconds: Double): String {
        val whole = seconds.toInt().coerceAtLeast(0)
        val hours = whole / 3_600
        val minutes = (whole % 3_600) / 60
        val secs = whole % 60
        return if (hours > 0) {
            String.format(Locale.US, "%d:%02d:%02d", hours, minutes, secs)
        } else {
            String.format(Locale.US, "%02d:%02d", minutes, secs)
        }
    }
}
