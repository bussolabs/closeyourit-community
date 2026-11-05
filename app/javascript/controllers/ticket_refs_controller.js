import { Controller } from "@hotwired/stimulus"

// CYRA-1148 — ticket codes in rendered text arrive as placeholders holding only the code. This collects
// every placeholder of the page, asks once for the ones the reader can see, and swaps in the label.
// Placeholders added later (a comment or chat message arriving live) are batched the same way.
export default class extends Controller {
  static targets = ["ref"]
  static values = { url: String }

  refTargetConnected() {
    if (this.scheduled) return

    this.scheduled = true
    setTimeout(() => this.fill(), 0)
  }

  async fill() {
    this.scheduled = false
    const pending = this.refTargets.filter((ref) => !("ticketRefsAsked" in ref.dataset))
    pending.forEach((ref) => { ref.dataset.ticketRefsAsked = "" })
    const codes = [...new Set(pending.map((ref) => ref.dataset.code))]
    if (codes.length === 0) return

    const url = new URL(this.urlValue, window.location.origin)
    url.searchParams.set("codes", codes.join(","))
    const labels = await this.fetchLabels(url)

    pending.forEach((ref) => {
      const label = labels[ref.dataset.code]
      if (label && ref.isConnected) ref.outerHTML = label
    })
  }

  // A failed request leaves the codes as plain text, which is what a hidden ticket shows anyway.
  async fetchLabels(url) {
    try {
      const response = await fetch(url, { headers: { Accept: "application/json" } })
      return response.ok ? (await response.json()).data : {}
    } catch {
      return {}
    }
  }
}
