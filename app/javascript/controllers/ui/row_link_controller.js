import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// CYRA-715 — riga di tabella che apre una scheda. Nasce per sostituire l'`onclick="window.location=…"`
// scritto dentro il `<tr>`: la Content Security Policy dell'area utenti ora blocca davvero, e non
// esiste modo di autorizzare codice scritto in un attributo HTML — il nonce vale per i tag `<script>`,
// non per gli attributi. Qui il codice sta in un file servito dalla nostra origine, che `script-src
// 'self'` autorizza.
//
// Uso: <tr data-controller="ui--row-link" data-action="click->ui--row-link#open"
//          data-ui--row-link-url-value="/member/…">
//        …
//        <td data-ui--row-link-skip>…comandi…</td>
//      </tr>
//
// La riga NON è l'unico modo di arrivarci: dentro c'è sempre un link vero alla stessa destinazione,
// che è quello che vedono tastiera, lettori di schermo e "apri in una scheda nuova". Questo
// controller è la comodità del clic sulla riga intera, non l'accesso.
export default class extends Controller {
  static values = { url: String }

  open(event) {
    if (!this.urlValue) return
    // Un clic, un effetto solo. Un comando dentro la riga (link, bottone, campo, o una cella marcata
    // `data-ui--row-link-skip`) fa il suo mestiere e basta: senza questo, premere «Riesegui»
    // eseguirebbe il comando E porterebbe via la pagina sotto le dita.
    if (event.target.closest("a, button, summary, dialog, input, select, textarea, label, [data-ui--row-link-skip]")) return

    // Cmd/Ctrl/Shift premuti: è il gesto di "apri in una scheda (o finestra) nuova". Lasciarlo
    // passare senza fare niente evita di portare via la pagina corrente contro l'intenzione di chi lo
    // usa — il link dentro la riga resta la via per aprire davvero altrove. Il tasto centrale non
    // arriva fin qui (i browser lo mandano come `auxclick`): il controllo su `button` è difesa.
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.button !== 0) return

    Turbo.visit(this.urlValue)
  }
}
