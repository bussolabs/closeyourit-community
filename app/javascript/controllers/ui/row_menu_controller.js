import { Controller } from "@hotwired/stimulus"

// Row-menu (kebab): pannello a position:fixed calcolato da getBoundingClientRect,
// così sfugge all'overflow-x delle tabelle scrollabili senza essere clippato. Il
// toggle resta il <details> nativo (apre anche senza JS); il JS aggiunge solo il
// posizionamento fixed + chiusura su Esc e click-fuori. Pannello allineato al bordo
// destro del trigger, con flip verso l'alto se sotto non c'è spazio. Stesso pattern
// anti-clipping di ui--tooltip. Reset dello stile inline alla chiusura → torna al
// fallback CSS (absolute right-0 top-9) quando il JS è assente.
//
//   <details data-controller="ui--row-menu" data-action="toggle->ui--row-menu#onToggle">
//     <summary data-ui--row-menu-target="trigger">⋯</summary>
//     <div data-ui--row-menu-target="panel">…</div>
//   </details>
export default class extends Controller {
  static targets = ["trigger", "panel"]

  connect() {
    this.outside = (e) => { if (!this.element.contains(e.target)) this.close() }
    this.onKeydown = (e) => { if (e.key === "Escape") this.close() }
    this.reposition = () => { if (this.element.open) this.position() }
    document.addEventListener("click", this.outside)
    document.addEventListener("keydown", this.onKeydown)
    // capture:true → intercetta anche lo scroll dentro la tabella scrollabile.
    window.addEventListener("scroll", this.reposition, true)
    window.addEventListener("resize", this.reposition)
  }

  disconnect() {
    document.removeEventListener("click", this.outside)
    document.removeEventListener("keydown", this.onKeydown)
    window.removeEventListener("scroll", this.reposition, true)
    window.removeEventListener("resize", this.reposition)
  }

  onToggle() {
    this.element.open ? this.position() : this.resetStyle()
  }

  close() {
    if (this.element.open) {
      this.element.open = false
      this.resetStyle()
    }
  }

  resetStyle() {
    const s = this.panelTarget.style
    s.position = s.left = s.top = s.right = s.bottom = s.zIndex = ""
  }

  // Posiziona il pannello con position:fixed: allineato a destra del trigger, sotto
  // di default, flip sopra se non c'è spazio, clamp orizzontale ai bordi del viewport.
  position() {
    const panel = this.panelTarget
    const s = panel.style
    s.position = "fixed"
    s.right = s.bottom = "auto"
    s.left = s.top = "0px"
    s.zIndex = "50"

    const t = this.triggerTarget.getBoundingClientRect()
    const p = panel.getBoundingClientRect()
    const gap = 4
    const margin = 8
    const vw = document.documentElement.clientWidth
    const vh = document.documentElement.clientHeight

    let left = t.right - p.width
    left = Math.max(margin, Math.min(left, vw - p.width - margin))

    let top = t.bottom + gap
    if (top + p.height + margin > vh && t.top - p.height - gap >= margin) {
      top = t.top - p.height - gap
    }
    top = Math.max(margin, top)

    s.left = `${Math.round(left)}px`
    s.top = `${Math.round(top)}px`
  }
}
