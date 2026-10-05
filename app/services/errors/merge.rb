# frozen_string_literal: true

module Errors
  # Fonde più gruppi d'errore in uno solo (CYRA-192): le occorrenze passano al primario, i contatori
  # si aggregano, i fingerprint assorbiti restano puntati qui e i gruppi sorgente spariscono.
  #
  # È IRREVERSIBILE per scelta esplicita — a differenza degli incident uptime, che si collassano
  # sotto un `parent_id` e si possono separare. Da qui discendono quasi tutte le decisioni sotto:
  # un'operazione che non si annulla non può permettersi di riuscire a metà, né in silenzio.
  #
  # Prende gli **id** e non i record: risolverli qui dentro è l'unico modo per garantire che o si
  # fondono tutti quelli chiesti, o non si fonde niente (vedi `resolve_sources!`).
  class Merge < ApplicationService
    def initialize(primary:, source_ids:)
      @primary = primary
      @source_ids = Array(source_ids).map(&:to_s).uniq
    end

    def call
      # L'esclusione del primario è difensiva: una UI che passa "tutti i selezionati" lo includerebbe,
      # e fondere un gruppo con sé stesso lo cancellerebbe. Va tolto PRIMA del conteggio, altrimenti
      # il chiamante riporterebbe un gruppo fuso in più di quelli davvero assorbiti.
      wanted = @source_ids - [ @primary.id.to_s ]
      return Result.err(no_sources_error) if wanted.empty?

      sources = nil
      ActiveRecord::Base.transaction do
        sources = resolve_sources!(wanted)
        # Lock pessimistico sulle sorgenti PRIMA di spostare: l'ingest di questi gruppi è continuo, e
        # un'occorrenza che arrivasse fra `move_events!` e la cancellazione verrebbe distrutta dalla
        # cascade sulla FK — persa in silenzio, che su un'operazione irreversibile è il peggio.
        sources.each(&:lock!)

        absorb_fingerprints!(sources)
        move_events!(sources)
        move_log_links!(sources)
        absorb_counters!(sources)
        # I gruppi muoiono QUI, dopo che tutto ciò che portavano ha cambiato padrone: `has_many
        # :events, dependent: :destroy` cancellerebbe le occorrenze ancora appese a loro.
        Errors::Group.where(id: sources.map(&:id)).destroy_all
      end

      Result.ok(@primary.reload)
    rescue MergeError => e
      Result.err(e.app_error)
    end

    private

    # Errore interno per abortire la transazione: `ActiveRecord::Rollback` NON va bene, perché la
    # transazione lo assorbe silenziosamente e il service proseguirebbe fino a `Result.ok` — dicendo
    # che la fusione è riuscita mentre il database è rimasto intatto.
    class MergeError < StandardError
      attr_reader :app_error

      def initialize(app_error)
        super(app_error.message)
        @app_error = app_error
      end
    end

    # Tutti o nessuno. Uno scope che filtra e prosegue fonderebbe i gruppi trovati e ignorerebbe gli
    # altri: chi ha chiesto di unirne tre ne vedrebbe uniti due, senza che nulla glielo dica, e senza
    # poter tornare indietro. Un id sconosciuto è quasi sempre un id di un ALTRO progetto (lo scope è
    # già gattato) o un refresh su dati vecchi: in entrambi i casi va fermato tutto.
    def resolve_sources!(wanted)
      found = @primary.project.error_groups.where(id: wanted).to_a
      missing = wanted - found.map { |g| g.id.to_s }
      raise MergeError, unknown_sources_error(missing) if missing.any?

      found
    end

    # I fingerprint assorbiti (più quelli che le sorgenti avevano già assorbito in fusioni
    # precedenti) restano puntati al primario: senza, la prima occorrenza successiva ricreerebbe il
    # gruppo appena fuso. Vedi Errors::Ingest::Record#upsert_group, che li risolve.
    def absorb_fingerprints!(sources)
      absorbed = sources.flat_map { |g| [ g.fingerprint, *g.merged_fingerprints ] }.compact
      @primary.update!(merged_fingerprints: (@primary.merged_fingerprints + absorbed).uniq)
    end

    def move_events!(sources)
      Errors::Event.where(group_id: sources.map(&:id)).update_all(group_id: @primary.id)
    end

    # I log collegati a mano a un gruppo sono lavoro umano di correlazione: `dependent: :destroy` li
    # butterebbe insieme al gruppo. `insert_all` con `unique_by` perché il primario può già avere lo
    # stesso log collegato, e il vincolo di unicità farebbe fallire tutta la fusione.
    def move_log_links!(sources)
      links = Logs::Link.where(linkable_type: "Errors::Group", linkable_id: sources.map(&:id))
      return if links.empty?

      rows = links.map do |link|
        link.attributes.except("id", "created_at", "updated_at")
            .merge("linkable_id" => @primary.id, "created_at" => Time.current, "updated_at" => Time.current)
      end
      Logs::Link.insert_all(rows, unique_by: %i[linkable_type linkable_id log_entry_id])
      links.delete_all
    end

    # `events_count` si SOMMA: è un totale di occorrenze e sopravvive alla potatura, quindi un COUNT
    # sulle righe rimaste direbbe meno del vero.
    #
    # `users_count` NO: è un conteggio di utenti DISTINTI, e sommarlo conterebbe due volte chi ha
    # incontrato entrambi gli errori — cosa probabile proprio nei gruppi che si fondono, che per
    # definizione sono lo stesso guasto. Senza i set degli utenti non si può calcolare l'unione:
    # teniamo il massimo, che è l'unico numero certamente vero ("almeno tanti"). Sottostima invece
    # di gonfiare, che su un dato mostrato all'utente è il verso giusto in cui sbagliare.
    def absorb_counters!(sources)
      @primary.update!(
        events_count: @primary.events_count + sources.sum(&:events_count),
        users_count: [ @primary.users_count, *sources.map(&:users_count) ].max,
        # user_context_seen è un fatto storico monotòno (CYRA-380): se il primario o QUALSIASI gruppo
        # fuso aveva ricevuto contesto utente, il gruppo risultante resta «tracciato».
        user_context_seen: [ @primary, *sources ].any?(&:user_context_seen?),
        first_seen_at: [ @primary.first_seen_at, *sources.map(&:first_seen_at) ].compact.min,
        last_seen_at: [ @primary.last_seen_at, *sources.map(&:last_seen_at) ].compact.max
      )
    end

    # Messaggi in chiaro come il gemello Errors::Triage: li legge chi chiama l'API o la CLI.
    def no_sources_error
      AppError.new("Serve almeno un gruppo da fondere, diverso dal primario", code: "R422-ERROR-003")
    end

    def unknown_sources_error(missing)
      AppError.new(
        "Gruppi non trovati in questo progetto: #{missing.join(', ')}. Nessuna fusione eseguita.",
        code: "R422-ERROR-004"
      )
    end
  end
end
