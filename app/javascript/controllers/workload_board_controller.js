import BoardKeyboardController from "controllers/board_keyboard_controller"

// Board Kanban del workload (gemello di ticket-board, per status enum). Trascinando una card su
// un'altra colonna parte un PATCH dello status della action; la card si sposta in modo ottimistico.
// A differenza della board ticket NON c'è broadcast realtime multi-utente in v1: su risposta non-ok
// si ricarica la pagina. draggable è deciso per-viewer da canManageValue.
//
// Il grab/move/drop/cancel da tastiera + roving tabindex + live-region (a11y, WP2.9) sono nella base
// condivisa `BoardKeyboardController` (board_keyboard_controller.js, gemella di ticket-board) — qui
// restano solo drag di mouse, persistenza (persistMove) e refresh contatori, che differiscono per
// dominio (param `status` vs `status_id`, selettori `data-test` del contatore).
export default class extends BoardKeyboardController {
  static targets = ["column", "card", "live"]
  static values = {
    canManage: Boolean,
    grabbedLabel: String,
    grabbedMessage: String,
    movingMessage: String,
    droppedMessage: String,
    cancelledMessage: String
  }

  columnTargetConnected(column) {
    if (column.dropBound) return
    column.dropBound = true
    column.addEventListener("dragover", (event) => {
      event.preventDefault()
      event.dataTransfer.dropEffect = "move"
    })
    column.addEventListener("drop", (event) => this.onDrop(event, column))
  }

  cardTargetConnected(card) {
    card.boardColumn = card.closest("[data-workload-board-target='column']")
    this.bindDrag(card)
    this.bindKeyboard(card)
    if (card.boardColumn) {
      this.syncEmpty(card.boardColumn)
      this.resetRoving(card.boardColumn)
    }
  }

  cardTargetDisconnected(card) {
    const column = card.boardColumn
    if (column && column.isConnected) {
      this.syncEmpty(column)
      this.resetRoving(column)
    }
  }

  // setData + effectAllowed sono obbligatori: senza, Firefox/Safari annullano il drag e le card
  // <a href> vengono trascinate come link nativo invece che spostate.
  bindDrag(card) {
    const canManage = this.hasCanManageValue
      ? this.canManageValue
      : card.getAttribute("draggable") === "true"
    if (this.hasCanManageValue) card.draggable = canManage
    if (!canManage || card.dragBound) return
    card.dragBound = true
    card.addEventListener("dragstart", (event) => {
      this.dragged = card
      event.dataTransfer.setData("text/plain", card.dataset.actionId)
      event.dataTransfer.effectAllowed = "move"
    })
    card.addEventListener("dragend", () => { this.dragged = null })
  }

  onDrop(event, column) {
    event.preventDefault()
    const card = this.dragged
    this.dragged = null
    if (!card) return
    if (card.closest("[data-workload-board-target='column']") === column) return
    this.persistMove(card, column)
  }

  // Persistenza CONDIVISA dal drop di mouse E dal rilascio da tastiera: PATCH dello status →
  // spostamento ottimistico (moveCard, idempotente) o reload su errore. Unico punto in cui il cambio
  // stato viene persistito lato board — NON duplicare questa fetch altrove.
  persistMove(card, column) {
    const url = `/member/workload/actions/${card.dataset.actionId}/status?status=${column.dataset.status}`
    return fetch(url, { method: "PATCH", headers: { "X-CSRF-Token": this.csrfToken } })
      .then((response) => (response.ok ? this.moveCard(card, column) : window.location.reload()))
      .catch(() => window.location.reload())
  }

  // Spostamento ottimistico idempotente: se la card è già nella lista destinazione non la ri-appende.
  moveCard(card, column) {
    const source = card.boardOrigin || card.closest("[data-workload-board-target='column']")
    delete card.boardOrigin
    const list = column.querySelector("[data-board-list]")
    if (card.parentElement !== list) list.appendChild(card)
    if (source && source !== column) { this.bumpTotal(source, -1); this.refresh(source) }
    this.bumpTotal(column, 1)
    this.refresh(column)
  }

  // K11 — the "/ total" of a searched column counts cards outside the search too: it moves by one.
  bumpTotal(column, delta) {
    column.querySelectorAll("[data-board-total]").forEach((total) => {
      const current = parseInt(total.textContent.trim(), 10)
      if (!Number.isNaN(current)) total.textContent = Math.max(0, current + delta)
    })
  }

  // Collapsed columns are a view choice for this page load only: nothing is saved.
  toggleCollapse(event) {
    const column = event.currentTarget.closest("[data-workload-board-target='column']")
    if (!column) return
    column.dataset.collapsed === "true" ? this.expandColumn(column) : (column.dataset.collapsed = "true")
  }

  expandColumn(column) {
    column.dataset.collapsed = "false"
    this.resetRoving(column)
  }

  // A keyboard move into a collapsed column opens it first, or the card would land in a hidden body.
  moveGrabbed(card, direction) {
    const columns = this.columnTargets
    const next = columns[columns.indexOf(this.columnOf(card)) + direction]
    if (next && next.dataset.collapsed === "true") this.expandColumn(next)
    super.moveGrabbed(card, direction)
  }

  refresh(column) {
    column.querySelectorAll("[data-test^='workload-board-count-'], [data-board-collapsed-count]")
      .forEach((counter) => { counter.textContent = this.cardCount(column) })
    this.syncEmpty(column)
    this.resetRoving(column)
  }

  syncEmpty(column) {
    const empty = column.querySelector("[data-board-empty]")
    if (empty) empty.hidden = this.cardCount(column) > 0
  }

  cardCount(column) {
    return column.querySelectorAll("[data-workload-board-target='card']").length
  }
}
