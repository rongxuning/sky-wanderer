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
                "户外步行",
                "徒步",
                "力量训练",
                "综合训练",
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
    fun outdoorWalkingRoundTrips() {
        assertEquals(SportKind.OutdoorWalking, SportKind.fromStored("outdoorWalking"))
        assertEquals(SportKind.OutdoorWalking, SportKind.fromStored("outdoorwalking"))
    }

    @Test
    fun unknownStoredValueIsOther() {
        assertEquals(SportKind.Other, SportKind.fromStored("cycling"))
    }
}
