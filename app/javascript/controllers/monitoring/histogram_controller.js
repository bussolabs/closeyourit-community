import { Controller } from "@hotwired/stimulus"

// Tooltip per-colonna dell'istogramma occorrenze/metriche. Su hover di una barra riempie il
// tooltip coi dati del blocco (data-label = finestra oraria, data-value = valore) e lo posiziona
// con position:fixed via getBoundingClientRect, così sfugge al clipping di tabelle/<dialog>.
// Toggle SEMPRE via l'attributo [hidden] (mai la classe .hidden — TS-TAILWIND-001).
// Mirror di ui--tooltip (app/javascript/controllers/ui/tooltip_controller.js).
export default class extends Controller {
  static targets = ["bar", "tooltip", "tooltipTime", "tooltipValue"]

  connect() {
    this.current = null
    // capture:true → intercetta anche lo scroll dentro contenitori annidati.
    this.reposition = () => { if (!this.tooltipTarget.hidden && this.current) this.position(this.current) }
    window.addEventListener("scroll", this.reposition, true)
    window.addEventListener("resize", this.reposition)
  }

  disconnect() {
    window.removeEventListener("scroll", this.reposition, true)
    window.removeEventListener("resize", this.reposition)
  }

  show(event) {
    const bar = event.currentTarget
    this.current = bar
    this.tooltipTimeTarget.textContent = bar.dataset.label || ""
    this.tooltipValueTarget.textContent = bar.dataset.value || ""
    this.tooltipTarget.hidden = false
    this.position(bar)
  }

  hide() {
    this.current = null
    const s = this.tooltipTarget.style
    this.tooltipTarget.hidden = true
    s.position = s.left = s.top = ""
  }

  // Posiziona il tooltip fixed sopra la barra, con flip sotto se manca spazio e clamp orizzontale.
  position(bar) {
    const s = this.tooltipTarget.style
    s.position = "fixed"
    s.left = "0px"
    s.top = "0px"

    const b = bar.getBoundingClientRect()
    const t = this.tooltipTarget.getBoundingClientRect()
    const gap = 8
    const margin = 8
    const vw = document.documentElement.clientWidth
    const vh = document.documentElement.clientHeight

    let left = b.left + b.width / 2 - t.width / 2
    left = Math.max(margin, Math.min(left, vw - t.width - margin))

    let top = b.top - t.height - gap
    if (top < margin) top = Math.min(b.bottom + gap, vh - t.height - margin)

    s.left = `${Math.round(left)}px`
    s.top = `${Math.round(top)}px`
  }
}
