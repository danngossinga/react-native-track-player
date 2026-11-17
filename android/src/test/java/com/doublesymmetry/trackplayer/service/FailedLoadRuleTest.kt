package com.doublesymmetry.trackplayer.service

import org.junit.Assert.assertEquals
import org.junit.Test

/** FailedLoadRule against the shared scenarios (iOS runs the same file). */
class FailedLoadRuleTest {
    @Test
    fun followsTheSharedScenarios() {
        @Suppress("UNCHECKED_CAST")
        val scenarios = readSharedFixture("scripts/fixtures/failed-load-scenarios.json")["scenarios"] as List<Map<String, Any?>>
        assertEquals(5, scenarios.size)
        for (scenario in scenarios) {
            val id = scenario["id"] as String
            val rule = FailedLoadRule()
            @Suppress("UNCHECKED_CAST")
            for ((index, step) in (scenario["steps"] as List<Map<String, Any?>>).withIndex()) {
                val where = "$id step $index"
                when (val event = step["event"] as String) {
                    "load" -> rule.loaded(step["item"])
                    "ready" -> rule.ready()
                    "fail" -> assertEquals(where, step["revert"], rule.failed()?.to)
                    "play" -> assertEquals(where, step["reload"], rule.play())
                    else -> error("unknown event $event in $id")
                }
                assertEquals(where, step["active"], rule.active)
            }
        }
    }
}
