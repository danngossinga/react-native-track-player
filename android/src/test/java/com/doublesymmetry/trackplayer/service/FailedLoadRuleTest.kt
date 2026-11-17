package com.doublesymmetry.trackplayer.service

import org.junit.Assert.assertEquals
import org.junit.Test

/** FailedLoadRule against the shared scenarios (iOS runs the same file). */
class FailedLoadRuleTest {
    @Test
    fun followsTheSharedScenarios() {
        @Suppress("UNCHECKED_CAST")
        val scenarios = readSharedFixture("scripts/fixtures/failed-load-scenarios.json")["scenarios"] as List<Map<String, Any?>>
        assertEquals(8, scenarios.size)
        for (scenario in scenarios) {
            val id = scenario["id"] as String
            val rule = FailedLoadRule()
            // One object per item name (the rule compares items by identity).
            val items = mutableMapOf<String, Any>()
            fun item(name: Any?): Any? = (name as String?)?.let { items.getOrPut(it) { Any() } }
            @Suppress("UNCHECKED_CAST")
            for ((index, step) in (scenario["steps"] as List<Map<String, Any?>>).withIndex()) {
                val where = "$id step $index"
                // The change expected (no key: none), to and from which track (null: none).
                fun assertReport(report: FailedLoadRule.Report?) {
                    val expected = (step["report"] as Map<String, Any?>?)?.let { FailedLoadRule.Report(item(it["to"]), item(it["from"])) }
                    assertEquals(where, expected, report)
                }
                when (val event = step["event"] as String) {
                    "load" -> assertEquals(where, step["report"], rule.moved(item(step["item"])))
                    "ready" -> assertReport(rule.ready())
                    "fail" -> assertReport(rule.failed())
                    "command" -> assertReport(rule.command())
                    "play" -> assertEquals(where, item(step["reload"]), rule.play())
                    "reset" -> rule.reset()
                    else -> error("unknown event $event in $id")
                }
                assertEquals("$where active", item(step["active"]), rule.active)
                assertEquals("$where reported", item(step["reported"]), rule.reported)
            }
        }
    }
}
