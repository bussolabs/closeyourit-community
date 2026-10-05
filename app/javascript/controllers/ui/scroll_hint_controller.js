import { Controller } from "@hotwired/stimulus"

// CYRA-351 — un contenitore che scorre in orizzontale non lo dichiara da solo: una tabella tagliata
// a metà si legge come una tabella con meno colonne, e nessuno va a cercare quello che non vede.
// Qui il bordo destro (e sinistro, dopo aver scorso) prende una sfumatura, ma SOLO quando c'è
// davvero altro da vedere: un'ombra sempre accesa sarebbe rumore.
//
// Oltre alle ombre, chi espone il target opzionale `horizontal` mostra una frase esplicita finché
// resta contenuto a destra. Il target `scroller` permette di tenere la frase fuori dall'area che
// scorre, così non sparisce insieme alle colonne.
//
// CYRA-585 — stessa cecità in verticale, ma su fondo scuro un'ombra non si vede: chi ha un elenco
// più alto della finestra (il menu laterale) aggiunge un target `more`, un elemento qualsiasi che
// resta nascosto finché non c'è davvero altro sotto. Il target è opzionale: senza, il controller si
// comporta esattamente come prima.
export default class extends Controller {
  static targets = ["more", "horizontal", "scroller"]
  // CYRA-663 — lo spazio sotto la tabella serve solo a non far coprire l'ultima riga
  // dall'indicatore «scorri». Era sempre acceso: su telefono lasciava una fascia vuota sotto
  // OGNI tabella, comprese quelle che ci stanno tutte. Ora segue l'indicatore.
  static classes = ["spazio"]

  connect() {
    if (!this.scroller) this.aggancia(this.hasScrollerTarget ? this.scrollerTarget : this.element)
  }

  disconnect() {
    this.sgancia()
  }

  // CYRA-663 — il nodo che scorre veniva preso una volta sola in connect(). Se un frame Turbo
  // sostituisce il contenuto SENZA rimuovere l'elemento di questo controller, quel nodo resta
  // staccato: il vecchio si porta dietro listener e ResizeObserver, e il nuovo non ne ha nessuno,
  // quindi l'indicatore non compare piu'. Agganciandosi ai callback del target si segue il nodo vivo.
  scrollerTargetConnected(elemento) {
    this.aggancia(elemento)
  }

  scrollerTargetDisconnected() {
    this.sgancia()
  }

  aggancia(nodo) {
    this.sgancia()
    this.scroller = nodo
    this.update()
    this.scroller.addEventListener("scroll", this.update, { passive: true })
    this.observer = new ResizeObserver(this.update)
    this.observer.observe(this.scroller)
    // Il contenitore NON cambia misura quando cambia il contenuto: un gruppo del menu che si apre lo
    // allunga a finestra ferma, e osservando solo il contenitore il segnale resterebbe spento
    // proprio nel momento in cui il taglio nasce. Quindi si osservano anche i figli.
    Array.from(this.scroller.children).forEach((figlio) => this.observer.observe(figlio))
  }

  sgancia() {
    this.scroller?.removeEventListener("scroll", this.update)
    this.observer?.disconnect()
    this.observer = null
    this.scroller = null
  }

  update = () => {
    const { scrollLeft, scrollWidth, clientWidth, scrollTop, scrollHeight, clientHeight } = this.scroller
    // Un pixel di tolleranza: gli zoom del browser producono frazioni che altrimenti tengono
    // l'ombra accesa su una tabella che sta tutta dentro.
    const more = scrollWidth - clientWidth - scrollLeft > 1
    this.scroller.classList.toggle("ui-scroll-right", more)
    this.scroller.classList.toggle("ui-scroll-left", scrollLeft > 1)

    if (this.hasMoreTarget) this.moreTarget.hidden = scrollHeight - clientHeight - scrollTop <= 1
    if (this.hasHorizontalTarget) this.horizontalTarget.hidden = !more
    if (this.hasSpazioClass) this.element.classList.toggle(this.spazioClass, more)
  }
}
