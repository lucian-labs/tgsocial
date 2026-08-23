package ca.lucianlabs.tgsocial.protocol

/** PROTOCOL §4.8 — t.me links. TDLib shifts server message ids by 20 bits. */
object DeepLink {
    fun serverMessageId(messageId: Long): Long = messageId shr 20

    fun post(username: String, messageId: Long): String = "https://t.me/$username/${serverMessageId(messageId)}"

    fun channel(username: String): String = "https://t.me/$username"
}
