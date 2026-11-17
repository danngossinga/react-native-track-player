package com.doublesymmetry.trackplayer.service

import org.junit.Assert.assertEquals
import org.junit.Test

/** FailedLoadRule against the shared scenarios (iOS runs the same file). */
class FailedLoadRuleTest {
    @Test
    fun followsTheSharedScenarios() {
        @Suppress("UNCHECKED_CAST")
        val scenarios = readSharedFixture("scripts/fixtures/failed-load-scenarios.json")["scenarios"] as List<Map<String, Any?>>
        assertEquals(13, scenarios.size)
        for (scenario in scenarios) {
            val id = scenario["id"] as String
            val rule = FailedLoadRule()
            // One object per item name (the rule compares items by identity).
            val items = mutableMapOf<String, Any>()
            fun item(name: Any?): Any? = (name as String?)?.let { items.getOrPut(it) { Any() } }
            fun nameOf(item: Any?): String = items.entries.firstOrNull { it.value === item }?.key ?: "none"
            fun phaseName(phase: FailedLoadRule.Phase): String = when (phase) {
                FailedLoadRule.Phase.Selecting -> "selecting"
                is FailedLoadRule.Phase.Loading -> "loading ${nameOf(phase.item)}"
                is FailedLoadRule.Phase.Loaded -> "loaded ${nameOf(phase.item)}"
                is FailedLoadRule.Phase.Failed -> "failed ${nameOf(phase.item)}"
            }
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
                    "remove" -> assertReport(rule.removed(item(step["item"])))
                    "publish" -> rule.published(item(step["item"]))
                    "adopt" -> rule.adopted(item(step["item"]))
                    "replace" -> rule.replaced(item(step["item"]), item(step["with"]))
                    // As the backends: the first error while the player has one fails the load.
                    "error" -> {
                        val isNew = rule.playerErrorSeen()
                        assertEquals("$where new", step["new"], isNew)
                        assertReport(if (isNew) rule.failed() else null)
                    }
                    "recover" -> assertEquals("$where cleared", step["cleared"], rule.playerErrorGone())
                    else -> error("unknown event $event in $id")
                }
                assertEquals("$where phase", step["phase"], phaseName(rule.phase))
                assertEquals("$where playerError", step["playerError"], rule.playerError.name.lowercase())
                assertEquals("$where active", item(step["active"]), rule.active)
                assertEquals("$where reported", item(step["reported"]), rule.reported)
            }
        }
    }
}
