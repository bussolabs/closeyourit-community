import { Controller } from "@hotwired/stimulus"

// Contatore caratteri vivo sotto un campo di testo lungo: "N / MAX caratteri", grigio finché c'è
// spazio, ambra oltre la quota d'avviso, rosso oltre il tetto. È un avviso, non un gate: non
// tronca e non blocca il submit — l'autorità è la validazione LengthBudget nel model, che vale
// identica per web, CLI e API. Serve solo a non far scoprire il limite col salvataggio rifiutato.
export default class extends Controller {
  static targets = ["field", "output", "hint"]
  static values = {
    max: Number,
    warnRatio: { type: Number, default: 0.8 },
    // Soglia d'avviso in caratteri, quando il campo ha un bersaglio proprio invece di una quota del
    // tetto (CYRA-263). Default 0 = non dichiarato, e vince warnRatio: e' cio' che tiene invariati
    // tutti gli altri campi. Un bersaglio non e' esprimibile come quota perche' non ha niente a che
    // vedere col tetto — sull'analisi tecnica sono 900 su 1.500, che come quota sarebbe uno 0.6
    // scelto per far tornare il conto invece che per una ragione.
    warnAt: { type: Number, default: 0 },
    unit: String
  }

  connect() {
    this.update()
  }

  update() {
    // Spread invece di .length: JS misura in unità UTF-16 (un emoji conterebbe 2), Ruby conta
    // codepoint. I fine-riga combaciano perché il model normalizza CRLF→LF (concern LengthBudget),
    // quindi questo conteggio è ESATTAMENTE quello che validerà il server.
    const count = [ ...this.fieldTarget.value ].length
    // Il bersaglio esplicito vince sulla quota, che resta il default di chi non ne dichiara uno.
    const warnAt = this.warnAtValue > 0 ? this.warnAtValue : this.maxValue * this.warnRatioValue

    this.outputTarget.textContent = `${count} / ${this.maxValue} ${this.unitValue}`
    this.outputTarget.classList.toggle("text-red-600", count > this.maxValue)
    this.outputTarget.classList.toggle("dark:text-red-400", count > this.maxValue)
    this.outputTarget.classList.toggle("text-amber-600", count <= this.maxValue && count >= warnAt)
    this.outputTarget.classList.toggle("dark:text-amber-400", count <= this.maxValue && count >= warnAt)
    this.outputTarget.classList.toggle("text-gray-500", count < warnAt)
    this.outputTarget.classList.toggle("dark:text-zinc-400", count < warnAt)
    // CYRA-883 — an optional sentence that explains the limit, shown only once it is close.
    if (this.hasHintTarget) this.hintTarget.classList.toggle("hidden", count < warnAt)
  }
}
