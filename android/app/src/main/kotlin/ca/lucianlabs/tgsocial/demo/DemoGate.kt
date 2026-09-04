package ca.lucianlabs.tgsocial.demo

/**
 * PRODUCT §2.22.3 — the three refusals, enforced where the action actually happens.
 *
 * `Open in Telegram`, `Copy Link`, `Share` and every link in a post reach the outside through five functions
 * in `ui/components/Links.kt`. Guarding *those* is the same idea as §2.22.4's substituted object: one place
 * that cannot be missed, rather than a flag checked at each of the fifteen call sites that reach them — a
 * kebab item added next month gets the refusal without anyone remembering to add it.
 *
 * §2.22.3 splits the refusal into three sentences, so *which* string a function passes is as load-bearing as
 * whether it asks at all: `openLink` and `openInTelegram` do the same thing to the same intent and answer
 * differently, which is why they are two functions rather than one with a default argument.
 *
 * The report email is deliberately not gated. §2.22.2 keeps report working in full, and the composer is the
 * reader's own mail client: the app hands it a `mailto:` and makes no request itself.
 *
 * Set by the view model, which owns the session; read from composables that have no view model in scope.
 */
object DemoGate {

    @Volatile
    private var active: Boolean = false

    @Volatile
    private var refuse: ((String) -> Unit)? = null

    val isActive: Boolean get() = active

    fun open(onRefusal: (String) -> Unit) {
        refuse = onRefusal
        active = true
    }

    fun close() {
        active = false
        refuse = null
    }

    /**
     * True when the demo swallowed this action. [message] is one of [DemoCopy]'s three strings — the caller
     * picks which truth applies, because "nothing here is on Telegram" and "links don't open in the demo" are
     * different sentences about different things.
     */
    fun refused(message: String): Boolean {
        if (!active) return false
        refuse?.invoke(message)
        return true
    }
}
