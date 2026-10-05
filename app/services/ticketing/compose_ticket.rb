# frozen_string_literal: true

module Ticketing
  # "AI Buddy": l'utente descrive in linguaggio naturale cosa gli serve e l'assistente compone
  # l'intero ticket — titolo, tipo (bug/story/task/epic), descrizione, N scenari BDD, condizioni
  # DoD e analisi tecnica. È SOLO una bozza input-assist: i campi restano la verità del model
  # Ticketing::Ticket (validati lato server), l'umano rivede e submitta il form.
  #
  # Registro: descrizione, scenari e DoD in linguaggio SEMPLICE per umani (niente gergo); i dettagli
  # tecnici (stack, componenti, ipotesi di causa) vanno SOLO in technical_analysis. Vale per tutti i kind.
  #
  # Output strutturato via `response_schema` (Ai::Structured): il modello è vincolato dall'API a
  # produrre JSON conforme → niente parsing fragile del testo libero. Stesso pattern di
  # Ticketing::AnalyzeBugReport / Ideas::SynthesizeTicket.
  class ComposeTicket < ApplicationService
    Draft = Data.define(:title, :kind, :description, :technical_analysis, :scenarios, :conditions,
                        :knowledge)

    STEP_FIELDS = %i[step_given step_when step_then step_expected].freeze
    SCENARIO_FIELDS = %w[title step_given step_when step_then step_expected].freeze
    KINDS = %w[bug story task epic].freeze
    TITLE_LIMIT = 120
    TEXT_CLAMP = 4000
    # La descrizione del progetto è scritta per gli umani e può essere lunga a piacere: al modello
    # servono le prime righe che dicono di cosa parla il prodotto, non la brochure intera.
    PROJECT_DESCRIPTION_CHARS = 500
    # Descrizione + più scenari (markdown): serve più spazio del default (1024). NON alzarlo per
    # curare un troncamento: provato contro l'API reale, a 8192 il modello ne consuma 7971 e si
    # tronca lo stesso — la degenerazione riempie qualunque spazio le si dia (CYRA-639).
    MAX_TOKENS = 3072

    # I tetti che il modello deve conoscere. Non sono decorazione del prompt: senza, il modello non
    # ha idea di quando fermarsi, e i tetti veri (Ticketing::Constants) li applica il codice DOPO,
    # tagliando a metà frase una bozza che l'utente si ritrova mozzata senza spiegazione.
    MAX_SCENARIOS = 4
    MAX_CONDITIONS = 6
    DESCRIPTION_HINT_CHARS = 600
    SCENARIO_TITLE_CHARS = 60
    STEP_CHARS = 200

    # La riga in più del SECONDO giro. Il primo tentativo non è arrivato in fondo: ripeterlo identico
    # è un'altra moneta lanciata, chiedere la versione minima cambia davvero il compito.
    SHORTER_RULE = "Il tentativo precedente non è arrivato in fondo perché troppo lungo. Questa " \
                   "volta scrivi la versione più corta che sia ancora utile: UN solo scenario, la " \
                   "descrizione in tre righe, l'analisi tecnica solo se indispensabile."

    # La forma che l'API impone alla risposta. Usa il solo sottoinsieme che il server AI accetta
    # (type/properties/required/items/enum/description): una parola chiave fuori da quello non
    # degrada, fa 400 → R502-LLM-003.
    SCHEMA = {
      type: "object",
      properties: {
        title: { type: "string", description: "Titolo conciso e azionabile del ticket" },
        kind: { type: "string", enum: KINDS, description: "Tipo di ticket" },
        description: { type: "string", description: "Riassunto breve, linguaggio semplice (no tecnicismi)" },
        scenarios: {
          type: "array",
          description: "Uno o più scenari BDD in linguaggio semplice (happy path, casi limite, errore)",
          items: {
            type: "object",
            # `required` NON è un dettaglio di validazione: senza, la grammatica del decoding
            # vincolato non obbliga mai a chiudere la stringa in corso e a passare al campo dopo, e
            # il modello degenera ripetendo finché esaurisce il budget — la risposta arriva tagliata
            # a metà e non si parsa. Misurato contro l'API del fornitore di allora: 0 bozze
            # riuscite su 5 senza, 5 su 5 con, e da ~2500 a ~400 token per bozza (CYRA-639).
            required: SCENARIO_FIELDS,
            properties: {
              title: { type: "string", description: "Etichetta breve dello scenario" },
              step_given: { type: "string", description: "Contesto/prerequisiti (Given)" },
              step_when: { type: "string", description: "Azione compiuta (When)" },
              step_then: { type: "string", description: "Cosa succede (Then)" },
              step_expected: { type: "string", description: "Cosa ci si aspetta invece (Expected)" }
            }
          }
        },
        conditions: {
          type: "array", items: { type: "string" },
          description: "Definition of Done: righe semplici e verificabili"
        },
        technical_analysis: { type: "string", description: "Dettagli tecnici (stack, causa, componenti)" }
      },
      required: %w[title kind description]
    }.freeze

    # client: lazy (default nil) → costruito dentro #call con la chiave dell'organizzazione del
    # progetto (CYRA-548). Iniettarlo resta la porta delle prove: chi lo passa porta già la sua chiave.
    #
    # correction + previous_draft (CYRA-632) arrivano SOLO al secondo giro e viaggiano insieme: una
    # correzione senza la bozza da correggere non è una correzione, è una seconda richiesta scritta
    # male. Se manca una delle due si compone da capo, che è il comportamento di sempre.
    #
    # embedding_client è separato da `client`: uno parla col server AI, l'altro col servizio di
    # embedding. Tenerli distinti serve alle prove, dove quasi sempre se ne finge uno solo.
    def initialize(project:, text:, correction: nil, previous_draft: nil, client: nil, embedding_client: nil)
      @project = project
      @text = text.to_s.strip
      @correction = correction.to_s.strip
      @previous_draft = previous_draft
      @client = client
      @embedding_client = embedding_client
      @knowledge_pages = []
    end

    def call
      return blank_text_error if @text.blank?
      if ::Ai::Feature.disabled?(:ticket_composition)
        return Result.err(::Ai::Feature.disabled_error(:ticket_composition))
      end

      client = @client || Ai::Llm::Client.new

      # Il contesto si recupera QUI, una volta sola, e non dentro i costruttori di prompt: quelli
      # devono restare pura composizione di stringhe. Un system_prompt che apre una ricerca
      # semantica è una chiamata di rete nascosta dentro qualcosa che sembra un'interpolazione —
      # parte anche quando il prompt lo si legge per un controllo, e costa un giro di embedding.
      @knowledge_pages = knowledge_pages

      args = generate(client)
      return too_long if args.nil?

      build_draft(args)
    rescue Ai::Llm::Client::Error => e
      Result.err(AppError.new(e.message, code: e.code, status: e.status))
    rescue KeyError
      # AI_* mancante → errore pulito, mai un 500 (stessa regola di Embeddings::EmbedText).
      Result.err(AppError.new(I18n.t("ai.not_configured"), code: "R502-LLM-002", status: :bad_gateway))
    rescue JSON::ParserError, TypeError
      unreadable
    end

    private

    # UN solo secondo giro, e solo sul troncamento. La generazione vincolata dallo schema resta
    # probabilistica: anche con lo schema corretto una bozza ogni tanto può non arrivare in fondo, e
    # una bozza persa è un utente che riscrive tutto a mano. Ogni altro guasto (503, auth, quota)
    # propaga subito: riguarda la richiesta o la chiave, e ripeterlo raddoppia il danno senza
    # cambiare esito — stessa regola della riserva sul 503 in Ai::Llm::Client.
    # → nil quando il secondo giro si tronca anche lui: lo traduce #too_long.
    def generate(client, shorter: false)
      ask(client, shorter: shorter)
    rescue Ai::Llm::Client::Error => e
      raise unless e.code == Ai::Llm::Client::TRUNCATED_CODE
      return nil if shorter

      Rails.logger.error("[Ticketing::ComposeTicket] bozza troncata al primo giro " \
                         "(progetto #{@project.id}): riprovo chiedendo la versione più corta")
      generate(client, shorter: true)
    end

    # Modello pieno e non quello strutturato ridotto: descrizione e scenari li legge un umano, e
    # una bozza da riscrivere da capo non fa risparmiare niente a nessuno.
    def ask(client, shorter:)
      Ai::Structured.call(client: client, system: system_prompt(shorter: shorter), user: user_prompt,
                          schema: SCHEMA, max_output_tokens: MAX_TOKENS,
                          model: Ai::Configuration.current.chat_model)
    end

    def too_long
      Result.err(AppError.new(I18n.t("member.tickets.compose.errors.too_long"),
                              code: "R502-AI-004", status: :bad_gateway))
    end

    def blank_text_error
      Result.err(AppError.new(I18n.t("member.tickets.compose.errors.blank"),
                              code: "R422-TICKET-012", status: :unprocessable_content))
    end

    # Le pagine di conoscenza pertinenti alla richiesta. Al secondo giro la query è testo +
    # correzione: la correzione sposta il tema («è una story, non un bug»), quindi la conoscenza
    # utile può non essere più quella di prima.
    #
    # Chiamata UNA volta da #call. Il risultato finisce in @knowledge_pages, che è ciò che leggono
    # la regola nel system prompt, il blocco nel user prompt e la bozza in uscita.
    def knowledge_pages
      ComposeContext.call(project: @project, query: [ @text, @correction ].compact_blank.join("\n"),
                          client: @embedding_client)
    end

    # Ordine dei blocchi: prima cosa sappiamo, poi cosa ci è stato chiesto, per ultima la correzione.
    # L'ultimo blocco è quello a cui il modello dà più peso, ed è giusto che sia l'istruzione più
    # fresca — quella che l'utente ha appena scritto guardando la bozza sbagliata.
    def user_prompt
      blocks = [ project_block ]
      blocks << knowledge_block(@knowledge_pages) if @knowledge_pages.any?
      blocks << "Richiesta:\n#{@text.truncate(TEXT_CLAMP)}"
      blocks += correction_blocks if correcting?
      blocks.join("\n\n")
    end

    # Righe presenti solo quando il dato c'è: un'etichetta vuota insegna al modello che il dato
    # esiste da qualche parte, e la reazione tipica è inventarlo (CYRA-680).
    def project_block
      lines = [ "Progetto: #{@project.name}" ]
      description = @project.description.to_s.strip
      lines << "Descrizione: #{description.truncate(PROJECT_DESCRIPTION_CHARS)}" if description.present?
      if (repository = @project.github_repository)
        lines << "Repository GitHub: #{repository.full_name} (branch #{repository.default_branch})"
      end
      lines.join("\n")
    end

    # Solo titolo e corpo troncato: tech_spec resta fuori (vedi Ticketing::ComposeContext).
    def knowledge_block(pages)
      entries = pages.map.with_index(1) do |page, index|
        "[#{index}] #{page.title}\n#{page.body.to_s.truncate(ComposeContext::PAGE_BODY_CHARS)}"
      end
      "Conoscenza del progetto (usala solo se pertinente, non inventarci sopra):\n#{entries.join("\n\n")}"
    end

    # La bozza precedente va rimandata per intero: senza, «togli il secondo scenario» non ha
    # nessun secondo scenario a cui riferirsi e il modello ne inventa uno da togliere.
    def correction_blocks
      [ "Bozza precedente:\n#{previous_draft_text}", "Correzione richiesta:\n#{@correction.truncate(TEXT_CLAMP)}" ]
    end

    def correcting? = @correction.present? && @previous_draft.present?

    # Il testo della bozza precedente, nella stessa forma in cui l'utente l'ha letta nell'anteprima.
    # Hash a chiavi stringa perché arriva dal payload jsonb di Ai::Request, non da un Draft.
    def previous_draft_text
      draft = @previous_draft
      lines = [ "titolo: #{draft['title']}", "tipo: #{draft['kind']}", "descrizione: #{draft['description']}" ]
      Array(draft["scenarios"]).each_with_index do |scenario, index|
        steps = STEP_FIELDS.filter_map { |field| scenario[field.to_s].presence }.join(" / ")
        lines << "scenario #{index + 1}: #{scenario['title']} — #{steps}"
      end
      Array(draft["conditions"]).each { |condition| lines << "condizione: #{condition}" }
      lines << "analisi tecnica: #{draft['technical_analysis']}" if draft["technical_analysis"].present?
      lines.join("\n")
    end

    def system_prompt(shorter: false)
      <<~PROMPT
        Sei un assistente che trasforma una richiesta scritta in linguaggio naturale in un ticket
        completo per un team di sviluppo. Rispondi con:
        - title: titolo conciso e azionabile (max #{TITLE_LIMIT} caratteri, senza prefissi tipo "Bug:").
        - kind: il tipo di ticket, SCELTO ESCLUSIVAMENTE tra: #{KINDS.join(', ')}.
          Usa `bug` per qualcosa che non funziona, `story` per valore nuovo o migliorato dal punto di
          vista di chi usa il prodotto, `task` per lavoro tecnico che l'utente non vede (refactor,
          aggiornamenti, configurazione), `epic` solo per un contenitore di più ticket — cioè quando
          la richiesta è chiaramente un obiettivo grosso da spezzare, non una singola cosa da fare.
        - description: un riassunto chiaro e BREVE in linguaggio SEMPLICE, come lo racconteresti a voce
          a un collega non tecnico. Niente gergo, niente stack trace, niente dettagli implementativi.
        - scenarios: uno o PIÙ scenari nel formato Given/When/Then/Expected, in linguaggio SEMPLICE per
          umani. Aggiungi uno scenario per ogni percorso rilevante (caso normale, caso limite, errore),
          non un solo scenario se il caso ne ha di più. Per ogni scenario: title (etichetta breve, es.
          "Compro e non arriva la mail"), step_given (contesto/prerequisiti), step_when (azione compiuta),
          step_then (cosa succede), step_expected (cosa ci si aspetta invece). Vale per tutti i kind.
        - conditions: la Definition of Done — righe semplici che dicono QUANDO il lavoro è fatto
          (criteri verificabili). Lascia vuoto se non ricavabili dal testo.
        - technical_analysis: QUI e solo qui i dettagli tecnici (stack, componenti coinvolti, ipotesi di
          causa, file/endpoint). Tienili FUORI da description/scenari/conditions. Vuoto se non pertinenti.
        Non inventare requisiti non presenti nel testo. Rispondi nella stessa lingua della richiesta.
        #{length_rule}#{knowledge_rule}#{correction_rule}#{shorter ? SHORTER_RULE : ''}#{Text::ItalianOrthography::PROMPT_RULE}
      PROMPT
    end

    # I tetti sono tetti, non obiettivi: un modello che non sa quando fermarsi non si ferma. Sono
    # allineati a quelli che il codice applica comunque in #build_draft, così l'utente non riceve
    # una frase tagliata a metà da un troncamento che nessuno gli ha annunciato.
    def length_rule
      "Tetti di lunghezza, sempre da rispettare: description al massimo #{DESCRIPTION_HINT_CHARS} " \
        "caratteri; al massimo #{MAX_SCENARIOS} scenari, ciascuno con title al massimo " \
        "#{SCENARIO_TITLE_CHARS} caratteri e step al massimo #{STEP_CHARS} caratteri; al massimo " \
        "#{MAX_CONDITIONS} condizioni, una riga ciascuna; technical_analysis al massimo " \
        "#{Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS} caratteri. Se una cosa si dice in " \
        "meno, dilla in meno, e chiudi.\n"
    end

    # La regola compare SOLO quando la conoscenza c'è davvero: nominarla a vuoto insegnerebbe al
    # modello che da qualche parte esiste un contesto che non ha ricevuto, e la reazione tipica è
    # riempirlo da sé.
    def knowledge_rule
      return "" if @knowledge_pages.empty?

      "Le pagine sotto «Conoscenza del progetto» dicono come funziona davvero questo prodotto: " \
        "usale per i nomi giusti e per non contraddire decisioni già prese. Non sono la richiesta — " \
        "se non c'entrano con quello che ti viene chiesto, ignorale, e non tirarne dentro requisiti.\n"
    end

    # Riscrittura, non ricomposizione: senza questa riga il modello riparte dalla richiesta e
    # restituisce una bozza diversa dappertutto, e chi aveva chiesto di cambiare una cosa sola si
    # ritrova a rileggere tutto per capire cosa è successo.
    def correction_rule
      return "" unless correcting?

      "Stai RISCRIVENDO la bozza qui sotto applicando la correzione richiesta. Tieni tutto quello " \
        "che la correzione non contesta — stesse parole dove puoi — e cambia solo ciò che serve. " \
        "Non ripartire da zero.\n"
    end

    # title vuoto → fallback generico; kind fuori dai consentiti → bug (sempre valido); description
    # vuota → output inutilizzabile. Scenari/DoD/analisi tecnica opzionali.
    def build_draft(args)
      description = args["description"].to_s.strip
      return unreadable if description.blank?

      kind = KINDS.include?(args["kind"].to_s) ? args["kind"].to_s : "bug"

      # Tutti troncati ai tetti del ticket: un modello che sfora non deve produrre una bozza che il
      # form rifiuta e l'utente deve tagliare a mano (stessa scelta di Ideas::SynthesizeTicket).
      Result.ok(Draft.new(
                  title: (args["title"].to_s.strip.presence || @text).truncate(TITLE_LIMIT),
                  kind:,
                  description: description.truncate(Ticketing::Constants::DESCRIPTION_MAX_CHARS),
                  technical_analysis: args["technical_analysis"].to_s.strip.presence
                                          &.truncate(Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS),
                  scenarios: self.class.parse_scenarios(args["scenarios"]),
                  conditions: self.class.parse_conditions(args["conditions"]),
                  knowledge: @knowledge_pages.map { |page| { id: page.id, title: page.title } }
                ))
    end

    # Normalizza gli scenari dal tool-output: scarta le righe senza alcuno step, strippa i valori.
    # Ritorna array di hash a chiavi simbolo {title, step_given, step_when, step_then, step_expected}.
    def self.parse_scenarios(raw)
      Array(raw).filter_map do |item|
        next unless item.is_a?(Hash)

        steps = STEP_FIELDS.index_with { |field| item[field.to_s].to_s.strip.presence }
        next if steps.values.all?(&:blank?)

        { title: item["title"].to_s.strip.presence }.merge(steps)
      end
    end

    def self.parse_conditions(raw)
      Array(raw).map { |condition| condition.to_s.strip }.reject(&:blank?)
    end

    def unreadable
      Result.err(AppError.new(I18n.t("member.tickets.compose.errors.unreadable"),
                              code: "R502-AI-003", status: :bad_gateway))
    end
  end
end
