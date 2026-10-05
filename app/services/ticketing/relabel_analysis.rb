# frozen_string_literal: true

module Ticketing
  # Riscrive un'analisi tecnica già scritta nella forma a etichette (CYRA-266): `**Approccio:**`,
  # `**Perché:**`, `**Rischi:**`, `**Aperto:**`. Le etichette e la loro distribuzione sono quelle di
  # knowledge-base/global/closeyourit-writing.md — se cambiano lì, cambiano qui e in
  # skills/shared/writing.md.
  #
  # Gemello di Ticketing::SummarizeAnalysis nella forma, opposto in una cosa sola e decisiva:
  # **non esiste un ripiego**. Là il testo integrale era già al sicuro in un allegato prima che il
  # modello venisse interpellato, quindi troncare era meglio di niente. Qui si riscrive l'UNICA copia
  # di un testo che è già leggibile: un'analisi senza etichette si legge, un'analisi troncata a metà
  # frase no. Se il modello tace, la cosa giusta è non toccare niente e lasciare che il rilancio
  # riprenda il ticket.
  #
  # L'originale non si perde comunque: la scrittura passa da Ticketing::UpdateTicket, il cui
  # log_changes registra la coppia prima→dopo nell'evento di cronologia.
  class RelabelAnalysis < ApplicationService
    # Le etichette ammesse nell'analisi tecnica. `Perche'` senza accento perché le skill headless
    # scrivono così quando la shell maltratta gli accenti: è lo stesso concetto, non un'etichetta in
    # più. `Consigli` è ammessa in lettura (CYRA-264) ma non si chiede al modello di inventarla.
    LABEL_PATTERN = /\*\*(Approccio|Perché|Perche'|Rischi|Aperto|Consigli):\*\*/

    # Si chiede il bersaglio, non il tetto: è il numero che la regola indica come misura giusta, e
    # chiedere 1.500 vorrebbe dire chiedere al modello di riempire lo spazio — esattamente il difetto
    # che questo lavoro esiste per togliere.
    TARGET_CHARS = Ticketing::Constants::TECHNICAL_ANALYSIS_TARGET_CHARS
    # Il campo ha un tetto di 1.500, quindi l'input non può essere più lungo di così. Il clamp resta
    # per i testi storici scritti prima che il tetto esistesse (LengthBudget li lascia salvare).
    INPUT_CLAMP = 4_000

    SYSTEM_PROMPT = <<~PROMPT
      Sei un redattore tecnico. Ricevi l'analisi tecnica di un ticket e la RIORGANIZZI nella forma
      fissa a etichette, senza cambiarne il contenuto.

      Le etichette, in quest'ordine, in grassetto e seguite dai due punti:
      - **Approccio:** cosa si intende fare — file, aree, percorsi e righe se ci sono.
      - **Perché:** la decisione presa e l'alternativa scartata.
      - **Rischi:** cosa può rompersi.
      - **Aperto:** cosa resta da decidere o da fare.

      Regole, in ordine di importanza:
      - NON AGGIUNGERE NULLA che non sia nell'originale. Non dedurre, non completare, non migliorare.
      - Ometti le etichette per cui l'originale non dice niente. Un'analisi che non parla di rischi
        resta senza **Rischi:** — inventarli è il modo peggiore di sbagliare questo compito.
      - Se l'originale è una frase sola, il risultato è **Approccio:** e quella frase. Va benissimo.
      - Italiano, stesso registro e stesso lessico tecnico dell'originale. Nomi di file, classi,
        percorsi, comandi ed errori si riportano ESATTI.
      - Punta a %{target} caratteri. Se l'originale è più corto, resta corto: non allungare.
      - Una riga per concetto, sotto le 25 parole.
      - Niente titoli markdown (#), niente elenchi annidati: le etichette sono già la struttura.
      #{Text::ItalianOrthography::PROMPT_RULE}
    PROMPT

    ANALYSIS_SCHEMA = {
      type: "object",
      properties: {
        analysis: { type: "string", description: "L'analisi riorganizzata a etichette." }
      },
      required: [ "analysis" ]
    }.freeze

    # `organization:` è OBBLIGATORIA (CYRA-547): l'analisi arriva già come stringa, e da una stringa
    # non si risale a chi paga la chiamata. Il client iniettato resta la porta delle prove.
    def initialize(body:, organization:, client: nil)
      @body = body.to_s
      @organization = organization
      @client = client
    end

    # => Result.ok(nil) se non c'era niente da fare, Result.ok(testo) se ha riscritto.
    def call
      return Result.ok(nil) if skip?
      return Result.err(Ai::Feature.disabled_error(:analysis_relabel)) if Ai::Feature.disabled?(:analysis_relabel)

      client = @client || Ai::Llm::Client.new

      analysis = request_analysis(client)
      return Result.err(empty_error) if analysis.blank?
      # Il modello ha risposto ma senza etichette: è un fallimento, non un risultato. Sovrascrivere
      # con una parafrasi senza forma sarebbe il peggiore dei due mondi — testo cambiato, problema
      # intatto.
      return Result.err(unlabelled_error) unless analysis.match?(LABEL_PATTERN)

      Result.ok(clamp(analysis))
    rescue Ai::Llm::Client::Error => e
      Result.err(AppError.new(e.message, code: e.code, status: e.status))
    rescue KeyError
      # AI_* mancante → errore pulito, mai un 500 (stessa regola di Embeddings::EmbedText).
      Result.err(AppError.new(I18n.t("ai.not_configured"), code: "R502-LLM-002", status: :bad_gateway))
    end

    private

    # Idempotenza a monte del modello: un rilancio non spende 423 chiamate per riscrivere ciò che ha
    # appena scritto. La guardia sul ticket (analysis_relabeled_at) copre il caso normale; questa
    # copre l'analisi scritta a etichette da una persona, che quel timestamp non ce l'ha.
    def skip? = @body.strip.empty? || @body.match?(LABEL_PATTERN)

    def request_analysis(client)
      payload = client.generate_content(
        system: format(SYSTEM_PROMPT, target: TARGET_CHARS),
        contents: [ { role: "user", parts: [ { text: @body.truncate(INPUT_CLAMP) } ] } ],
        response_schema: ANALYSIS_SCHEMA
      )
      payload["analysis"].to_s.strip
    end

    # Clamp incondizionato: non ci si fida del modello sul conteggio dei caratteri, mai. Sul TETTO e
    # non sul bersaglio — superare il bersaglio è un'imprecisione, superare il tetto è un salvataggio
    # rifiutato da LengthBudget.
    def clamp(analysis)
      analysis.truncate(Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS, separator: " ", omission: "…")
    end

    def empty_error
      AppError.new(I18n.t("ticketing.relabel.errors.empty"), code: "R502-RELABEL-001", status: :bad_gateway)
    end

    def unlabelled_error
      AppError.new(I18n.t("ticketing.relabel.errors.unlabelled"), code: "R502-RELABEL-002", status: :bad_gateway)
    end
  end
end
