import { Controller } from "@hotwired/stimulus"

// Base condivisa della logica TASTIERA dei board Kanban (ticket-board, workload-board): estratta
// perché le due implementazioni erano ~130 righe pressoché identiche (review T8). Comportamento
// INVARIATO — solo dedup, nessun cambio di UX.
//
// Oltre al drag di mouse (che resta nel controller concreto), la board è operabile da TASTIERA
// (a11y, WP2.9): le frecce su/giù muovono il focus tra le card di una colonna (roving tabindex);
// Spazio/Invio "prende" la card, le frecce sinistra/destra la spostano nella colonna adiacente
// (anteprima), Spazio/Invio la rilascia e Esc annulla. Il rilascio persiste con la STESSA fetch del
// drop di mouse (persistMove, definito nel controller concreto) — nessuna logica di persistenza
// duplicata qui. Lo stato "presa" è comunicato agli AT in modo PERSISTENTE tramite l'aria-label
// della card stessa (MAI aria-grabbed, deprecato in ARIA 1.1) — non solo un annuncio one-shot: la
// card presa espone titolo+istruzioni finché non viene rilasciata/annullata. Ogni passo è ANCHE
// annunciato in una live region aria-live=polite (target `live`), a complemento non in sostituzione.
//
// Contratto per i controller concreti che estendono questa classe:
// - dichiarano `static targets = ["column", "card", "live"]` e i `static values` (canManage,
//   grabbedLabel, grabbedMessage, movingMessage, droppedMessage, cancelledMessage) — invariati,
//   Stimulus li risolve sull'identifier con cui il figlio è REGISTRATO (es. "ticket-board");
// - implementano `persistMove(card, column)` (fetch di persistenza — URL/param diversi per dominio:
//   ticket usa `status_id`, workload usa `status` — riusata sia dal drop di mouse sia dal rilascio
//   da tastiera via `drop()` qui sotto);
// - implementano `refresh`/`syncEmpty`/`cardCount` (contatore colonna, selettore `data-test`
//   diverso per dominio) e la logica di drag-mouse (`bindDrag`/`onDrop`/`moveCard`/*TargetConnected).
//
// `cardsIn` usa `this.identifier` — Stimulus lo imposta automaticamente all'identifier con cui il
// controller concreto è registrato ("ticket-board"/"workload-board", uguale a quanto Stimulus usa
// già internamente per risolvere `data-<identifier>-target`) — quindi il selettore si costruisce da
// solo, senza bisogno di un override esplicito per ogni figlio.
export default class extends Controller {
  bindKeyboard(card) {
    if (card.keyboardBound) return
    card.keyboardBound = true
    card.addEventListener("keydown", (event) => this.onKeydown(event, card))
    // Se il focus lascia davvero una card presa (Tab/click altrove), annulla la presa e ripristina.
    card.addEventListener("blur", () => this.onCardBlur(card))
  }

  onKeydown(event, card) {
    const grabbed = this.grabbed === card
    switch (event.key) {
      case " ":
      case "Spacebar":
      case "Enter":
        // Preso → rilascia. Altrimenti prende (solo chi può gestire); ai lettori il resto del tasto
        // resta nativo (Invio apre il ticket, Spazio scrolla) — enhancement progressivo.
        if (grabbed) { event.preventDefault(); this.drop(card) }
        else if (this.canManageValue) { event.preventDefault(); this.grab(card) }
        break
      case "Escape":
        if (grabbed) { event.preventDefault(); this.cancelGrab() }
        break
      case "ArrowRight":
        if (grabbed) { event.preventDefault(); this.moveGrabbed(card, 1) }
        break
      case "ArrowLeft":
        if (grabbed) { event.preventDefault(); this.moveGrabbed(card, -1) }
        break
      case "ArrowDown":
        event.preventDefault()
        if (!grabbed) this.moveFocus(card, 1)
        break
      case "ArrowUp":
        event.preventDefault()
        if (!grabbed) this.moveFocus(card, -1)
        break
    }
  }

  grab(card) {
    this.grabbed = card
    this.grabOrigin = this.columnOf(card)
    // aria-grabbed è deprecato (ARIA 1.1): lo stato "presa" persiste per gli AT nell'accessible name
    // della card (aria-label), non in un attributo di stato dedicato. Rimosso al rilascio/annullo.
    card.setAttribute("aria-label", this.format(this.grabbedLabelValue, { title: this.titleOf(card) }))
    card.classList.add("ring-2", "ring-indigo-400", "ring-offset-1")
    this.announce(this.format(this.grabbedMessageValue, { title: this.titleOf(card) }))
  }

  // Rilascio: la card è già nella colonna di destinazione (spostata in anteprima dalle frecce).
  // Se non ha cambiato colonna → nessun PATCH. Altrimenti persiste con la STESSA fetch del mouse.
  drop(card) {
    const origin = this.grabOrigin
    const column = this.columnOf(card)
    this.release(card)
    if (!column || column === origin) {
      this.announce(this.format(this.cancelledMessageValue, { title: this.titleOf(card), status: this.statusLabelOf(origin) }))
      this.focusCard(card, column || origin)
      return
    }
    // The arrows already moved the card: moveCard must count it out of the column it was grabbed in.
    card.boardOrigin = origin
    this.persistMove(card, column)
    this.announce(this.format(this.droppedMessageValue, { status: this.statusLabelOf(column) }))
    this.focusCard(card, column)
  }

  // Anteprima: sposta la card presa nella colonna adiacente (senza PATCH) e la annuncia.
  moveGrabbed(card, direction) {
    const current = this.columnOf(card)
    const columns = this.columnTargets
    const next = columns[columns.indexOf(current) + direction]
    if (!next) return // bordo della board: nessuna colonna adiacente
    next.querySelector("[data-board-list]").appendChild(card)
    this.refresh(current)
    this.refresh(next)
    this.focusCard(card, next)
    this.announce(this.format(this.movingMessageValue, { title: this.titleOf(card), status: this.statusLabelOf(next) }))
  }

  cancelGrab() {
    const card = this.grabbed
    if (!card) return
    const origin = this.grabOrigin
    const current = this.columnOf(card)
    this.release(card)
    if (origin && current && current !== origin) {
      origin.querySelector("[data-board-list]").appendChild(card)
      this.refresh(current)
      this.refresh(origin)
    }
    this.announce(this.format(this.cancelledMessageValue, { title: this.titleOf(card), status: this.statusLabelOf(origin) }))
    this.focusCard(card, origin || current)
  }

  release(card) {
    card.removeAttribute("aria-label")
    card.classList.remove("ring-2", "ring-indigo-400", "ring-offset-1")
    this.grabbed = null
    this.grabOrigin = null
  }

  onCardBlur(card) {
    if (this.grabbed !== card) return
    // Uno spostamento programmato (frecce) blura e rifocalizza la card nello stesso tick: rimanda il
    // controllo e annulla la presa SOLO se il focus è davvero uscito dalla card presa.
    setTimeout(() => {
      if (this.grabbed === card && document.activeElement !== card) this.cancelGrab()
    }, 0)
  }

  moveFocus(card, direction) {
    const column = this.columnOf(card)
    if (!column) return
    const cards = this.cardsIn(column)
    const next = cards[cards.indexOf(card) + direction]
    if (next) this.focusCard(next, column)
  }

  // Un solo tabstop per colonna (roving): preserva la card già tabbabile se ancora presente,
  // altrimenti la prima → si entra in ogni colonna con Tab e si naviga con le frecce.
  resetRoving(column) {
    const cards = this.cardsIn(column)
    if (cards.length === 0) return
    const active = cards.find((card) => card.getAttribute("tabindex") === "0") || cards[0]
    cards.forEach((card) => card.setAttribute("tabindex", card === active ? "0" : "-1"))
  }

  focusCard(card, column) {
    if (column) this.cardsIn(column).forEach((c) => c.setAttribute("tabindex", c === card ? "0" : "-1"))
    card.focus()
  }

  columnOf(el) {
    return this.columnTargets.find((column) => column.contains(el))
  }

  // Card di una colonna, nell'identifier del controller CONCRETO (this.identifier = "ticket-board" /
  // "workload-board", assegnato da Stimulus alla registrazione) — equivalente al selettore hardcoded
  // che ciascun controller aveva prima dell'estrazione.
  cardsIn(column) {
    return Array.from(column.querySelectorAll(`[data-${this.identifier}-target='card']`))
  }

  titleOf(card) {
    return card.dataset.title || ""
  }

  statusLabelOf(column) {
    return column && column.dataset.statusLabel ? column.dataset.statusLabel : ""
  }

  announce(message) {
    if (this.hasLiveTarget) this.liveTarget.textContent = message
  }

  // Interpola i template i18n con placeholder {chiave} (Rails non tocca le graffe singole).
  format(template, vars) {
    let out = template || ""
    for (const key in vars) out = out.split("{" + key + "}").join(vars[key])
    return out
  }

  get csrfToken() {
    const meta = document.querySelector("meta[name='csrf-token']")
    return meta ? meta.content : ""
  }
}
