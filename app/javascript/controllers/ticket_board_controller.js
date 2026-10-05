import BoardKeyboardController from "controllers/board_keyboard_controller"

// Board Kanban realtime. Trascinando una card su un'altra colonna parte un PATCH dello status del
// ticket; la card si sposta in modo ottimistico e il service Ticketing::ChangeStatus manda un
// page-refresh Turbo sullo stream della board di QUEL progetto → le altre sessioni che il progetto
// lo vedono ri-fetchano la board e morphano, ognuna scopata sui propri progetti (CYRA-257). I
// callback *TargetConnected agganciano i listener e sincronizzano lo stato-vuoto anche sulle card
// che il morph rimpiazza (che un solo connect() non vedrebbe).
//
// Il grab/move/drop/cancel da tastiera + roving tabindex + live-region (a11y, WP2.9) sono nella base
// condivisa `BoardKeyboardController` (board_keyboard_controller.js, gemella di workload-board) — qui
// restano solo drag di mouse, persistenza (persistMove) e refresh contatori, che differiscono per
// dominio (param `status_id` vs `status`, selettori `data-test` del contatore).
//
// draggable è deciso PER-VIEWER da canManageValue (la board lo passa); senza il value vale
// l'attributo `draggable` del markup. Lo stato-bound è
// memorizzato su proprietà expando (boardColumn/dragBound/dropBound/keyboardBound) così i broadcast
// possono ri-connettere lo stesso nodo senza doppi listener.
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
    // Memorizza la colonna ORA: a card rimossa (broadcast remove) closest() non risale più, ma serve
    // per ri-sincronizzare lo stato-vuoto della colonna sorgente in cardTargetDisconnected.
    card.boardColumn = card.closest("[data-ticket-board-target='column']")
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

  // draggable per-viewer (canManageValue, altrimenti l'attributo del markup). Aggancia i listener una
  // sola volta — i broadcast possono ri-connettere lo stesso nodo. setData + effectAllowed sono
  // obbligatori: senza, Firefox/Safari annullano il drag e le card <a href> vengono trascinate come
  // link nativo invece che spostate.
  bindDrag(card) {
    const canManage = this.hasCanManageValue
      ? this.canManageValue
      : card.getAttribute("draggable") === "true"
    if (this.hasCanManageValue) card.draggable = canManage
    if (!canManage || card.dragBound) return
    card.dragBound = true
    card.addEventListener("dragstart", (event) => {
      this.dragged = card
      event.dataTransfer.setData("text/plain", card.dataset.ticketId)
      event.dataTransfer.effectAllowed = "move"
    })
    card.addEventListener("dragend", () => { this.dragged = null })
  }

  onDrop(event, column) {
    event.preventDefault()
    const card = this.dragged
    this.dragged = null
    if (!card) return
    if (card.closest("[data-ticket-board-target='column']") === column) return
    this.persistMove(card, column)
  }

  // Persistenza CONDIVISA dal drop di mouse E dal rilascio da tastiera: PATCH dello status →
  // spostamento ottimistico (moveCard, idempotente) o reload su errore. Unico punto in cui il cambio
  // stato viene persistito lato board — NON duplicare questa fetch altrove.
  persistMove(card, column) {
    const url = `/member/tickets/${card.dataset.ticketId}/status?status_id=${column.dataset.statusId}`
    return fetch(url, { method: "PATCH", headers: { "X-CSRF-Token": this.csrfToken, Accept: "application/json" } })
      .then((response) => (response.ok ? this.moveCard(card, column) : window.location.reload()))
      .catch(() => window.location.reload())
  }

  // Spostamento ottimistico idempotente: se la card è già nella lista destinazione non la ri-appende
  // (niente doppi-append). Le altre sessioni si riconciliano col page-refresh morph che il service
  // manda sullo stream del progetto (Ticketing::StatusBroadcasts): ognuna ri-fetcha la propria board.
  moveCard(card, column) {
    // Card lasciata su una colonna RIDOTTA o mostrata a pezzi: la si riapre (e la scelta si ricorda)
    // così il ticket spostato resta a vista — «il gesto funziona sempre, il risultato resta visibile»
    // (CYRA-390). La card entra in fondo alla lista già renderizzata, quindi è nel DOM e visibile
    // anche quando la colonna era paginata.
    if (this.isCollapsed(column)) this.expandColumn(column)
    const source = card.boardOrigin || card.closest("[data-ticket-board-target='column']")
    delete card.boardOrigin
    const list = column.querySelector("[data-board-list]")
    if (card.parentElement !== list) list.appendChild(card)
    if (source && source !== column) { this.bumpCount(source, -1); this.refresh(source) }
    this.bumpCount(column, 1)
    this.refresh(column)
  }

  // Anteprima da tastiera (frecce): se la colonna adiacente è ridotta, la si riapre PRIMA che la base
  // vi appenda la card, altrimenti l'anteprima finirebbe in un corpo nascosto e il focus non si
  // vedrebbe (CYRA-390). Il resto della logica di anteprima resta nella base condivisa.
  moveGrabbed(card, direction) {
    const columns = this.columnTargets
    const next = columns[columns.indexOf(this.columnOf(card)) + direction]
    if (next && this.isCollapsed(next)) this.expandColumn(next)
    super.moveGrabbed(card, direction)
  }

  // Riduci/espandi la colonna del bottone premuto (header ridotto o barra della colonna chiusa).
  toggleCollapse(event) {
    const column = event.currentTarget.closest("[data-ticket-board-target='column']")
    if (!column) return
    this.isCollapsed(column) ? this.expandColumn(column) : this.collapseColumn(column)
  }

  isCollapsed(column) {
    return column.dataset.collapsed === "true"
  }

  collapseColumn(column) {
    if (this.isCollapsed(column)) return
    column.dataset.collapsed = "true"
    this.persistCollapse(column, true)
  }

  expandColumn(column) {
    if (!this.isCollapsed(column)) return
    column.dataset.collapsed = "false"
    this.persistCollapse(column, false)
    this.resetRoving(column)
  }

  // Persiste la scelta di colonna ridotta sull'account (CYRA-390): POST collassa, DELETE espande. È
  // solo una preferenza UI — un errore non deve rompere il gesto, quindi si ignora in silenzio (il
  // DOM è già aggiornato; alla peggio la scelta non viene ricordata). Nessun code → niente da salvare.
  persistCollapse(column, collapsed) {
    // K12 — a column the search collapsed is not the person's choice: the first toggle is never saved.
    if (column.dataset.autoCollapsed === "true") { delete column.dataset.autoCollapsed; return }
    const code = column.dataset.statusCode
    if (!code) return
    const base = "/member/tickets/columns"
    const url = collapsed ? `${base}?code=${encodeURIComponent(code)}` : `${base}/${encodeURIComponent(code)}`
    fetch(url, { method: collapsed ? "POST" : "DELETE", headers: { "X-CSRF-Token": this.csrfToken } }).catch(() => {})
  }

  // Stato-vuoto + roving dopo uno spostamento. Il conteggio di colonna NON si ricalcola dalle card nel
  // DOM: è il TOTALE reale dello stato (CYRA-390), non le card mostrate — che sono una finestra
  // paginata — e ricontare il DOM ricreerebbe la bugia dei contatori. L'aggiustamento ottimistico è
  // ±1 (bumpCount); il numero autorevole torna col page-refresh, reso sullo scope di chi guarda.
  refresh(column) {
    this.syncEmpty(column)
    this.resetRoving(column)
  }

  // Aggiustamento ottimistico del conteggio di colonna di ±1: parte dal totale reale renderizzato e lo
  // incrementa/decrementa, senza mai ricontare le card nel DOM (una finestra). Testo non numerico →
  // non tocca nulla (fail-safe).
  bumpCount(column, delta) {
    // K11 — while a search is on the head reads "found / total": both numbers move with the card.
    column.querySelectorAll("[data-test^='board-count-'], [data-board-collapsed-count], [data-board-total]").forEach((counter) => {
      const current = parseInt(counter.textContent.trim(), 10)
      if (!Number.isNaN(current)) counter.textContent = Math.max(0, current + delta)
    })
  }

  syncEmpty(column) {
    const empty = column.querySelector("[data-board-empty]")
    if (empty) empty.hidden = this.cardCount(column) > 0
  }

  cardCount(column) {
    return column.querySelectorAll("[data-ticket-board-target='card']").length
  }
}
