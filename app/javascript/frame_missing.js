// CYRA-827 — un pezzo di pagina che riceve una risposta senza il proprio nome dentro.
//
// COSA FA TURBO DA SOLO, ed è il motivo per cui questo file esiste: quando la risposta a un
// turbo-frame non contiene un <turbo-frame> con quell'id, Turbo emette `turbo:frame-missing` e — se
// nessuno lo raccoglie — riscrive l'INTERNO del riquadro con «Content missing» e solleva un errore
// in console. Riscrivere l'interno vuol dire buttare via anche il contenuto di partenza: il
// collegamento di ripiego che quel riquadro aveva proprio per questo caso sparisce insieme al resto,
// e chi guarda resta davanti a due parole inglesi senza niente da premere.
//
// QUANDO SUCCEDE DAVVERO: la sessione è scaduta e la risposta è la pagina di login; il record non
// esiste più ed è la pagina d'errore; il server è inciampato. Nessuna di queste risposte ha dentro
// il riquadro, e nessuna è una risposta da mostrare dentro un riquadro: sono pagine intere.
//
// COSA FACCIAMO: la stessa cosa che Turbo farebbe con `turbo-visit-control: reload`, ma senza
// chiedere a ogni pagina che potrebbe capitare qui di ricordarsi di dichiararlo — si va a quella
// pagina a schermo intero. Alla login ci si arriva sulla login, all'errore sull'errore. Vale per
// ogni riquadro dell'applicazione, non solo per quelli della scheda progetto.
//
// `detail.visit` accetta la Response già letta: passarla evita una seconda richiesta di rete e
// conserva l'indirizzo a cui si era finiti (compreso il redirect verso la login).
// Un riquadro che si gestisce da solo (l'assistente mostra un messaggio e un pulsante «riprova»)
// ha già fermato l'evento sul proprio elemento: qui non si fa niente, altrimenti la sua cura
// verrebbe scavalcata da una navigazione a schermo intero che nessuno ha chiesto.
addEventListener("turbo:frame-missing", (event) => {
  if (event.defaultPrevented) return

  const { response, visit } = event.detail
  event.preventDefault()
  visit(response)
})
