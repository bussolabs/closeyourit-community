import { Controller } from "@hotwired/stimulus"
import { icon } from "lib/icon"

// Filtri della toolbar a chip on-demand (Ui::TableToolbarComponent). Il menu "Filtri" mostra/
// nasconde i chip; l'applicazione è in auto-submit del form GET — alla chiusura di un dropdown
// ui--select con selezione cambiata (snapshot su opened, confronto su closed: robusto
// sull'ordine change/close e niente submit se la selezione torna uguale) o alla rimozione (X)
// di un chip con valori. L'Apply server-rendered resta come fallback no-JS: qui viene nascosto
// al connect.
//
// Visibilità di chip / check / Apply via ATTRIBUTO hidden (el.hidden, preflight Tailwind
// display:none !important), MAI via classe .hidden: su nodi con utility di display
// (inline-flex, inline-block) la classe perde il conflitto di cascade. Il pannello del menu invece
// non ha utility di display e usa la classe, come gli altri dropdown (ui--select, saved-views).
export default class extends Controller {
  static targets = ["form", "chip", "menuButton", "menuPanel", "submitButton", "submitIcon", "filterRegion"]

  connect() {
    this.snapshots = new Map()
    this.submitting = false
    this.chipTargets.forEach((chip) => this.syncExactFields(chip))
    // :not([form]) — a button that submits ANOTHER form (e.g. the projects view switch) is not the Apply.
    const apply = this.formTarget.querySelector("button[type=submit]:not([form]):not([data-ui--filter-bar-target~=submitButton])")
    if (apply) apply.hidden = true
    this.outside = (e) => {
      if (this.hasMenuPanelTarget && !this.menuButtonTarget.contains(e.target) && !this.menuPanelTarget.contains(e.target)) this.closeMenu()
    }
    document.addEventListener("click", this.outside)
  }

  disconnect() {
    document.removeEventListener("click", this.outside)
  }

  toggleMenu() {
    this.menuPanelTarget.classList.contains("hidden") ? this.openMenu() : this.closeMenu()
  }

  openMenu() {
    // Check sulle voci = chip visibile (aggiunto o attivo), non solo con valori selezionati.
    this.menuPanelTarget.querySelectorAll("[data-filter-key]").forEach((item) => {
      const chip = this.chipFor(item.dataset.filterKey)
      const check = item.querySelector("[data-menu-check]")
      if (check) check.hidden = !chip || chip.hidden
    })
    this.menuPanelTarget.classList.remove("hidden")
    this.menuButtonTarget.setAttribute("aria-expanded", "true")
  }

  closeMenu() {
    this.menuPanelTarget.classList.add("hidden")
    this.menuButtonTarget.setAttribute("aria-expanded", "false")
  }

  // Voce del menu: mostra il chip e apre subito il suo dropdown per scegliere i valori.
  // Idempotente se il chip è già visibile; dal menu non si rimuove (rimozione = solo X).
  // Apertura DEFERITA (setTimeout 0): il click sulla voce sta ancora bubblando verso document
  // e l'outside-handler di ui--select chiuderebbe all'istante un panel aperto in sincrono.
  chooseFilter(event) {
    const chip = this.chipFor(event.currentTarget.dataset.filterKey)
    if (!chip) return
    chip.hidden = false
    this.syncExactFields(chip)
    this.closeMenu()
    const select = chip.querySelector("[data-filter-bar-compound]") ? null : chip.querySelector("[data-controller~='ui--select']")
    if (!select) {
      // A chip whose control is a <details> menu (Ui::RangeFilterComponent, CYRA-985).
      const menu = chip.querySelector("details")
      if (menu) setTimeout(() => { menu.open = true }, 0)
      return
    }
    setTimeout(() => this.application.getControllerForElementAndIdentifier(select, "ui--select")?.open(), 0)
  }

  // A chip, or an always-visible control marked data-filter-bar-autosubmit (e.g. the projects "Sort"
  // menu, CYRA-883): both apply on close, only when the choice changed.
  selectOpened(event) {
    const chip = event.target.closest("[data-ui--filter-bar-target='chip'], [data-filter-bar-autosubmit]")
    if (chip && !chip.querySelector("[data-filter-bar-compound]")) this.snapshots.set(chip, this.values(chip))
  }

  selectClosed(event) {
    const chip = event.target.closest("[data-ui--filter-bar-target='chip'], [data-filter-bar-autosubmit]")
    if (!chip || !this.snapshots.has(chip)) return
    const changed = this.snapshots.get(chip) !== this.values(chip)
    this.snapshots.delete(chip)
    if (changed) this.submit()
  }

  // X sul chip: azzera il select nativo (change → ui--select ri-sincronizza trigger/lista),
  // nasconde il chip e submitta solo se c'erano valori (chip vuoto rimosso ⇒ nessun reload).
  remove(event) {
    const chip = event.currentTarget.closest("[data-ui--filter-bar-target='chip']")
    if (!chip) return
    const had = this.values(chip) !== "" || (!chip.hidden && chip.querySelectorAll("[data-filter-bar-exact]").length > 0)
    const compound = chip.querySelector("[data-filter-bar-compound]")
    if (compound) {
      compound.querySelectorAll("input[name], select[name]").forEach((field) => {
        if (field.tagName === "SELECT") Array.from(field.options).forEach((option) => { option.selected = false })
        field.value = ""
      })
    }
    const select = compound ? null : chip.querySelector("select")
    if (select) {
      Array.from(select.selectedOptions).forEach((o) => { o.selected = false })
      select.dispatchEvent(new Event("change", { bubbles: true }))
    }
    const holder = chip.querySelector("[data-filter-bar-value]")
    if (holder) holder.value = ""
    chip.hidden = true
    this.syncExactFields(chip)
    if (had) this.submit()
  }

  // Empty strings are meaningful only for an explicitly enabled exact filter.
  syncExactFields(chip) {
    chip.querySelectorAll("[data-filter-bar-exact]").forEach((field) => { field.disabled = chip.hidden })
  }

  values(chip) {
    const compound = chip.querySelector("[data-filter-bar-compound]")
    if (compound) return Array.from(compound.querySelectorAll("input[name], select[name]")).map((field) => field.value).join("")
    const select = chip.querySelector("select")
    // A chip without a select keeps its value in a marked hidden field (CYRA-985).
    if (!select) return chip.querySelector("[data-filter-bar-value]")?.value ?? ""
    return Array.from(select.selectedOptions).map((o) => o.value).sort().join(" ")
  }

  chipFor(key) {
    return this.chipTargets.find((c) => c.dataset.filterKey === key)
  }

  // requestSubmit (non submit()): fa intercettare la GET a Turbo Drive. Il form non porta
  // `page` → si riparte da pagina 1; gli hidden (es. range) sono nel form → preservati.
  submit() {
    if (this.submitting) return
    this.submitting = true
    this.formTarget.requestSubmit()
  }

  // Loading state (results_frame only): semantic search is slow, so the search arrow spins and the
  // filter region is disabled while the frame loads. Bound to the form's turbo:submit-start/end.
  start() {
    if (this.hasSubmitButtonTarget) this.submitButtonTarget.disabled = true
    if (this.hasSubmitIconTarget) this.swapSubmitIcon("loader-circle", true)
    if (this.hasFilterRegionTarget) this.filterRegionTarget.classList.add("opacity-50", "pointer-events-none")
  }

  // Fine caricamento: ripristina UI E resetta `submitting` — con il frame la toolbar NON si
  // ricarica (solo il frame swappa), quindi senza reset gli auto-submit successivi resterebbero
  // bloccati dal guard di submit().
  end() {
    this.submitting = false
    if (this.hasSubmitButtonTarget) this.submitButtonTarget.disabled = false
    if (this.hasSubmitIconTarget) this.swapSubmitIcon("arrow-right", false)
    if (this.hasFilterRegionTarget) this.filterRegionTarget.classList.remove("opacity-50", "pointer-events-none")
  }

  // Swaps the search arrow for the spinner and back: a new SVG with the old classes and target.
  swapSubmitIcon(name, spinning) {
    const current = this.submitIconTarget
    const next = icon(name)
    next.setAttribute("class", current.getAttribute("class"))
    next.classList.toggle("animate-spin", spinning)
    next.setAttribute("data-ui--filter-bar-target", "submitIcon")
    current.replaceWith(next)
  }
}
