import { Controller } from "@hotwired/stimulus"
import { icon } from "lib/icon"

// Aggiorna live la checklist regole password. Rispecchia Accounts::Constants::PASSWORD_FORMAT.
const RULES = {
  length:    (v) => v.length >= 8,
  uppercase: (v) => /[A-Z]/.test(v),
  lowercase: (v) => /[a-z]/.test(v),
  number:    (v) => /\d/.test(v),
  special:   (v) => /[^A-Za-z0-9]/.test(v),
}

export default class extends Controller {
  static targets = ["input", "rule"]

  connect() {
    this.check()
  }

  check() {
    const value = this.hasInputTarget ? this.inputTarget.value : ""
    this.ruleTargets.forEach((el) => {
      const test = RULES[el.dataset.rule]
      const met = test ? test(value) : false
      el.dataset.met = met ? "true" : "false"
      el.classList.toggle("text-green-600", met)
      el.classList.toggle("dark:text-green-400", met)
      // Nessun toggle su un altro grigio: la classe statica text-gray-500 (contrasto AA) resta
      // l'unico colore per lo stato non soddisfatto — niente doppia classe gray-400/gray-500 in
      // competizione nella cascata.
      const current = el.querySelector("svg[data-icon]")
      if (current) {
        current.replaceWith(met
          ? icon("circle-check", "w-[1.25em] text-[11px]")
          : icon("circle", "w-[1.25em] text-[8px] text-gray-300 dark:text-zinc-600"))
      }
      // Equivalente testuale per gli AT (oltre a icona/colore) — l'aria-live sul <ul> annuncia il cambio.
      const status = el.querySelector("[data-status]")
      if (status) status.textContent = met ? el.dataset.metText : el.dataset.unmetText
    })
  }
}
