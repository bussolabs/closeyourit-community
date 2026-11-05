import { Controller } from "@hotwired/stimulus"
import { icon } from "lib/icon"

// One search dialog, two responsive entry points: the borderless lens in the mobile top bar and the
// field in the desktop actions. It is always modal: full screen on phones, centred with the page
// blurred behind it from md up (CYRA-900).
const RECENTS_LIMIT = 6
// Same-site paths only: "//host" would leave the app.
const INTERNAL_PATH = /^\/(?!\/)/

export default class extends Controller {
  static targets = ["dialog", "trigger", "form", "input", "progress", "type", "recents", "recentsList"]

  connect() {
    this.onKeydown = (event) => this.#handleGlobalKeydown(event)
    this.onFrameLoad = (event) => { if (event.target.id === "member-global-search-results") this.loaded() }
    window.addEventListener("keydown", this.onKeydown)
    this.element.addEventListener("turbo:frame-load", this.onFrameLoad)
  }

  disconnect() {
    window.removeEventListener("keydown", this.onKeydown)
    this.element.removeEventListener("turbo:frame-load", this.onFrameLoad)
    clearTimeout(this.searchTimer)
  }

  open(event) {
    event?.preventDefault()
    this.activeTrigger = event?.currentTarget || this.triggerTargets.find((trigger) => trigger.offsetParent !== null)
    if (!this.dialogTarget.open) this.dialogTarget.showModal()
    this.#setExpanded(true)
    this.#renderRecents()
    requestAnimationFrame(() => this.inputTarget.focus())
  }

  close() {
    if (this.dialogTarget.open) this.dialogTarget.close()
  }

  cancel(event) {
    event.preventDefault()
    this.close()
  }

  backdrop(event) {
    if (event.target === this.dialogTarget) this.close()
  }

  closed() {
    this.#setExpanded(false)
    this.activeTrigger?.focus()
  }

  search() {
    clearTimeout(this.searchTimer)
    this.pending = true
    this.#renderRecents()
    if (this.hasProgressTarget) this.progressTarget.hidden = false
    this.searchTimer = setTimeout(() => this.formTarget.requestSubmit(), 180)
  }

  loaded() {
    // A late answer to an older query changes nothing: the one asked for is still on its way.
    const answered = this.dialogTarget.querySelector("[data-global-search-query]")?.dataset.globalSearchQuery
    if (answered !== undefined && answered !== this.inputTarget.value.trim().slice(0, 100)) return
    this.pending = false
    if (this.hasProgressTarget) this.progressTarget.hidden = true
    if (!this.openFirstOnLoad) return
    this.openFirstOnLoad = false
    this.#results()[0]?.click()
  }

  // A filter reloads the results frame by itself; the hidden field keeps it for the next keystroke.
  pickType(event) {
    if (this.hasTypeTarget) this.typeTarget.value = event.currentTarget.dataset.type || ""
  }

  // Enter opens the first result: with an exact code it is the ticket or project typed (CYRA-900).
  inputKeydown(event) {
    // A search still on its way: Enter waits for its results instead of opening the old ones.
    if (event.key === "Enter" && this.pending) {
      event.preventDefault()
      clearTimeout(this.searchTimer)
      this.openFirstOnLoad = true
      this.formTarget.requestSubmit()
      return
    }
    const first = this.#results()[0]
    if (event.key === "Enter" && first) {
      event.preventDefault()
      first.click()
      return
    }
    if (event.key !== "ArrowDown" || !first) return
    event.preventDefault()
    first.focus()
  }

  resultKeydown(event) {
    if (!["ArrowDown", "ArrowUp"].includes(event.key)) return
    const results = this.#results()
    const current = results.indexOf(event.currentTarget)
    const next = event.key === "ArrowDown" ? results[current + 1] : results[current - 1]
    event.preventDefault()
    if (next) next.focus()
    else this.inputTarget.focus()
  }

  // Only plain links are remembered: a result that posts (a new direct chat) is an action, not a place.
  remember(event) {
    const link = event.currentTarget
    if (link.dataset.turboMethod) return
    const entry = { href: link.getAttribute("href"), title: link.dataset.title, meta: link.dataset.meta, icon: link.dataset.icon }
    if (!INTERNAL_PATH.test(entry.href || "")) return
    const recents = [entry, ...this.#recents().filter((item) => item.href !== entry.href)].slice(0, RECENTS_LIMIT)
    try {
      localStorage.setItem(this.#recentsKey(), JSON.stringify(recents))
    } catch (_error) {
      // Private windows and blocked storage: recents are a convenience, search keeps working.
    }
  }

  #renderRecents() {
    if (!this.hasRecentsTarget) return
    const recents = this.inputTarget.value.trim() === "" ? this.#recents() : []
    this.recentsListTarget.replaceChildren(...recents.map((entry) => this.#recentLink(entry)))
    this.recentsTarget.hidden = recents.length === 0
  }

  // Built with DOM nodes and textContent: stored values never become markup.
  #recentLink(entry) {
    const link = document.createElement("a")
    link.href = entry.href
    link.className = "flex items-center gap-3 px-3 py-2 text-left hover:bg-stone-50 dark:hover:bg-zinc-800 focus-visible:outline-none focus-visible:bg-indigo-50 dark:focus-visible:bg-indigo-500/15 focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-indigo-600"
    link.dataset.globalSearchResult = ""
    link.dataset.action = "keydown->ui--global-search#resultKeydown"
    link.dataset.test = "global-search-recent"
    const badge = document.createElement("span")
    badge.className = "inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-md bg-stone-100 dark:bg-zinc-800 text-gray-500 dark:text-zinc-400"
    badge.setAttribute("aria-hidden", "true")
    badge.append(this.#recentIcon(entry.icon))
    const text = document.createElement("span")
    text.className = "min-w-0"
    const title = document.createElement("span")
    title.className = "block truncate text-[13px] font-medium text-zinc-900 dark:text-zinc-100"
    title.textContent = entry.title || entry.href
    const meta = document.createElement("span")
    meta.className = "mt-0.5 block truncate font-mono text-[10px] text-gray-500 dark:text-zinc-400"
    meta.textContent = entry.meta || ""
    text.append(title, meta)
    link.append(badge, text)
    return link
  }

  // A stored name the icon templates do not hold (or a malformed one) falls back to the history icon.
  #recentIcon(name) {
    if (/^[a-z0-9-]+$/.test(name || "")) {
      try {
        return icon(name, "text-[12px]")
      } catch (_error) {
        // Not in shared/_icon_templates: fall through to the default.
      }
    }
    return icon("history", "text-[12px]")
  }

  #recents() {
    try {
      const parsed = JSON.parse(localStorage.getItem(this.#recentsKey()) || "[]")
      return Array.isArray(parsed) ? parsed.filter((item) => typeof item?.href === "string" && INTERNAL_PATH.test(item.href)) : []
    } catch (_error) {
      return []
    }
  }

  #recentsKey() {
    return this.dialogTarget.dataset.recentsKey || "cyi-search-recents"
  }

  #handleGlobalKeydown(event) {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
      event.preventDefault()
      this.open()
    }
  }

  #results() {
    return Array.from(this.dialogTarget.querySelectorAll("[data-global-search-result]"))
      .filter((element) => element.offsetParent !== null)
  }

  #setExpanded(open) {
    this.triggerTargets.forEach((trigger) => trigger.setAttribute("aria-expanded", open ? "true" : "false"))
  }
}
