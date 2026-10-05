import { Controller } from "@hotwired/stimulus"
import { icon } from "lib/icon"

// Suggerimento duplicati mentre si crea un ticket. Vive sul FORM (non sul campo titolo): deve
// mandare al server tutti i campi, perché il testo che si misura qui dev'essere lo stesso che il
// server misura al salvataggio — altrimenti il pannello dice una percentuale e il salvataggio si
// comporta come se ne avesse letta un'altra.
//
// Il pannello non è più solo informativo: ogni riga ha una casella `link_ticket_ids[]` che, spuntata,
// fa nascere il ticket già collegato a quello. Da qui tre regole che non si possono allentare:
//
//  1. una riga spuntata NON sparisce mai — nemmeno se scende sotto soglia o esce dalla lista mentre
//     si continua a scrivere: toglierla butterebbe via in silenzio una decisione già presa;
//  2. un errore o il servizio giù nascondono i suggerimenti, MAI le spunte;
//  3. le risposte arrivano fuori ordine: vale solo l'ultima richiesta partita, altrimenti un elenco
//     vecchio può tornare a coprire quello nuovo.
//
// Progressive enhancement invariato: senza JS nessun pannello e nessuna casella, e il confronto
// lato server continua a fare il suo lavoro.
export default class extends Controller {
  static targets = ["panel", "list", "restored"]
  static values = { url: String, minChars: { type: Number, default: 8 } }

  connect() {
    this.selected = new Set()
    this.known = new Map()
    // Spunte tornate indietro da un errore di validazione. Il controller le adotta, e i campi
    // nascosti che le portavano spariscono solo quando la casella corrispondente è davvero in
    // pagina (§ paint): finché non c'è, sono loro a tenere in vita la scelta.
    //
    // Ogni campo si porta dietro codice e titolo, quindi la riga si può ridisegnare SEMPRE — anche
    // se il motore dei simili non risponde o quel ticket non è più fra i suggerimenti. È la
    // differenza fra una spunta che si vede e si può togliere e un collegamento invisibile che
    // parte comunque.
    this.restoredTargets.forEach((field) => {
      this.selected.add(field.value)
      this.known.set(field.value, {
        id: field.value,
        code: field.dataset.code,
        title: field.dataset.title,
        url: field.dataset.url,
      })
    })
    if (this.selected.size > 0) this.showSelectedOnly()
  }

  disconnect() {
    clearTimeout(this.timer)
    this.pending?.abort()
  }

  queue() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.fetchNow(), 600)
  }

  // Cambio progetto: i simili di un altro progetto non sono collegabili (il salvataggio li
  // rifiuterebbe), quindi si azzerano invece di restare spuntati a vuoto.
  projectChanged(event) {
    if (event.target.name !== "project_id") return

    this.selected.clear()
    this.known.clear()
    this.restoredTargets.forEach((field) => field.remove())
    this.lastSignature = null
    this.fetchNow()
  }

  async fetchNow() {
    if (this.title.length < this.minCharsValue || !this.projectId) {
      // Anche qui si annulla la richiesta in volo: una risposta partita col titolo lungo può
      // arrivare dopo che è stato cancellato, e rimetterebbe in pagina suggerimenti di un testo
      // che non c'è più.
      this.pending?.abort()
      this.showSelectedOnly()
      return
    }

    // Il controller sta sul form e ascolta l'uscita da OGNI campo: compilare gli scenari e le
    // condizioni vorrebbe dire una richiesta per campo, tutte con lo stesso testo. Se il form non è
    // cambiato dall'ultima volta, la risposta sarebbe identica e si tiene quella già in pagina.
    const payload = this.formPayload()
    const signature = payload.toString()
    if (signature === this.lastSignature) return

    this.pending?.abort()
    this.pending = new AbortController()
    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: { Accept: "application/json", "X-CSRF-Token": this.csrfToken },
        body: payload,
        signal: this.pending.signal,
      })
      if (!response.ok) {
        this.showSelectedOnly()
        return
      }
      // La firma si segna solo a risposta buona: un errore non deve zittire il tentativo successivo
      // sullo stesso testo.
      this.lastSignature = signature
      const body = await response.json().catch(() => ({}))
      this.render(body?.data?.tickets || [])
    } catch (error) {
      if (error.name === "AbortError") return

      this.showSelectedOnly() // servizio giù → nessun rumore, e la scelta resta
    }
  }

  // Il form intero, meno i campi che non descrivono il ticket (le spunte stesse: chiederebbero al
  // server di misurare la propria risposta precedente).
  formPayload() {
    const data = new FormData(this.element)
    const params = new URLSearchParams()
    for (const [name, value] of data.entries()) {
      if (name === "link_ticket_ids[]" || value instanceof File) continue

      params.append(name, value)
    }
    return params
  }

  render(tickets) {
    tickets.forEach((ticket) => this.known.set(ticket.id, ticket))
    // Le spuntate prima, anche quelle uscite dalla lista fresca: restano visibili finché è chi
    // scrive a toglierle.
    const fresh = tickets.filter((ticket) => !this.selected.has(ticket.id))
    const pinned = [...this.selected].map((id) => this.known.get(id)).filter(Boolean)
    this.paint([...pinned, ...fresh])
  }

  // Elenco ridotto alle sole spunte: è quello che resta quando non c'è niente da suggerire, il
  // servizio non risponde o il titolo è ancora troppo corto.
  //
  // Qui si dimentica anche l'ultima firma, e vale per TUTTI i modi in cui i suggerimenti spariscono:
  // da questo momento non sono più in pagina, quindi tornare a un testo già chiesto dev'essere una
  // richiesta nuova. Senza, chi cancella il titolo e lo riscrive uguale — o chi ci ritorna dopo che
  // il motore ha smesso di rispondere — resta senza pannello e non capisce perché.
  showSelectedOnly() {
    this.lastSignature = null
    this.paint([...this.selected].map((id) => this.known.get(id)).filter(Boolean))
  }

  paint(tickets) {
    const drawn = new Set(tickets.map((ticket) => ticket.id))
    // Un campo nascosto sparisce solo quando la sua casella è davvero in pagina: altrimenti manda
    // l'id due volte. Finché quella casella non c'è, il campo resta ed è l'unica cosa che tiene in
    // vita una spunta già decisa.
    this.restoredTargets.forEach((field) => { if (drawn.has(field.value)) field.remove() })

    if (tickets.length === 0) {
      this.panelTarget.hidden = true
      this.listTarget.replaceChildren()
      return
    }
    this.listTarget.replaceChildren(...tickets.map((ticket) => this.item(ticket)))
    this.panelTarget.hidden = false
  }

  item(ticket) {
    const li = document.createElement("li")
    const row = document.createElement("label")
    row.className = "min-w-0 flex-1 flex items-center gap-2 cursor-pointer"
    row.dataset.test = "ticket-duplicates-item"

    const box = document.createElement("input")
    box.type = "checkbox"
    box.name = "link_ticket_ids[]"
    box.value = ticket.id
    box.checked = this.selected.has(ticket.id)
    box.className = "h-3.5 w-3.5 rounded border-amber-300 dark:border-amber-500/50 text-indigo-600 dark:text-indigo-400 focus:ring-indigo-500 dark:focus:ring-indigo-400"
    box.dataset.test = `ticket-duplicates-select-${ticket.code}`
    box.addEventListener("change", () => this.toggle(ticket.id, box.checked))

    const code = document.createElement("span")
    code.className = "font-mono text-[11px] text-amber-700 dark:text-amber-300"
    code.textContent = ticket.code

    const title = document.createElement("span")
    title.className = "min-w-0 flex-1 truncate text-[12px] text-amber-900 dark:text-amber-200"
    title.textContent = ticket.title

    const similarity = document.createElement("span")
    similarity.className = "font-mono text-[10.5px] text-amber-700 dark:text-amber-300"
    similarity.textContent = ticket.similarity_label || ""

    const status = document.createElement("span")
    status.className = "text-[10.5px] uppercase tracking-wide text-amber-600 dark:text-amber-400"
    status.textContent = ticket.status_label || ""

    // Il link apre il ticket in un'altra scheda: fuori dalla label, o aprirlo spunterebbe la casella.
    // Solo icona: scritto a parole finiva accanto al nome dello stato ("OPEN open") e le due cose
    // si leggevano come una sola.
    const open = document.createElement("a")
    open.href = ticket.url
    open.target = "_blank"
    open.rel = "noopener"
    open.className = "shrink-0 text-[11px] text-amber-700 dark:text-amber-300 hover:text-amber-900 dark:hover:text-amber-200"
    open.title = this.openLabel
    open.setAttribute("aria-label", this.openLabel)
    open.append(icon("arrow-up-right-from-square"))

    row.append(box, code, title, similarity, status)
    li.append(row, open)
    li.className = "flex items-center gap-2"
    return li
  }

  toggle(id, checked) {
    if (checked) {
      this.selected.add(id)
      return
    }
    this.selected.delete(id)
    // Se per quell'id era sopravvissuto anche un campo nascosto, togliere la spunta deve togliere
    // pure quello: altrimenti il collegamento si scriverebbe lo stesso, contro la volontà di chi
    // l'ha appena tolto.
    this.restoredTargets.forEach((field) => { if (field.value === id) field.remove() })
  }

  get title() {
    return this.element.querySelector('[data-test="ticket-title"]')?.value.trim() || ""
  }

  get projectId() {
    return this.element.querySelector('[name="project_id"]')?.value || ""
  }

  get openLabel() {
    return this.panelTarget.dataset.openLabel || ""
  }

  get csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content
  }
}
