import { Controller } from "@hotwired/stimulus"

// Riordino drag-drop degli elementi di guidance (references o procedures) di un livello. Trascinando una
// riga la si sposta nel DOM in modo ottimistico, poi si PATCHa urlValue con l'ordine corrente degli id
// (ordered_ids[]); il server persiste solo la posizione (Guidance::Reorder). Progressive enhancement:
// senza JS le righe restano ordinate dalla posizione salvata. Gemello di todo_reorder_controller.
export default class extends Controller {
  static targets = ["item"]
  static values = { url: String }

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
    if (!dragged || dragged === target) return
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
