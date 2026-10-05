import { Controller } from "@hotwired/stimulus"

// Riga della matrice secret: bloccata di default (celle mascherate). Due comandi distinti, perché sono
// due permessi distinti (CYRA-721): 👁 mostra i valori senza renderli editabili (`secrets.read`), 🔓 li
// sblocca per l'editing + Salva/Annulla (`secrets.manage`). Il salvataggio è il submit del form-riga
// (associato via l'attributo HTML `form=`), non un fetch. Annulla ripristina i valori e rimaschera.
export default class extends Controller {
  static targets = ["masked", "input", "description", "lockButton", "saveButton", "cancelButton",
                    "revealButton", "hideButton"]
  static values = { open: Boolean, revealError: String }

  connect() {
    this.revealed = false
    // Riga ri-aperta dal server dopo un errore di validazione (422): mostra subito i campi in editing.
    if (this.openValue) this.unlock()
  }

  unlock() {
    this.openValue = true
    this.maskedTargets.forEach((el) => (el.hidden = true))
    this.inputTargets.forEach((el) => {
      el.hidden = false
      el.readOnly = false
    })
    this.toggle(this.lockButtonTarget, false)
    this.toggle(this.saveButtonTarget, true)
    this.toggle(this.cancelButtonTarget, true)
    // In editing i due comandi di sola lettura sparirebbero a metà strada: il valore è già scoperto e
    // «nascondi» lascerebbe la riga sbloccata con le caselle vuote. Tornano con Annulla.
    this.toggleReveal(false)
    this.toggleHide(false)
    this.inputTargets[0]?.focus()
    this.revealValues()
  }

  // 👁 — mostra i valori SENZA aprire l'editing: le caselle restano readOnly, il form-riga non c'è
  // nemmeno per chi ha il solo permesso di lettura. Chi ha entrambi i permessi può quindi guardare un
  // valore senza rischiare di riscriverlo per sbaglio.
  reveal() {
    if (this.openValue) return

    this.revealed = true
    this.maskedTargets.forEach((el) => (el.hidden = true))
    this.inputTargets.forEach((el) => {
      el.hidden = false
      el.readOnly = true
    })
    this.toggleReveal(false)
    this.toggleHide(true)
    this.revealValues()
  }

  // Rimaschera e BUTTA il valore rivelato: lasciarlo nel DOM lo terrebbe leggibile dopo il click su
  // «nascondi», che è il contrario di quello che il comando promette.
  mask() {
    this.revealed = false
    this.inputTargets.forEach((el) => {
      el.value = el.defaultValue
      el.hidden = true
    })
    this.maskedTargets.forEach((el) => (el.hidden = false))
    this.toggleReveal(true)
    this.toggleHide(false)
  }

  // CYRA-202: il textarea parte VUOTO (il valore non è nel sorgente). Allo sblocco recupera il valore
  // in chiaro dall'endpoint reveal (data-secret-reveal-url), che registra l'accesso. Le celle senza
  // valore (creabili) non hanno l'attributo → restano vuote.
  //
  // Ogni sblocco ha un token: una risposta tardiva (riga già annullata o ri-sbloccata) viene scartata.
  // Il valore rivelato è applicato SOLO se la cella è ancora vuota, così non sovrascrive mai ciò che
  // l'utente ha già digitato. Se il fetch fallisce, la cella resta vuota ma il placeholder segnala
  // l'errore (l'utente non crede che il secret sia vuoto); il save salta comunque le celle blank,
  // quindi un valore esistente non viene mai cancellato.
  async revealValues() {
    const token = (this.revealToken = (this.revealToken || 0) + 1)
    await Promise.all(this.inputTargets.map(async (el) => {
      const url = el.dataset.secretRevealUrl
      if (!url) return
      try {
        const response = await fetch(url, { headers: { Accept: "application/json" }, credentials: "same-origin" })
        if (!response.ok) throw new Error(`reveal failed: ${response.status}`)
        const data = await response.json()
        if (this.revealToken === token && this.showing && el.value === "") el.value = data.value ?? ""
      } catch {
        if (this.revealToken === token && this.hasRevealErrorValue) el.placeholder = this.revealErrorValue
      }
    }))
  }

  // La riga è scoperta sia in editing sia in sola lettura: una risposta tardiva vale in entrambi i
  // casi, e non vale più quando la riga è tornata mascherata.
  get showing() {
    return this.openValue || this.revealed
  }

  cancel() {
    this.openValue = false
    this.revealed = false
    this.inputTargets.forEach((el) => {
      el.value = el.defaultValue
      el.hidden = true
      el.readOnly = true
    })
    this.descriptionTargets.forEach((el) => {
      el.value = el.defaultValue
      el.hidden = true
    })
    this.maskedTargets.forEach((el) => (el.hidden = false))
    this.toggle(this.lockButtonTarget, true)
    this.toggle(this.saveButtonTarget, false)
    this.toggle(this.cancelButtonTarget, false)
    this.toggleReveal(true)
    this.toggleHide(false)
  }

  // Voce di menu "Modifica descrizione": sblocca la riga (se serve) e rivela il campo descrizione della
  // cella da cui è partito il click.
  toggleDescription(event) {
    if (!this.openValue) this.unlock()
    const cell = event.target.closest("td")
    const field = cell?.querySelector("[data-secret-matrix-row-target='description']")
    if (!field) return
    field.hidden = !field.hidden
    if (!field.hidden) field.focus()
  }

  toggle(el, visible) {
    if (el) el.hidden = !visible
  }

  // 👁 esiste solo per chi può leggere e 🔓 solo per chi può gestire: le due coppie di comandi vivono
  // in modo indipendente sulla stessa riga, quindi ogni cambio di stato controlla che il target ci sia
  // prima di toccarlo (Stimulus solleva sull'accesso a un target assente).
  toggleReveal(visible) {
    if (this.hasRevealButtonTarget) this.revealButtonTarget.hidden = !visible
  }

  toggleHide(visible) {
    if (this.hasHideButtonTarget) this.hideButtonTarget.hidden = !visible
  }
}
