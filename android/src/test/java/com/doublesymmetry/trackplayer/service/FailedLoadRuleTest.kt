package com.doublesymmetry.trackplayer.service

import org.junit.Assert.assertEquals
import org.junit.Test

/** FailedLoadRule against the shared scenarios (iOS runs the same file). */
class FailedLoadRuleTest {
    @Test
    fun followsTheSharedScenarios() {
        @Suppress("UNCHECKED_CAST")
        val scenarios = readSharedFixture("scripts/fixtures/failed-load-scenarios.json")["scenarios"] as List<Map<String, Any?>>
        assertEquals(7, scenarios.size)
        for (scenario in scenarios) {
            val id = scenario["id"] as String
            val rule = FailedLoadRule()
            // One object per item name (the rule compares items by identity).
            val items = mutableMapOf<String, Any>()
            fun item(name: Any?): Any? = (name as String?)?.let { items.getOrPut(it) { Any() } }
            @Suppress("UNCHECKED_CAST")
            for ((index, step) in (scenario["steps"] as List<Map<String, Any?>>).withIndex()) {
                val where = "$id step $index"
                // A report expected (absent: none), and to which track (null: none).
                fun assertReport(report: FailedLoadRule.Report?) =
                    assertEquals(where, if (step.containsKey("report")) FailedLoadRule.Report(item(step["report"])) else null, report)
                when (val event = step["event"] as String) {
                    "load" -> assertEquals(where, step["report"], rule.moved(item(step["item"])))
                    "ready" -> assertReport(rule.ready())
                    "fail" -> assertReport(rule.failed())
                    "command" -> assertReport(rule.command())
                    "play" -> assertEquals(where, item(step["reload"]), rule.play())
                    else -> error("unknown event $event in $id")
                }
                assertEquals(where, item(step["active"]), rule.active)
            }
        }
    }
}
