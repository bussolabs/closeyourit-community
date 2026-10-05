import { Controller } from "@hotwired/stimulus"

// Riordino drag-drop delle voci di una lista di todo. Trascinando una voce la si sposta nel DOM in
// modo ottimistico, poi si PATCHa urlValue con l'ordine corrente degli id (ordered_ids[]); il server
// persiste solo la posizione. Progressive enhancement: senza JS le voci restano ordinate dalla
// posizione salvata (non riordinabili). Pattern ridotto di ticket_board_controller (singola colonna).
export default class extends Controller {
  static targets = ["item"]
  static values = { url: String }

  // A tick re-renders the whole block by morph: keep what the person opened (the Completed group, a
  // rename being typed) instead of closing it under their hands.
  connect() {
    this.keepOpen = (event) => {
      const { attributeName, mutationType } = event.detail
      if (event.target.tagName === "DETAILS" && attributeName === "open" && mutationType === "remove") event.preventDefault()
    }
    this.keepTyping = (event) => {
      if (event.target.matches?.("details[data-test='todo-item-rename'][open]")) event.preventDefault()
    }
    this.element.addEventListener("turbo:before-morph-attribute", this.keepOpen)
    this.element.addEventListener("turbo:before-morph-element", this.keepTyping)
  }

  disconnect() {
    this.element.removeEventListener("turbo:before-morph-attribute", this.keepOpen)
    this.element.removeEventListener("turbo:before-morph-element", this.keepTyping)
  }

  itemTargetConnected(item) {
    if (item.dragBound) return
    item.dragBound = true
    item.draggable = true
    item.addEventListener("dragstart", (event) => {
      this.dragged = item
      event.dataTransfer.effectAllowed = "move"
    })
    item.addEventListener("dragover", (event) => {
      event.preventDefault()
      event.dataTransfer.dropEffect = "move"
    })
    item.addEventListener("drop", (event) => this.onDrop(event, item))
    item.addEventListener("dragend", () => { this.dragged = null })
  }

  onDrop(event, target) {
    event.preventDefault()
    const dragged = this.dragged
    // Open and completed items are two groups: dropping across them would fake a state change.
    if (!dragged || dragged === target || dragged.parentNode !== target.parentNode) return
    const rect = target.getBoundingClientRect()
    const after = event.clientY > rect.top + rect.height / 2
    target.parentNode.insertBefore(dragged, after ? target.nextSibling : target)
    this.persist()
  }

  persist() {
    const body = new URLSearchParams()
    this.itemTargets.forEach((el) => body.append("ordered_ids[]", el.dataset.id))
    fetch(this.urlValue, {
      method: "PATCH",
      headers: { "X-CSRF-Token": this.csrfToken, "Content-Type": "application/x-www-form-urlencoded" },
      body: body.toString()
    })
  }

  get csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content
  }
}
