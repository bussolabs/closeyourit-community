import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"

// Thread di una conversazione di chat.
//
// - append messaggi + update typing/receipt: li applica Turbo (turbo_stream_from nella view) — qui
//   ci limitiamo ad auto-scrollare in fondo quando ne arriva uno nuovo.
// - typing (client→server): apriamo una subscription a ChatConversationChannel e, all'input,
//   facciamo perform("typing") throttlato. L'eco del proprio indicatore viene rimosso; ogni
//   indicatore si autopulisce dopo un timeout.
// - mark_read (client→server): al connect e quando la finestra torna in focus.
export default class extends Controller {
  static targets = ["messages", "typing", "message", "dayTemplate"]
  static values = {
    id: String,
    accountId: String,
    todayLabel: String,
    yesterdayLabel: String,
    typingThrottle: { type: Number, default: 2000 },
    typingClear: { type: Number, default: 4000 }
  }

  connect() {
    this.scrollToBottom()
    this.observer = new MutationObserver(() => this.scrollToBottom())
    if (this.hasMessagesTarget) {
      this.observer.observe(this.messagesTarget, { childList: true })
    }
    this.onFocus = () => this.markRead()
    window.addEventListener("focus", this.onFocus)

    cable
      .getConsumer()
      .then((consumer) => {
        this.subscription = consumer.subscriptions.create(
          { channel: "ChatConversationChannel", id: this.idValue },
          { connected: () => this.markRead() }
        )
      })
      .catch(() => {})
  }

  disconnect() {
    if (this.observer) this.observer.disconnect()
    if (this.onFocus) window.removeEventListener("focus", this.onFocus)
    if (this.lastTypingClear) clearTimeout(this.lastTypingClear)
    if (this.subscription) {
      this.subscription.unsubscribe()
      this.subscription = null
    }
  }

  // Chiamato all'input della textarea (action nella view). Throttla il segnale "sta scrivendo".
  typing() {
    const now = Date.now()
    if (this.lastTyping && now - this.lastTyping < this.typingThrottleValue) return
    this.lastTyping = now
    this.subscription?.perform("typing")
  }

  markRead() {
    this.subscription?.perform("mark_read")
  }

  // Lifecycle target: quando compare l'indicatore typing (via broadcast), nascondi l'eco del proprio
  // account e programma la pulizia degli altri.
  typingTargetConnected(element) {
    if (element.dataset.accountId === this.accountIdValue) {
      element.remove()
      return
    }
    if (this.lastTypingClear) clearTimeout(this.lastTypingClear)
    this.lastTypingClear = setTimeout(() => {
      if (element.isConnected) element.remove()
    }, this.typingClearValue)
  }

  // Own messages sit on the right, like in any chat. Done here because broadcast HTML is the same
  // for every viewer.
  messageTargetConnected(element) {
    this.addDaySeparator(element)
    if (element.dataset.authorId !== this.accountIdValue) return
    element.classList.remove("mr-auto", "bg-zinc-50", "dark:bg-zinc-800")
    element.classList.add("ml-auto", "bg-indigo-50", "dark:bg-indigo-500/15")
  }

  // Server-rendered messages already sit under their day. A live one from a later day than the last
  // separator (or the first one in an empty thread) gets a new one; it can only be today's. Past
  // midnight the older labels shift: the old "Today" becomes "Yesterday", older ones their date.
  addDaySeparator(element) {
    const date = element.querySelector("time[datetime]")?.getAttribute("datetime")?.slice(0, 10)
    const separators = this.messagesTarget.querySelectorAll("[data-test='chat-day']")
    const last = separators[separators.length - 1]
    if (!date || (last && last.dataset.date >= date)) return
    if (!last && !this.hasDayTemplateTarget) return

    const yesterday = new Date(`${date}T12:00:00Z`)
    yesterday.setUTCDate(yesterday.getUTCDate() - 1)
    const yesterdayDate = yesterday.toISOString().slice(0, 10)
    separators.forEach((separator) => {
      separator.textContent = separator.dataset.date === yesterdayDate ? this.yesterdayLabelValue : separator.dataset.shortLabel
    })

    const separator = this.dayTemplateTarget.content.firstElementChild.cloneNode(false)
    separator.dataset.date = date
    separator.dataset.shortLabel = new Intl.DateTimeFormat(document.documentElement.lang, { day: "numeric", month: "short", timeZone: "UTC" })
      .format(new Date(`${date}T12:00:00Z`))
    separator.textContent = this.todayLabelValue
    element.before(separator)
  }

  scrollToBottom() {
    if (this.hasMessagesTarget) {
      this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
    }
  }
}
