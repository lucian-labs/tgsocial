package ca.lucianlabs.tgsocial.protocol

/**
 * PRODUCT §2.3 — attribution: the post header is the NODE the post reaches me through, not the channel.
 * My feed → me; else the node I follow whose card lists the source feed (the earliest in my `follows:` order
 * when several list it); else null and the card falls back to the channel itself.
 */
object Attribution {
    /**
     * Resolves the attribution node's username for a post from [feedUsername], or null when no node attributes
     * it. [cardOf] reads a followed node's card (cached is fine — attribution is derived, never fetched for).
     */
    fun resolve(feedUsername: String, myUsername: String?, myCard: Card?, cardOf: (String) -> Card?): String? {
        if (myCard == null) return null
        if (myUsername != null && myCard.hasFeed(feedUsername)) return myUsername
        return myCard.follows.firstOrNull { cardOf(it)?.hasFeed(feedUsername) == true }
    }
}
