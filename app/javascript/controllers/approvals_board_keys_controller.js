import { Controller } from "@hotwired/stimulus"

// CYRA-899 — the approvals board from the keyboard: j/k move between rows, Enter opens the focused
// row, a approves it, x ticks its checkbox. Same guards as decision_keys_controller: no modifiers,
// nothing while typing. Also opens and closes the preview row under each row.
export default class extends Controller {
  static targets = ["row"]

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
      case "j": this.#move(1); break
      case "k": this.#move(-1); break
      case "Enter": if (!this.#click("approvals-board-decide")) return; break
      case "a": if (!this.#click("approvals-row-approve")) return; break
      case "x": if (!this.#tick()) return; break
      default: return
    }
    event.preventDefault()
  }

  togglePreview(event) {
    this.#toggle(event.currentTarget)
  }

  // CYRA-904 — a click on the row itself opens the preview; links, buttons and checkboxes keep theirs.
  openFromRow(event) {
    if (event.target.closest("a, button, input, label, summary, details")) return

    const button = event.currentTarget.querySelector('[data-test="approvals-row-preview-toggle"]')
    if (button) this.#toggle(button)
  }

  // CYRA-904 — ticks every row of one group that has no report, ready for the bulk approve.
  selectBare({ params: { group } }) {
    this.rowTargets
      .filter((row) => row.dataset.rowGroupKey === group)
      .flatMap((row) => [ ...row.querySelectorAll('input[type="checkbox"][data-no-report="true"]') ])
      .filter((box) => !box.checked)
      .forEach((box) => {
        box.checked = true
        box.dispatchEvent(new Event("change", { bubbles: true }))
      })
  }

  #toggle(button) {
    const preview = button.closest("tr")?.nextElementSibling
    if (preview?.dataset.test !== "approvals-row-preview") return

    const open = button.getAttribute("aria-expanded") !== "true"
    button.setAttribute("aria-expanded", String(open))
    button.querySelector("i")?.classList.toggle("rotate-90", open)
    preview.hidden = !open
  }

  // Only rows the reader can see: a closed group keeps its rows out of the way.
  #move(step) {
    const rows = this.rowTargets.filter((row) => !row.hidden)
    if (rows.length === 0) return

    const index = rows.indexOf(this.#focusedRow())
    const next = index === -1 ? (step > 0 ? 0 : rows.length - 1) : Math.min(Math.max(index + step, 0), rows.length - 1)
    rows[next].focus()
    rows[next].scrollIntoView({ block: "nearest" })
  }

  // Enter, a and x act on the focused ROW only: on a focused link or button the browser keeps its own.
  #focusedRow() {
    return this.rowTargets.find((row) => row === document.activeElement) || null
  }

  #click(testId) {
    const button = this.#focusedRow()?.querySelector(`[data-test="${testId}"]`)
    if (!button) return false

    button.click()
    return true
  }

  #tick() {
    const box = this.#focusedRow()?.querySelector('input[type="checkbox"]')
    if (!box) return false

    box.checked = !box.checked
    box.dispatchEvent(new Event("change", { bubbles: true }))
    return true
  }

  #typing(el) {
    if (!el) return false
    return [ "INPUT", "TEXTAREA", "SELECT" ].includes(el.tagName) || el.isContentEditable
  }
}
