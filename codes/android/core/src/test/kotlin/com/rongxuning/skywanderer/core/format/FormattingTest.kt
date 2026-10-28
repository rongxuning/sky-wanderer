package com.rongxuning.skywanderer.core.format

import org.junit.Assert.assertEquals
import org.junit.Test

class FormattingTest {
    @Test
    fun kilometersUsesTwoDecimals() {
        assertEquals("5.00", Format.kilometers(5_000.0))
    }

    @Test
    fun paceFormatsMinutesAndSeconds() {
        assertEquals("5'30\"", Format.pace(330.0))
    }

    @Test
    fun paceRejectsOutOfRange() {
        assertEquals("—", Format.pace(0.0))
        assertEquals("—", Format.pace(3_600.0))
    }

    @Test
    fun durationUsesHoursThenMinutes() {
        assertEquals("1 小时 2 分", Format.duration(3_720.0))
        assertEquals("3 分钟", Format.duration(180.0))
        assertEquals("9 秒", Format.duration(9.0))
    }

    @Test
    fun clockDropsHoursWhenShort() {
        assertEquals("05:30", Format.clock(330.0))
        assertEquals("1:01:01", Format.clock(3_661.0))
    }
}
