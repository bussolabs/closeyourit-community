import { Controller } from "@hotwired/stimulus"

// Tooltip informativo: apre un popup su hover/focus del pallino "i".
// Il pannello viene posizionato con position:fixed calcolato da getBoundingClientRect,
// così sfugge all'overflow di tabelle e a <dialog> (niente clipping). Chiude su Esc,
// mouseleave/blur e click-fuori. Il pannello usa l'attributo [hidden] (mai la classe
// .hidden — vedi TS-TAILWIND-001).
//
//   <span data-controller="ui--tooltip" data-ui--tooltip-placement-value="top">
//     <button data-ui--tooltip-target="trigger"
//             data-action="mouseenter->ui--tooltip#show mouseleave->ui--tooltip#hide
//                          focus->ui--tooltip#show blur->ui--tooltip#hide
//                          keydown.esc->ui--tooltip#hideOnEsc">i</button>
//     <span data-ui--tooltip-target="panel" role="tooltip" hidden>…</span>
//   </span>
export default class extends Controller {
  static targets = ["trigger", "panel"]
  static values = { placement: { type: String, default: "top" } }

  connect() {
    this.outside = (e) => { if (!this.element.contains(e.target)) this.hide() }
    this.reposition = () => { if (!this.panelTarget.hidden) this.position() }
    document.addEventListener("click", this.outside)
    // capture:true → intercetta anche lo scroll dentro contenitori annidati (tabelle).
    window.addEventListener("scroll", this.reposition, true)
    window.addEventListener("resize", this.reposition)
  }

  disconnect() {
    document.removeEventListener("click", this.outside)
    window.removeEventListener("scroll", this.reposition, true)
    window.removeEventListener("resize", this.reposition)
  }

  show() {
    this.panelTarget.hidden = false
    this.position()
  }

  hide() {
    const s = this.panelTarget.style
    this.panelTarget.hidden = true
    // Torna al fallback CSS (le classi placement) quando è chiuso.
    s.position = s.left = s.top = s.bottom = s.right = s.transform = s.translate = ""
  }

  toggle() {
    this.panelTarget.hidden ? this.show() : this.hide()
  }

  hideOnEsc() {
    this.hide()
    this.triggerTarget.blur()
  }

  // Calcola la posizione fixed rispetto al trigger, con flip verticale e clamp
  // orizzontale ai bordi del viewport.
  position() {
    const panel = this.panelTarget
    const s = panel.style
    s.position = "fixed"
    // Il fallback CSS centra il pannello sul pallino con `-translate-x-1/2`. In Tailwind v4 quella
    // utility scrive la proprietà `translate`, NON `transform`: azzerare solo `transform` la lascia
    // in piedi e il pannello resta spostato di mezza larghezza a sinistra — su schermo stretto esce
    // dal bordo e la frase si legge tagliata (CYRA-432). Vanno azzerate entrambe.
    s.transform = s.translate = "none"
    s.bottom = s.right = "auto"
    s.left = s.top = "0px"

    const t = this.triggerTarget.getBoundingClientRect()
    const p = panel.getBoundingClientRect()
    const gap = 6
    const margin = 8
    const vw = document.documentElement.clientWidth
    const vh = document.documentElement.clientHeight

    // Orizzontale: centrato sul trigger, poi clamp entro i bordi.
    let left = t.left + t.width / 2 - p.width / 2
    left = Math.max(margin, Math.min(left, vw - p.width - margin))

    // Verticale: sopra di default, flip sotto se non c'è spazio sopra.
    let placeTop = this.placementValue !== "bottom"
    if (placeTop && t.top - p.height - gap < margin) placeTop = false
    if (!placeTop && t.bottom + p.height + gap > vh - margin &&
        t.top - p.height - gap >= margin) {
      placeTop = true
    }
    const top = placeTop ? t.top - p.height - gap : t.bottom + gap

    s.left = `${Math.round(left)}px`
    s.top = `${Math.round(top)}px`
  }
}
