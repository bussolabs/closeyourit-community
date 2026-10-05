# frozen_string_literal: true

module Knowledge
  # Il revisore automatico di una pagina (CYRA-764): pre-check deterministico, poi il modello del
  # server AI di casa con le regole di app/prompts/knowledge/review.md. Gira SINCRONO dentro
  # CreatePage/UpdatePage/Pages::Publish, prima di ogni transazione, e nel job di riclassificazione.
  #
  # Usa il client generativo comune con AI_API_KEY e l’endpoint CHAT_BASE_URL.
  # Lo switch knowledge_review resta
  # indipendente dalla rotazione della credenziale (CYRA-841).
  #
  # Esiti:
  #   Result.ok(nil)      — revisore spento dal god (Ai::Feature): la pagina entra senza verdetto,
  #                         e il registro lo dice.
  #   Result.ok(Verdict)  — giudicata; è il chiamante a fermarsi se `rejected?` (Review.rejection).
  #   Result.err          — R503-KNOWLEDGE-001 (server giù, tempo scaduto, chiave rifiutata, ENV
  #                         assenti) o R502-KNOWLEDGE-001 (verdetto illeggibile). FAIL-CLOSED: senza
  #                         verdetto la pagina NON entra. Il freno è l'interruttore in Valhalla.
  #
  # Il pre-check che boccia non chiama il modello: zero rete, zero latenza. Le pagine vicine per
  # embedding entrano nel prompt per il giudizio sul doppione (K13); se l'embedding è giù si va
  # avanti senza — un revisore che non vede i vicini è meglio di nessun revisore.
  #
  # Il giudizio si RICORDA per la domanda esatta (CYAU-200): la stessa pagina inviata due volte era
  # rifiutata la prima e accettata la seconda, e chi pubblicava non sapeva se correggere o riprovare.
  # Il modello non è ripetibile nemmeno a temperatura zero, quindi la ripetibilità la mette qui
  # l'applicazione.
  class ReviewPage < ApplicationService
    UNAVAILABLE_CODE = "R503-KNOWLEDGE-001"
    REVIEWED_STATUSES = %i[published in_review].freeze

    # `scope` è la relation delle pagine che il revisore PUÒ nominare — wikilink (K14), serie (P05),
    # vicine e `duplicate_of` (K13): le pagine visibili a chi scrive, non l'intera organizzazione, o un
    # titolo che l'attore non vede trapelerebbe in un messaggio d'errore. La costruisce il chiamante
    # (Knowledge::Page.visible_to, o for_projects nel giro senza attore).
    def initialize(title:, body:, tech_spec:, kind:, tags:, scope:, exclude_page_id: nil, neighbours: true, client: nil,
                   precheck_only: false, legacy: false)
      @precheck_only = precheck_only
      @legacy = legacy
      @title = title
      @body = body
      @tech_spec = tech_spec
      @kind = kind
      @tags = tags
      @scope = scope
      @exclude_page_id = exclude_page_id
      @neighbours = neighbours
      @client = client
    end

    def call
      if Ai::Feature.disabled?(:knowledge_review)
        Rails.logger.warn("[knowledge-review] revisore spento dal god: la pagina «#{@title.to_s.first(80)}» entra senza verdetto")
        return Result.ok(nil)
      end

      precheck = Knowledge::Review::Precheck.call(title: @title, body: @body, tech_spec: @tech_spec, kind: @kind,
                                                  tags: @tags, known_titles: known_titles, legacy: @legacy)
      return Result.ok(precheck_rejection(precheck)) if precheck.any?(&:blocking)
      # Solo le regole meccaniche (un cambio di soli tag, K11): nessun verdetto nuovo sul testo.
      return Result.ok(nil) if @precheck_only

      rules = Knowledge::Review::Rules.system_prompt
      page = user_prompt
      key = memory_key(rules, page)
      remembered = Rails.cache.read(key)
      answer = remembered || ask_model(rules, page)

      result = parse(answer, precheck)
      return result if remembered || result.err?

      # Il verdetto è leggibile: si ricorda. Se intanto un gemello è arrivato primo vince il suo, e
      # questo giro lo adotta — due esiti diversi non possono uscire dalla stessa domanda.
      kept = remember(key, answer)
      kept == answer ? result : parse(kept, precheck)
    rescue KeyError
      unavailable("unconfigured")
    rescue Ai::Llm::Client::Error => e
      Rails.logger.error("[knowledge-review] server AI non disponibile: #{e.code} #{e.message}")
      unavailable(e.code)
    end

    private

    # L'impronta della domanda esatta: regole, pagina (titolo, kind, tag, corpo, parte tecnica),
    # pagine vicine e schema della risposta. Cambiata una virgola è una domanda nuova; identica, vale
    # il giudizio di prima. `v1` davanti perché, se cambia la FORMA di ciò che si ricorda, le voci
    # vecchie vanno ignorate e non lette a metà.
    def memory_key(rules, page)
      digest = Digest::SHA256.hexdigest([ rules, page, Knowledge::Review::SCHEMA.to_json ].join("\n"))
      "knowledge-review/v1/#{digest}"
    end

    def ask_model(rules, page)
      client = @client || Ai::Llm::Client.new(credentials: :knowledge_review)
      payload = Ai::Structured.call(client: client, system: rules, user: page,
                                    schema: Knowledge::Review::SCHEMA,
                                    max_output_tokens: Knowledge::Constants::REVIEW_MAX_OUTPUT_TOKENS,
                                    deadline_seconds: Knowledge::Constants::REVIEW_DEADLINE_SECONDS)
      { payload: payload, model: client.usage.model }
    end

    def parse(answer, precheck)
      Knowledge::Review::Parse.call(payload: answer[:payload], model: answer[:model],
                                    precheck_violations: precheck, source: source_text)
    end

    # Ricorda la risposta e restituisce quella che vale: la propria, o quella che c'era già.
    # `unless_exist` perché due salvataggi gemelli partiti insieme trovano ENTRAMBI la memoria vuota,
    # e chi scrive per ultimo cancellerebbe il verdetto appena consegnato all'altro — di nuovo due
    # esiti sulla stessa pagina, che è il difetto da cui si parte. Si ricorda solo un verdetto
    # LEGGIBILE: ripetere una risposta che non si sa interpretare terrebbe ferma la pagina per giorni
    # senza che nessuno abbia sbagliato niente.
    def remember(key, answer)
      return answer if Rails.cache.write(key, answer, expires_in: Knowledge::Constants::REVIEW_MEMORY_TTL,
                                                      unless_exist: true)

      Rails.cache.read(key) || answer
    end

    # Il testo su cui si verificano i passaggi citati dal modello (CYAU-200).
    def source_text = [ @body, @tech_spec ].compact_blank.join("\n")

    # I titoli con cui il pre-check risolve wikilink e serie (K14, P05): lo scope visibile, senza le
    # pagine scartate e senza la pagina stessa quando si sta aggiornando.
    def known_titles
      pages.pluck(:title)
    end

    def pages
      scope = @scope.where(status: REVIEWED_STATUSES)
      scope = scope.where.not(id: @exclude_page_id) if @exclude_page_id
      scope
    end

    def precheck_rejection(violations)
      Knowledge::Review::Verdict.new(
        format: Knowledge::Review::Precheck.format_of(@body) || "unknown", verdict: "reject", violations: violations,
        suggested_kind: nil, suggested_title: nil, split_suggestion: [], duplicate_of: nil, model: nil
      )
    end

    LEGACY_NOTE = <<~TEXT
      Pagina scritta PRIMA delle regole di forma (giro sul parco, modalità legacy): ignora K01 (riga
      `Formato:`), K11 (tag) e K10 (kind); deduci tu il formato dal contenuto e mettilo in `format`.
      Giudica SOLO la sostanza: vale la pena tenerla? Se non rientra in nessun formato, `unknown`.
    TEXT

    def user_prompt
      lines = [ "Titolo: #{@title}", "Kind: #{@kind}", "Tag: #{Array(@tags).join(', ').presence || '(nessuno)'}" ]
      lines << "" << LEGACY_NOTE if @legacy
      titles = neighbour_titles
      lines << "Pagine vicine per significato (per la regola K13):" << titles.map { |t| "- #{t}" } if titles.any?
      lines << "" << "--- Corpo ---" << @body.to_s
      lines << "" << "--- Parte tecnica ---" << @tech_spec.to_s if @tech_spec.present?
      lines.flatten.join("\n")
    end

    def neighbour_titles
      return [] unless @neighbours

      vector = Embeddings::QueryVector.call(query: "#{@title}\n#{@body.to_s.first(1_000)}")
      return [] if vector.err?

      pages.where.not(embedding: nil).current_embedding
           .nearest_neighbors(:embedding, vector.value, distance: "cosine")
           .limit(Knowledge::Constants::REVIEW_NEIGHBOURS).pluck(:title)
    rescue StandardError => e
      Rails.logger.warn("[knowledge-review] vicini non disponibili (#{e.class}): giudizio senza doppioni")
      []
    end

    def unavailable(cause)
      Result.err(AppError.new(I18n.t("member.knowledge.errors.review_unavailable"), code: UNAVAILABLE_CODE,
                              status: :service_unavailable, details: { cause: cause }))
    end
  end
end
