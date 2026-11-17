package com.doublesymmetry.trackplayer.service

import java.io.File

/** A JSON file the iOS XCTests read too, by its path from the repository root (scripts/fixtures). */
internal fun readSharedFixture(path: String): Map<String, Any?> {
    var dir: File? = File("").absoluteFile
    while (dir != null && !File(dir, path).exists()) dir = dir.parentFile
    return parseFixtureJson(File(checkNotNull(dir) { "$path not found" }, path).readText())
}

// org.json is a stub in JVM tests: a small parser for the fixtures' JSON.
internal fun parseFixtureJson(text: String): Map<String, Any?> {
    var i = 0
    fun ws() { while (i < text.length && text[i].isWhitespace()) i++ }
    fun value(): Any? {
        ws()
        return when (text[i]) {
            '{' -> { i++; val m = linkedMapOf<String, Any?>(); ws(); if (text[i] == '}') { i++; return m }
                while (true) { ws(); val k = value() as String; ws(); i++; m[k] = value(); ws(); if (text[i++] == '}') break }; m }
            '[' -> { i++; val l = mutableListOf<Any?>(); ws(); if (text[i] == ']') { i++; return l }
                while (true) { l += value(); ws(); if (text[i++] == ']') break }; l }
            '"' -> { i++; val sb = StringBuilder(); while (text[i] != '"') { if (text[i] == '\\') i++; sb.append(text[i++]) }; i++; sb.toString() }
            't' -> { i += 4; true }
            'f' -> { i += 5; false }
            'n' -> { i += 4; null }
            else -> { val s = i; while (i < text.length && (text[i].isDigit() || text[i] == '-' || text[i] == '.')) i++; text.substring(s, i).toDouble() }
        }
    }
    @Suppress("UNCHECKED_CAST")
    return value() as Map<String, Any?>
}
