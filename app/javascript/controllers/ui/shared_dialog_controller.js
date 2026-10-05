import { Controller } from "@hotwired/stimulus"

// Un <dialog> CONDIVISO da tutte le righe di un elenco (CYRA-571).
//
// Gemello di ui--dialog, ma il dialog non sta dentro la riga: sta in pagina UNA volta e la riga,
// aprendolo, gli dice su cosa sta decidendo. Un dialog per riga significa un modulo e un token per
// riga — cinquanta righe erano cinquanta copie dello stesso markup, e il peso della pagina cresceva
// con l'elenco senza comprimersi (ogni token è diverso dagli altri).
//
// Il controller sta sul contenitore che tiene INSIEME l'elenco e i dialoghi (le righe devono
// cadere nel suo scope), e distingue più dialoghi per nome.
//
//   <div data-controller="ui--shared-dialog">
//     <button data-action="ui--shared-dialog#open"
//             data-dialog="reject" data-dialog-url="/…/reject" data-dialog-subject="API_KEY">Rifiuta</button>
//     …
//     <dialog data-ui--shared-dialog-target="dialog" data-dialog-name="reject"
//             data-action="click->ui--shared-dialog#backdrop">
//       <form>… <span data-dialog-subject></span> …</form>
//     </dialog>
//   </div>
export default class extends Controller {
  static targets = ["dialog"]

  open(event) {
    const trigger = event.currentTarget
    const dialog = this.dialogTargets.find((el) => el.dataset.dialogName === trigger.dataset.dialog)
    if (!dialog) return

    const form = dialog.querySelector("form")
    if (form) {
      // reset() prima dell'action: il motivo scritto per un'altra riga e poi abbandonato non deve
      // ritrovarsi qui.
      form.reset()
      if (trigger.dataset.dialogUrl) form.setAttribute("action", trigger.dataset.dialogUrl)
    }
    dialog.querySelectorAll("[data-dialog-subject]").forEach((el) => {
      el.textContent = trigger.dataset.dialogSubject || ""
    })

    dialog.showModal()
  }

  close(event) {
    event.target.closest("dialog")?.close()
  }

  // Chiude se il click cade sul <dialog> stesso (area backdrop), non sul contenuto interno.
  backdrop(event) {
    if (event.target === event.currentTarget) event.currentTarget.close()
  }
}
