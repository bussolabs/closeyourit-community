import { Controller } from "@hotwired/stimulus"

// Picker visuale (icona Font Awesome o colore) come progressive enhancement su un <input hidden> che
// porta il valore submesso (rack_test-friendly: senza JS submette il default). TUTTO il markup
// (trigger, popover, griglia, opzioni) è renderizzato lato server in ERB — così Tailwind compila le
// classi (l'auto-detection non scansiona i .js). Il controller NON costruisce DOM: sincronizza la
// selezione sull'input, aggiorna l'anteprima del trigger e filtra la griglia.
//
// kind: "icon" | "color" (cambia solo come si aggiorna l'anteprima del trigger).
// Ogni opzione porta: data-ui--picker-value-param, data-value, data-selected-class (classi di
// selezione, letterali in ERB), e per i colori data-swatch.
export default class extends Controller {
  static targets = ["input", "option", "label", "preview", "search", "details"]
  static values = { kind: { type: String, default: "icon" }, noneLabel: { type: String, default: "" } }

  connect() {
    this.refresh()
  }

  select(event) {
    this.inputTarget.value = event.currentTarget.dataset.value
    this.refresh()
    if (this.hasDetailsTarget) this.detailsTarget.open = false
  }

  refresh() {
    const value = this.inputTarget.value
    this.optionTargets.forEach((option) => {
      this.markOption(option, option.dataset.value === value && value !== "")
    })
    const selected = this.optionTargets.find((o) => o.dataset.value === value && value !== "")
    this.updateTrigger(selected)
  }

  filter() {
    if (!this.hasSearchTarget) return
    const q = this.searchTarget.value.trim().toLowerCase()
    this.optionTargets.forEach((option) => {
      option.hidden = q !== "" && !option.dataset.value.includes(q)
    })
  }

  markOption(option, selected) {
    (option.dataset.selectedClass || "")
      .split(" ")
      .filter(Boolean)
      .forEach((cls) => option.classList.toggle(cls, selected))
  }

  updateTrigger(selected) {
    if (this.hasLabelTarget) {
      this.labelTarget.textContent = selected ? selected.dataset.label : this.noneLabelValue
    }
    if (!this.hasPreviewTarget) return

    if (this.kindValue === "color") {
      const swatch = selected ? selected.dataset.swatch : this.previewTarget.dataset.defaultSwatch
      this.previewTarget.className = `${this.previewTarget.dataset.base} ${swatch}`.trim()
    } else {
      // Icon: copy the SVG the server drew in the chosen option (the "none" option when cleared).
      const source = selected || this.optionTargets.find((option) => option.dataset.value === "")
      const svg = source?.querySelector("svg")
      if (svg) this.previewTarget.replaceChildren(svg.cloneNode(true))
    }
  }
}
