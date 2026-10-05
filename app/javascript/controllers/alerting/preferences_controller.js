import { Controller } from "@hotwired/stimulus"

// CYRA-443 — ricerca fra gli avvisi della pagina notifiche. Chi arriva per spegnere UNA cosa la
// trovava solo a occhio, scorrendo quaranta righe: qui si digita il nome e restano solo le righe che
// corrispondono, con i gruppi che le contengono aperti.
//
// Il filtro NON tocca i valori: le righe nascoste restano nel form con la cadenza scelta, quindi un
// salvataggio a ricerca attiva salva tutto e non spegne quello che non si vede.
//
// Senza JS la pagina resta usabile: i gruppi sono <details> nativi e si aprono lo stesso, si perde
// solo la ricerca. Visibilità via ATTRIBUTO hidden (mai la classe .hidden): le righe hanno utility
// di display (flex) e la classe perderebbe il conflitto di cascade.
export default class extends Controller {
  static targets = ["search", "group", "row", "empty"]

  // Lo stato di partenza dei gruppi va ricordato: la ricerca apre quelli con risultati e, a campo
  // svuotato, la pagina deve tornare com'era — non con tutto spalancato.
  connect() {
    this.apertiAllArrivo = new Map(this.groupTargets.map((group) => [group, group.open]))
  }

  filter() {
    const query = this.searchTarget.value.trim().toLowerCase()
    let visibili = 0

    this.groupTargets.forEach((group) => {
      const righe = Array.from(group.querySelectorAll("[data-search]"))
      const trovate = righe.filter((riga) => !query || riga.dataset.search.includes(query))

      righe.forEach((riga) => { riga.hidden = query !== "" && !trovate.includes(riga) })
      group.hidden = trovate.length === 0
      group.open = query === "" ? this.apertiAllArrivo.get(group) : trovate.length > 0
      visibili += trovate.length
    })

    this.emptyTarget.hidden = visibili > 0
  }

  clear() {
    this.searchTarget.value = ""
    this.filter()
    this.searchTarget.focus()
  }

  // Invio nel campo di ricerca: filtra e basta. Senza questo il browser manderebbe il form —
  // un salvataggio a metà scelta, o peggio la prima configurazione pronta della barra.
  noSubmit(event) {
    event.preventDefault()
    this.filter()
  }
}
