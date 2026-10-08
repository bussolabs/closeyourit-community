import { Controller } from "@hotwired/stimulus"

// CYRA-1059 — Approve and Retry on a board row run without reloading. Turbo cancels the pending
// request at every new submission, so each click is a fetch of its own: the row dims at once, the
// server's stream removes it (or a message says why not), then only the header counters reload
// and its group's count goes down by one (the group header goes with its last row).
// Without JavaScript the forms still post and redirect as before.
export default class extends Controller {
  static values = { forms: Array, countsFrame: String, countLabels: Object }

  submit(event) {
    const form = event.target
    const button = event.submitter
    const row = button?.closest("tr")
    if (!this.formsValue.includes(form.id) || !row) return

    event.preventDefault()
    this.#run(form, button, row)
  }

  async #run(form, button, row) {
    const body = new FormData(form, button)
    let removed = false
    this.#busy(row, button, true)
    try {
      const response = await fetch(button.getAttribute("formaction") || form.action, {
        method: "POST",
        body,
        credentials: "same-origin",
        headers: { Accept: "text/vnd.turbo-stream.html", "X-CSRF-Token": this.#csrf() },
      })
      const html = await response.text()
      if (response.headers.get("Content-Type")?.startsWith("text/vnd.turbo-stream.html")) {
        // Turbo removes the row on a later frame, so the answer itself says whether it goes.
        removed = html.includes(`target="${row.id}"`)
        window.Turbo?.renderStreamMessage?.(html)
      }
    } catch {
      // Network failure: the row simply comes back below.
    }
    if (removed) this.#lowerGroupCount(row.dataset.rowGroupKey)
    else this.#busy(row, button, false)
    this.#refreshCounts()
  }

  #busy(row, button, on) {
    row.toggleAttribute("aria-busy", on)
    row.classList.toggle("opacity-50", on)
    row.classList.toggle("pointer-events-none", on)
    button.disabled = on
  }

  #lowerGroupCount(key) {
    const header = key && this.element.querySelector(`tr[data-row-group-header="${CSS.escape(key)}"]`)
    const count = header?.querySelector("[data-row-group-count]")
    if (!count) return

    const left = parseInt(count.textContent.replace(/\D/g, ""), 10) - 1
    if (!(left > 0)) return header.remove()

    const { one, other } = this.countLabelsValue
    count.textContent = left === 1 ? one : other.replace("%{count}", left)
  }

  #refreshCounts() {
    const frame = document.getElementById(this.countsFrameValue)
    if (!frame) return

    if (frame.src === window.location.href) frame.reload()
    else frame.src = window.location.href
  }

  #csrf() {
    return document.querySelector('meta[name="csrf-token"]')?.content
  }
}
