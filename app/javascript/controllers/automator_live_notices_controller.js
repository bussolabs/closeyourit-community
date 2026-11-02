import { Controller } from "@hotwired/stimulus"

// CYRA-1139 — the conflict notices of a live session. Closing one hides it for that conflict until the tab is
// closed: the frame reloads with every new step, and a notice the person closed must not come back each time.
// Two or more notices stack like a deck (CSS in application.css); one left alone stops stacking.
const STORAGE_KEY = "automator-live:closed-conflicts"

export default class extends Controller {
  static targets = ["notice", "counter"]

  connect() {
    const closed = this.closed()
    this.noticeTargets.filter((notice) => closed.has(notice.dataset.key)).forEach((notice) => notice.remove())
    this.refresh()
  }

  dismiss(event) {
    const notice = event.target.closest("[data-key]")
    const closed = this.closed()
    closed.add(notice.dataset.key)
    try { sessionStorage.setItem(STORAGE_KEY, JSON.stringify([...closed])) } catch { /* private mode: closes for now only */ }
    notice.remove()
    this.refresh()
  }

  refresh() {
    const left = this.noticeTargets.length
    this.element.classList.toggle("is-stacked", left > 1)
    if (this.hasCounterTarget) this.counterTarget.hidden = left < 2
    this.element.hidden = left === 0
  }

  closed() {
    try { return new Set(JSON.parse(sessionStorage.getItem(STORAGE_KEY) || "[]")) } catch { return new Set() }
  }
}
