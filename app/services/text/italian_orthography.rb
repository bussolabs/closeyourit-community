# frozen_string_literal: true

module Text
  # Ortografia italiana dei testi scritti dalle automazioni (CYRA-411).
  #
  # Un modello che scrive «il ticket e' gia chiuso» produce testo che l'utente legge per primo e più
  # a lungo di qualsiasi altra cosa: l'accento mancante fa sembrare improvvisato il prodotto e in
  # qualche caso cambia il senso della frase. La difesa è a due livelli, e questo modulo li tiene
  # insieme perché non divergano:
  #
  # 1. PROMPT_RULE — il vincolo esplicito da mettere nel prompt di sistema di ogni service che fa
  #    scrivere testo italiano a un modello. Previene l'errore alla fonte, ma non lo garantisce.
  # 2. .correct — la rete di sicurezza lato server, applicata dalle `normalizes` dei model prima del
  #    salvataggio. Vale per QUALUNQUE origine (assistente AI, agente autonomo via CLI, persona):
  #    «perché» scritto senza accento è un errore chiunque l'abbia scritto.
  #
  # La correzione è deliberatamente TIMIDA. Un dizionario chiuso di forme note, mai una regola
  # generale sull'apostrofo finale (`po'`, `da'`, `fa'`, `va'`, `di'` sono corretti così e non sono
  # in tabella) e mai il singolo carattere: `e` congiunzione ed `è` verbo si scrivono uguali senza
  # accento, quindi «bug e story» deve restare intatto. Correggere di meno è un difetto estetico;
  # correggere di più è un errore nuovo introdotto nel testo di qualcun altro.
  module ItalianOrthography
    # Forma sbagliata (senza accento) → forma corretta. CHIUSO: si allunga a mano, una voce alla
    # volta, e solo dopo aver verificato che la forma senza accento non sia a sua volta una parola
    # italiana di uso corrente (vedi APOSTROPHE_ONLY per quelle che lo sono).
    CORRECTIONS = {
      # Ambigue senza apostrofo — vedi APOSTROPHE_ONLY.
      "e" => "è",
      "ne" => "né",
      "se" => "sé",
      "si" => "sì",
      "li" => "lì",
      "la" => "là",
      "meta" => "metà",
      "eta" => "età",
      "sara" => "sarà",
      # Avverbi e congiunzioni: senza accento non sono parole italiane.
      "gia" => "già",
      "piu" => "più",
      "giu" => "giù",
      "puo" => "può",
      "cio" => "ciò",
      "cosi" => "così",
      "cioe" => "cioè",
      "pero" => "però",
      "percio" => "perciò",
      "perche" => "perché",
      "poiche" => "poiché",
      "finche" => "finché",
      "benche" => "benché",
      "affinche" => "affinché",
      "nonche" => "nonché",
      "anziche" => "anziché",
      "sicche" => "sicché",
      "caffe" => "caffè",
      # Nomi in -tà: frequentissimi nel vocabolario del prodotto.
      "citta" => "città",
      "societa" => "società",
      "universita" => "università",
      "liberta" => "libertà",
      "novita" => "novità",
      "verita" => "verità",
      "entita" => "entità",
      "qualita" => "qualità",
      "quantita" => "quantità",
      "attivita" => "attività",
      "identita" => "identità",
      "priorita" => "priorità",
      "velocita" => "velocità",
      "visibilita" => "visibilità",
      "possibilita" => "possibilità",
      "funzionalita" => "funzionalità",
      "specificita" => "specificità",
      "compatibilita" => "compatibilità",
      "affidabilita" => "affidabilità",
      "disponibilita" => "disponibilità",
      "responsabilita" => "responsabilità",
      "ereditarieta" => "ereditarietà",
      # Futuri semplici.
      "avra" => "avrà",
      "fara" => "farà",
      "dara" => "darà",
      "verra" => "verrà",
      "andra" => "andrà",
      "potra" => "potrà",
      "dovra" => "dovrà",
      "sapra" => "saprà"
    }.freeze

    # Forme la cui variante senza accento è a sua volta italiano valido («la» articolo, «li»
    # pronome, «meta» traguardo) o un nome proprio («Sara»): si correggono SOLO quando arrivano con
    # l'apostrofo finale, che è già di per sé la prova dell'intenzione di mettere un accento.
    APOSTROPHE_ONLY = %w[e ne se si li la meta eta sara].to_set.freeze

    # Vincolo da interpolare nel prompt di sistema dei service che fanno scrivere testo italiano a un
    # modello. Le forme sbagliate stanno fra backtick: sono anche l'esempio di ciò che .correct non
    # deve toccare, e questo testo passa dalla propria regola come qualsiasi altro (vedi spec).
    PROMPT_RULE = <<~RULE
      Ortografia italiana obbligatoria: metti sempre gli accenti dove servono (è, più, già, perché,
      così, però, lì, città, sarà) e non sostituirli mai con l'apostrofo — si scrive «è» e non `e'`,
      «più» e non `piu'`, «perché» e non `perche'`. L'apostrofo serve solo all'elisione (l'utente,
      dell'app, un'ora).
    RULE

    # Zone in cui una parola non è prosa italiana e non va toccata: blocchi di codice recintati,
    # codice inline, URL e indirizzi email. Senza questa esclusione `params[:gia]` diventerebbe
    # `params[:già]` e un link a /perche finirebbe rotto.
    PROTECTED_SOURCE = [
      "```.*?```",
      "~~~.*?~~~",
      '`[^`\n]*`',
      '\b[a-z][a-z0-9+.\-]*://\S*',
      '[\w.+\-]+@[\w\-]+(?:\.[\w\-]+)+'
    ].join("|").freeze

    # Le chiavi lunghe prima: l'alternanza si ferma alla prima che matcha.
    WORDS_SOURCE = Regexp.union(CORRECTIONS.keys.sort_by { |word| -word.length }).source

    SCANNER = Regexp.new(
      "(?<skip>#{PROTECTED_SOURCE})|" \
      "(?<![[:alnum:]_])(?<word>#{WORDS_SOURCE})(?<mark>['’])?(?![[:alnum:]_])",
      Regexp::IGNORECASE | Regexp::MULTILINE
    )

    # Il testo con le forme note corrette. Funzione pura e idempotente: applicarla due volte dà lo
    # stesso risultato, perché ciò che produce (con l'accento) non è più nel dizionario.
    def self.correct(text)
      text.to_s.gsub(SCANNER) do
        match = Regexp.last_match
        next match[:skip] if match[:skip]

        replacement_for(match[:word], match[:mark]) || match[0]
      end
    end

    # Come .correct ma dentro una struttura jsonb (gli scenari e le note di un Agents::Plan arrivano
    # come array di stringhe o di hash, a seconda del planner). Corregge SOLO le stringhe di valore e
    # lascia la forma esattamente com'era: le chiavi sono nomi di campo del contratto, non prosa.
    def self.correct_deep(value)
      case value
      when String then correct(value)
      when Array  then value.map { |item| correct_deep(item) }
      when Hash   then value.transform_values { |item| correct_deep(item) }
      else value
      end
    end

    # nil = questa occorrenza si lascia com'è (fuori dizionario, oppure ambigua e senza apostrofo).
    def self.replacement_for(word, mark)
      correction = CORRECTIONS[word.downcase]
      return if correction.nil?
      return if mark.nil? && APOSTROPHE_ONLY.include?(word.downcase)

      match_case(word, correction)
    end
    private_class_method :replacement_for

    # La maiuscola di chi ha scritto sopravvive alla correzione: a inizio frase «Perche» resta
    # «Perché» e in un titolo tutto maiuscolo «PIU'» resta «PIÙ».
    def self.match_case(word, correction)
      return correction if word == word.downcase
      return correction.upcase if word == word.upcase

      correction.capitalize
    end
    private_class_method :match_case
  end
end
