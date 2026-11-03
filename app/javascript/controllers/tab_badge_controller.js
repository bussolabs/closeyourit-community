import { Controller } from "@hotwired/stimulus"

// CYRA-1147 — the tab title starts with "(n)" and the favicon gets a dot while decisions or unread
// notifications wait. n sums the exact `data-pending-count` of the counters, never their "99+" label.
// Turbo resets the title on every visit; this controller reconnects with the new page and reapplies it.
const TITLE_PREFIX = /^\(\d+\+?\) /
const ICON = "/icon.svg"
const DOT_ICON = "/icon-dot.svg"
const APPROVALS_FRAME = "turbo-frame#member-nav-approvals-count"
// The approvals queue is heavy: recount it on return to the tab and every 5 minutes, never faster.
const REFRESH_MS = 5 * 60 * 1000

export default class extends Controller {
  connect() {
    this.apply = this.apply.bind(this)
    this.refresh = this.refresh.bind(this)
    this.onVisibility = () => { if (document.visibilityState === "visible") this.refresh() }

    // Counters change in place: a broadcast replaces the bell badge, the lazy frame loads the approvals.
    this.observer = new MutationObserver(this.apply)
    this.observer.observe(this.element, { childList: true, subtree: true, attributes: true, attributeFilter: ["data-pending-count"] })
    document.addEventListener("visibilitychange", this.onVisibility)
    this.timer = setInterval(this.refresh, REFRESH_MS)

    // The frame is lazy and the sidebar is hidden on a phone: load it anyway, the title needs it.
    this.#approvalsFrame()?.setAttribute("loading", "eager")
    this.apply()
  }

  disconnect() {
    this.observer.disconnect()
    document.removeEventListener("visibilitychange", this.onVisibility)
    clearInterval(this.timer)
  }

  refresh() {
    const frame = this.#approvalsFrame()
    if (frame?.src) frame.reload()
  }

  apply() {
    const total = [...this.element.querySelectorAll("[data-pending-count]")]
      .reduce((sum, el) => sum + (parseInt(el.dataset.pendingCount, 10) || 0), 0)
    const base = document.title.replace(TITLE_PREFIX, "")
    const title = total > 0 ? `(${total > 99 ? "99+" : total}) ${base}` : base
    if (document.title !== title) document.title = title

    const icon = document.querySelector("link[rel~='icon']")
    const href = total > 0 ? DOT_ICON : ICON
    if (icon && icon.getAttribute("href") !== href) icon.setAttribute("href", href)
  }

  #approvalsFrame() {
    return this.element.querySelector(APPROVALS_FRAME)
  }
}
