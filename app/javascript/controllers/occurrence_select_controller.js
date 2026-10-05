import { Controller } from "@hotwired/stimulus"

// Master-detail occorrenze: selezionando una riga della tabella mostra i pannelli di QUELL'evento,
// senza reload. Serve sia la show di un gruppo errori (stacktrace/request/breadcrumbs/log/replay) sia
// quella di un gruppo metriche (parametri/source della query): la meccanica è la stessa e vive qui una
// volta sola; le due pagine differiscono solo per il colore della riga selezionata, dichiarato dal
// markup con data-occurrence-select-selected-class.
// Operabile da tastiera: ArrowUp/Down o j/k per spostarsi, Home/End agli estremi, Enter/Space per
// confermare; roving tabindex + aria-selected sulle righe; il cambio è annunciato via aria-live.
// Progressive enhancement: i pannelli dell'occorrenza selezionata sono già resi server-side.
export default class extends Controller {
  static targets = ["panel", "row", "check", "status"]
  static classes = ["selected"]

  connect() {
    this.index = this.rowTargets.findIndex((r) => r.getAttribute("aria-selected") === "true")
    if (this.index < 0) this.index = 0
    this.#apply({ focus: false, announce: false })
  }

  // click su una riga
  select(event) {
    this.index = this.rowTargets.indexOf(event.currentTarget)
    this.#apply({ focus: false })
  }

  // keydown sulla tabella occorrenze
  nav(event) {
    const last = this.rowTargets.length - 1
    if (last < 0) return
    let next = this.index
    switch (event.key) {
      case "ArrowDown": case "j": next = Math.min(this.index + 1, last); break
      case "ArrowUp":   case "k": next = Math.max(this.index - 1, 0);    break
      case "Home": next = 0; break
      case "End":  next = last; break
      case "Enter": case " ": event.preventDefault(); this.#apply(); return
      default: return
    }
    event.preventDefault()
    this.index = next
    this.#apply()
  }

  // Il colore della riga selezionata è del markup, non del controller: indigo sugli errori, stone
  // sulle metriche. Il default copre la pagina che non lo dichiara, così una riga resta comunque
  // riconoscibile invece di non evidenziarsi affatto.
  get #selectedClasses() {
    return this.hasSelectedClass ? this.selectedClasses : [ "bg-indigo-50", "dark:bg-indigo-500/15" ]
  }

  #apply({ focus = true, announce = true } = {}) {
    const current = this.rowTargets[this.index]
    if (!current) return
    const id = String(current.dataset.occurrenceId)
    const selectedClasses = this.#selectedClasses

    this.panelTargets.forEach((panel) => {
      panel.classList.toggle("hidden", panel.dataset.panelId !== id)
    })
    this.rowTargets.forEach((row, i) => {
      const selected = i === this.index
      selectedClasses.forEach((klass) => row.classList.toggle(klass, selected))
      row.setAttribute("aria-selected", selected ? "true" : "false")
      row.tabIndex = selected ? 0 : -1
    })
    this.checkTargets.forEach((check, i) => {
      check.classList.toggle("invisible", i !== this.index)
    })

    if (focus) current.focus()
    if (announce && this.hasStatusTarget) {
      this.statusTarget.textContent = current.dataset.announce || ""
    }
  }
}
