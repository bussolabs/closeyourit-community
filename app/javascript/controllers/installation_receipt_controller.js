import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["form", "button", "result"]
  static values = { pending: String, unchecked: String, loading: String, error: String, received: String }

  disconnect() { this.invalidateRequest() }

  reset() {
    this.invalidateRequest()
    this.buttonTarget.disabled = false
    this.resultTarget.textContent = this.uncheckedValue
  }

  invalidateRequest() {
    const previous = this.request
    this.request = null
    previous?.abort()
  }

  async check(event) {
    event.preventDefault()
    if (!this.formTarget.reportValidity()) return
    this.request?.abort()
    const request = new AbortController()
    this.request = request
    this.buttonTarget.disabled = true
    this.resultTarget.textContent = this.loadingValue
    const timeout = setTimeout(() => request.abort(), 10000)
    try {
      const url = new URL(this.formTarget.action)
      url.search = new URLSearchParams(new FormData(this.formTarget)).toString()
      const response = await fetch(url, { headers: { Accept: "application/json" }, credentials: "same-origin", signal: request.signal })
      const text = await response.text()
      if (text.length > 4096 || !response.headers.get("Content-Type")?.includes("application/json")) throw new Error("Invalid receipt response")
      const result = JSON.parse(text)
      if (this.request !== request) return
      if (!response.ok) {
        this.resultTarget.textContent = result.error?.message || this.errorValue
      } else if (result.data?.state === "received" && result.data.received_at) {
        this.resultTarget.textContent = `${this.receivedValue} ${result.data.received_at} · ${result.data.environment} · ${result.data.release}`
      } else if (result.data?.state === "pending") {
        this.resultTarget.textContent = this.pendingValue
      } else throw new Error("Unknown receipt state")
    } catch (_) {
      if (this.request === request) this.resultTarget.textContent = this.errorValue
    } finally {
      clearTimeout(timeout)
      if (this.request === request) this.buttonTarget.disabled = false
    }
  }
}
