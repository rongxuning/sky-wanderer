package com.rongxuning.skywanderer.core.model

import org.junit.Assert.assertEquals
import org.junit.Test

class SportKindTest {
    @Test
    fun titlesMatchAppList() {
        assertEquals(
            listOf(
                "户外跑步",
                "室内跑步",
                "越野跑",
                "徒步",
                "功能性力量训练",
                "HIIT训练",
                "其他",
            ),
            SportKind.entries.map { it.title },
        )
    }

    @Test
    fun legacyRunningMapsToOutdoor() {
        assertEquals(SportKind.OutdoorRunning, SportKind.fromStored("running"))
        assertEquals(SportKind.OutdoorRunning, SportKind.fromStored("Running"))
    }

    @Test
    fun unknownStoredValueIsOther() {
        assertEquals(SportKind.Other, SportKind.fromStored("cycling"))
    }
}
