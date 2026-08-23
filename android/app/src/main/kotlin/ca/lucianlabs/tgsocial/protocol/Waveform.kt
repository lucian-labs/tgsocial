package ca.lucianlabs.tgsocial.protocol

/** TDLib voice-note waveforms: 5-bit samples packed little-endian into bytes. */
object Waveform {
    /** Unpacks to 0–1 floats. Empty input yields an empty list. */
    fun decode(bytes: ByteArray): List<Float> {
        if (bytes.isEmpty()) return emptyList()
        val count = bytes.size * 8 / 5
        val out = ArrayList<Float>(count)
        for (i in 0 until count) {
            val bit = i * 5
            val byteIndex = bit / 8
            val shift = bit % 8
            var value = (bytes[byteIndex].toInt() and 0xFF) shr shift
            if (shift > 3 && byteIndex + 1 < bytes.size) {
                value = value or ((bytes[byteIndex + 1].toInt() and 0xFF) shl (8 - shift))
            }
            out += (value and 0x1F) / 31f
        }
        return out
    }
}
