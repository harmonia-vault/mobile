package org.harmoniavault.harmonia_mobile.productqa

/** 原生测试socket的flat JSON语法；拒重复/escaped同名、非整数version与宽松JSON变体。 */
internal object ProductQaCommand {
    fun parse(text: String): Map<String, Any> {
        require(text.length in 2..32768) { "product QA frame invalid" }
        var index = 0
        fun reject(): Nothing = throw IllegalArgumentException("product QA frame invalid")
        fun whitespace() { while (index < text.length && text[index] in " \t\r\n") index++ }
        fun expect(char: Char) { whitespace(); if (index >= text.length || text[index++] != char) reject() }
        fun string(): String {
            expect('"')
            val value = StringBuilder()
            var complete = false
            while (index < text.length) {
                val char = text[index++]
                if (char == '"') { complete = true; break }
                if (char.code < 32) reject()
                if (char.code != 92) { value.append(char); continue }
                if (index >= text.length) reject()
                when (val escape = text[index++]) {
                    34.toChar(), 92.toChar(), 47.toChar() -> value.append(escape)
                    'b' -> value.append('\b')
                    'f' -> value.append('\u000c')
                    'n' -> value.append('\n')
                    'r' -> value.append('\r')
                    't' -> value.append('\t')
                    'u' -> {
                        if (index + 4 > text.length) reject()
                        var number = 0
                        repeat(4) {
                            val digit = text[index++].digitToIntOrNull(16) ?: reject()
                            number = number * 16 + digit
                        }
                        value.append(number.toChar())
                    }
                    else -> reject()
                }
            }
            if (!complete) reject()
            val result = value.toString()
            var position = 0
            while (position < result.length) {
                val char = result[position++]
                if (char.isHighSurrogate()) {
                    if (position >= result.length || !result[position++].isLowSurrogate()) reject()
                } else if (char.isLowSurrogate()) reject()
            }
            return result
        }
        expect('{')
        val values = linkedMapOf<String, Any>()
        whitespace()
        if (index < text.length && text[index] == '}') index++ else {
            while (true) {
                val key = string()
                if (key in values) reject()
                expect(':')
                whitespace()
                values[key] = if (key == "version") {
                    if (index >= text.length || text[index++] != '1') reject()
                    1
                } else string()
                whitespace()
                if (index >= text.length) reject()
                when (text[index++]) {
                    '}' -> break
                    ',' -> Unit
                    else -> reject()
                }
            }
        }
        whitespace()
        if (index != text.length) reject()
        return values
    }
}
