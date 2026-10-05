import { Controller } from "@hotwired/stimulus"

// Riga di creazione secret ON-DEMAND. La riga (_new_row) è nel tbody ma con l'attributo `hidden`;
// il bottone "Aggiungi secret" nell'header la rivela + focus sul nome. "Annulla" la ri-nasconde e
// pulisce i campi. Empty-state e bottone header seguono lo stato. Il salvataggio resta il submit
// del form-riga (pattern form=): POST create → redirect (la riga torna hidden al reload).
export default class extends Controller {
  static targets = ["row", "field", "empty", "addButton"]

  connect() {
    // Riga ri-aperta dal server dopo un 422 (render :index): allinea empty-state e bottone.
    if (this.hasRowTarget && !this.rowTarget.hidden) this.syncChrome(true)
  }

  show() {
    this.rowTarget.hidden = false
    this.syncChrome(true)
    this.fieldTargets[0]?.focus()
  }

  cancel() {
    this.fieldTargets.forEach((el) => (el.value = ""))
    this.rowTarget.hidden = true
    this.syncChrome(false)
  }

  syncChrome(open) {
    if (this.hasEmptyTarget) this.emptyTarget.hidden = open
    if (this.hasAddButtonTarget) this.addButtonTarget.hidden = open
  }
}
