package ca.lucianlabs.tgsocial.audio

import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Radix-2 Cooley–Tukey FFT with a Hann window — the house spectrum primitive, written out in Kotlin rather
 * than pulled in as a dependency (Wake gets the same thing from vDSP; see `WakeFFTAnalyzer.swift`).
 *
 * Real input, `size / 2` magnitude bins out. Bin `k` is centred on `k * rate / size` Hz.
 *
 * Everything is preallocated: [magnitudes] is called once per hop, so a 10-minute clip runs it ~9 000 times
 * and an allocation per call is 9 000 arrays of 2 048 floats for the collector to walk. The instance is
 * therefore **not** thread-safe — one analysis job owns one [Fft].
 *
 * ### Scaling
 * Magnitudes come out as `2 * |X[k]| / size`, so a full-scale sine reads ≈ 0.5 through the Hann window
 * (whose coherent gain is 0.5) and ≈ 1.0 with the window's gain divided back out. The absolute figure does
 * not actually matter downstream — [Spectrogram] normalises against a rolling peak, not against dBFS — but
 * a fixed convention is what makes the AGC's floor a meaningful number.
 */
class Fft(val size: Int) {
    init {
        require(size >= 2 && size and (size - 1) == 0) { "FFT size must be a power of two, was $size" }
    }

    val bins: Int = size / 2

    private val window = FloatArray(size) { i ->
        // Periodic Hann: the correct form for spectral analysis of a continuing signal (the symmetric form
        // duplicates the endpoint and biases the estimate slightly).
        (0.5 - 0.5 * cos(2.0 * Math.PI * i / size)).toFloat()
    }
    private val re = FloatArray(size)
    private val im = FloatArray(size)
    private val reverse = IntArray(size).also { table ->
        var bits = 0
        while (1 shl bits < size) bits++
        for (i in 0 until size) {
            var v = i
            var r = 0
            for (b in 0 until bits) {
                r = (r shl 1) or (v and 1)
                v = v shr 1
            }
            table[i] = r
        }
    }
    private val cosTable = FloatArray(size / 2) { cos(-2.0 * Math.PI * it / size).toFloat() }
    private val sinTable = FloatArray(size / 2) { sin(-2.0 * Math.PI * it / size).toFloat() }

    /**
     * Windowed magnitudes of `size` samples read from [samples] at [offset], written into [out]
     * (`out.size == bins`). Reads past the end of [samples] are zero-filled, which is the right behaviour
     * for the last hop of a clip.
     */
    fun magnitudes(samples: FloatArray, offset: Int, out: FloatArray) {
        require(out.size == bins) { "out must hold $bins bins, holds ${out.size}" }
        for (i in 0 until size) {
            val j = offset + i
            re[reverse[i]] = if (j in samples.indices) samples[j] * window[i] else 0f
            im[reverse[i]] = 0f
        }
        var span = 2
        while (span <= size) {
            val half = span / 2
            val step = size / span
            var start = 0
            while (start < size) {
                var k = 0
                for (i in start until start + half) {
                    val c = cosTable[k]
                    val s = sinTable[k]
                    val j = i + half
                    val tr = re[j] * c - im[j] * s
                    val ti = re[j] * s + im[j] * c
                    re[j] = re[i] - tr
                    im[j] = im[i] - ti
                    re[i] += tr
                    im[i] += ti
                    k += step
                }
                start += span
            }
            span = span shl 1
        }
        val scale = 2f / size
        for (k in 0 until bins) out[k] = sqrt(re[k] * re[k] + im[k] * im[k]) * scale
    }
}
