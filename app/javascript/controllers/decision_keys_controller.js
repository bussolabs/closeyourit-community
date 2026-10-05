import { Controller } from "@hotwired/stimulus"

// Tasti della home decisioni: a approva, r apre il rifiuto, s salta, d rimanda (CYRA-862).
// Stessi guardiani di keyboard_shortcuts_controller: niente modificatori, niente mentre si scrive.
export default class extends Controller {
  connect() {
    this._onKeydown = this.handle.bind(this)
    window.addEventListener("keydown", this._onKeydown)
  }

  disconnect() {
    window.removeEventListener("keydown", this._onKeydown)
  }

  handle(event) {
    if (event.metaKey || event.ctrlKey || event.altKey) return
    if (this.#typing(event.target)) return

    switch (event.key) {
      case "a": this.#submit("approvals-approve"); break
      case "s": this.#submit("decision-skip"); break
      case "d": this.#submit("decision-defer"); break
      case "r": this.#openReject(); break
      default: return
    }
    event.preventDefault()
  }

  #submit(testId) {
    const button = this.element.querySelector(`[data-test="${testId}"]`)
    const form = button?.closest("form")
    if (form) form.requestSubmit(button.type === "submit" ? button : undefined)
    else button?.click()
  }

  #openReject() {
    this.element.querySelector('[data-test="approvals-more-choices"]')?.setAttribute("open", "")
    this.element.querySelector('[data-test="approvals-reject"]')?.setAttribute("open", "")
    this.element.querySelector('[data-test="approvals-reject-reason"]')?.focus()
  }

  #typing(el) {
    if (!el) return false
    return [ "INPUT", "TEXTAREA", "SELECT" ].includes(el.tagName) || el.isContentEditable
  }
}
