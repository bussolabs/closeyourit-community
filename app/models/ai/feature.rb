# frozen_string_literal: true

module Ai
  # Interruttori per-servizio delle funzioni AI, decisi dal god in Valhalla (Settings::Global).
  #
  # PORO costante come Monitoring::Tool: il catalogo dei servizi è dev-defined (ogni chiave ha un
  # punto di innesto scritto nel codice), non una tabella CRUD. Aggiungere un servizio = aggiungere
  # una chiave qui, una colonna in settings_global e una guardia nel service che chiama il provider.
  #
  # PERCHÉ ESISTE: il 2026-07-29 un backfill del gate agenti ha saturato il rate limit del provider e
  # innescato una valanga di errori; l'unico modo di fermarlo sarebbe stato un deploy. Un interruttore
  # raggiungibile da un umano in dieci secondi è la differenza fra un incidente e un fastidio.
  #
  # NON è un feature flag di prodotto (chi vede cosa) ma un **freno d'emergenza operativo**: vale per
  # tutte le organizzazioni insieme, e la sua sola sede legittima è il pannello god.
  module Feature
    # Un servizio per punto di uscita verso un provider AI. L'ordine è quello mostrato in Valhalla.
    KEYS = %i[
      agent_gate
      assistant_chat
      assistant_tools
      assistant_voice
      triage
      embeddings
      ticket_composition
      dataset_predictions
      comment_compaction
      analysis_relabel
      knowledge_review
    ].freeze

    # Le funzioni che escono verso il PROVIDER GENERATIVO (Gemini): tutte tranne quelle che parlano
    # col server AI di casa (LiteLLM sul DGX) e hanno già il loro controllo di salute — gli embedding
    # e, dal CYRA-764, il revisore delle pagine di conoscenza. Serve a chi deve sapere se
    # «l'intelligenza artificiale» del prodotto è accesa nel suo insieme (CYRA-712), non se lo è una
    # singola funzione.
    GENERATIVE_KEYS = (KEYS - %i[embeddings knowledge_review]).freeze

    # Servizio spento dal god → i service di dominio si fermano PRIMA di spendere una chiamata.
    # 503 e non 502: l'upstream sta benissimo, siamo noi ad aver chiuso il rubinetto.
    ERROR_CODE = "R503-AI-001"

    module_function

    def enabled?(key)
      key = key.to_sym
      raise ArgumentError, "servizio AI sconosciuto: #{key}" unless KEYS.include?(key)

      settings = Settings::Global.instance
      settings.public_send(:"ai_#{key}_enabled")
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError => e
      # Tabella/colonna non ancora migrata, o DB irraggiungibile mentre si legge una CONFIGURAZIONE.
      # Fail-OPEN di proposito, all'opposto del gate di eleggibilità: lì il default sicuro è "non
      # lavorare il ticket", qui sarebbe spegnere tutta l'AI del prodotto per un errore di lettura di
      # un interruttore. Chi vuole spegnere lo fa esplicitamente.
      Rails.logger.warn("[ai-feature] interruttori illeggibili, assumo acceso #{key}: #{e.class}")
      true
    end

    def disabled?(key) = !enabled?(key)

    # Il god ha spento OGNI funzione generativa? (CYRA-712) Chi controlla la salute del provider lo
    # chiede per non avvisare nessuno di un guasto su una porta che nessuno sta usando: il freno
    # d'emergenza esiste per fermare una valanga, non per accenderne un'altra fatta di avvisi.
    def generative_disabled? = GENERATIVE_KEYS.all? { |key| disabled?(key) }

    # AppError pronto per il ramo `Result.err` dei service.
    def disabled_error(key)
      AppError.new(
        I18n.t("ai.feature.disabled", service: I18n.t("ai.feature.services.#{key}")),
        code: ERROR_CODE,
        status: :service_unavailable
      )
    end
  end
end
