# frozen_string_literal: true

module Errors
  # Divide un gruppo d'errore estraendo alcune occorrenze in un NUOVO gruppo (CYRA-153). È il gesto
  # opposto della fusione: quando un gruppo raccoglie occorrenze di problemi in realtà diversi (un
  # fingerprint troppo generico, o una fusione fatta con troppa larghezza), se ne stacca un pezzo.
  #
  # Prende gli **id delle occorrenze** e non i record: risolverli qui dentro è l'unico modo per
  # garantire tutto-o-niente (o si separano tutte quelle chieste, o niente), come per la fusione.
  #
  # Il fingerprint del nuovo gruppo decide se la divisione "TIENE" anche per il futuro:
  #  - se le occorrenze estratte hanno TUTTE lo stesso fingerprint EFFETTIVO (quello che l'ingest
  #    produrrebbe davvero, regole di raggruppamento comprese), diverso dal sorgente e ancora libero,
  #    il nuovo gruppo lo adotta → l'ingest ci manderà le occorrenze successive di quel tipo, e se quel
  #    fingerprint era stato assorbito da una fusione lo si toglie dai `merged_fingerprints` del
  #    sorgente (annulla la fusione per quella sola chiave);
  #  - altrimenti (insieme eterogeneo, stesso fingerprint del sorgente, o già occupato) il nuovo gruppo
  #    nasce con una chiave SINTETICA: è una riorganizzazione delle occorrenze già raccolte, mentre le
  #    nuove continuano ad arrivare al sorgente. Così non si ruba né si duplica un raggruppamento
  #    esistente in silenzio.
  class Split < ApplicationService
    def initialize(group:, event_ids:)
      @group = group
      @event_ids = Array(event_ids).map(&:to_s).uniq
    end

    def call
      return Result.err(no_events_error) if @event_ids.empty?

      new_group = nil
      ActiveRecord::Base.transaction do
        # Lock sul sorgente PRIMA di leggerne le occorrenze: l'ingest è continuo e un'occorrenza che
        # arrivasse durante lo spostamento falserebbe i contatori ricalcolati sotto.
        @group.lock!

        moved = resolve_events!(@event_ids)
        remaining_count = @group.events.where.not(id: moved.map(&:id)).count
        # Separare TUTTE le occorrenze presenti lascerebbe il sorgente vuoto: è un'eliminazione
        # travestita, non una divisione. Chi vuole svuotare un gruppo usa destroy.
        raise SplitError, drains_source_error if remaining_count.zero?

        fingerprint = fingerprint_for(moved)
        new_group = build_new_group!(fingerprint)
        Errors::Event.where(id: moved.map(&:id)).update_all(group_id: new_group.id)
        release_absorbed_fingerprint!(fingerprint)
        recount!(new_group)
        recount!(@group)
      end

      Result.ok(new_group)
    rescue SplitError => e
      Result.err(e.app_error)
    end

    private

    # Errore interno per abortire la transazione senza che venga assorbita in silenzio (come Merge):
    # ActiveRecord::Rollback proseguirebbe fino a Result.ok mentendo sull'esito.
    class SplitError < StandardError
      attr_reader :app_error

      def initialize(app_error)
        super(app_error.message)
        @app_error = app_error
      end
    end

    # Tutto-o-niente: un id che non appartiene a QUESTO gruppo (altro gruppo, altro progetto, o dato
    # vecchio) ferma tutto. Separare quelle trovate e ignorare le altre lascerebbe l'utente convinto
    # di aver spostato più occorrenze di quelle davvero spostate.
    def resolve_events!(wanted)
      found = @group.events.where(id: wanted).to_a
      missing = wanted - found.map { |e| e.id.to_s }
      raise SplitError, unknown_events_error(missing) if missing.any?

      found
    end

    # Il nuovo gruppo "tiene" (riceve anche le occorrenze future di quel tipo) SOLO se le occorrenze
    # estratte hanno TUTTE lo stesso fingerprint EFFETTIVO — quello che l'ingest produrrebbe davvero,
    # regole di raggruppamento comprese — diverso dal sorgente e ancora libero. Un insieme eterogeneo,
    # o una chiave già occupata / uguale al sorgente, non ha un fingerprint unico che lo rappresenti:
    # chiave sintetica, e la divisione resta una riorganizzazione delle occorrenze già raccolte.
    def fingerprint_for(events)
      effective = events.map { |event| effective_fingerprint(event) }.uniq
      candidate = effective.first
      return candidate if effective.one? && candidate != @group.fingerprint && free?(candidate)

      synthetic_fingerprint
    end

    # Il fingerprint che l'ingest assegnerebbe DAVVERO a questa occorrenza: quello automatico PIÙ le
    # regole di raggruppamento del progetto (che potrebbero rimapparlo). Senza applicarle, il nuovo
    # gruppo adotterebbe una chiave che l'ingest non produce mai e le occorrenze future finirebbero
    # altrove — proprio ciò che la divisione vuole evitare.
    def effective_fingerprint(event)
      base = Errors::Fingerprint.call(payload: event.payload)
      Errors::ApplyGroupingRules.call(project: project, payload: event.payload, fingerprint: base)
    end

    # Libero = nessun gruppo del progetto lo usa come fingerprint diretto né lo tiene fra gli assorbiti
    # da una fusione (in quel caso l'ingest lo risolverebbe lì).
    def free?(fingerprint)
      return false if project.error_groups.where(fingerprint: fingerprint).exists?

      !project.error_groups.where.not(id: @group.id)
              .where("merged_fingerprints @> ARRAY[?]::text[]", [ fingerprint ]).exists?
    end

    def synthetic_fingerprint = "split:#{SecureRandom.hex(16)}"

    # Il nuovo gruppo eredita l'identità descrittiva del sorgente (stesso tipo d'errore, punto di
    # partenza sensato); le finestre temporali le fissa recount! sui soli eventi spostati.
    def build_new_group!(fingerprint)
      project.error_groups.create!(
        fingerprint: fingerprint,
        title: @group.title,
        culprit: @group.culprit,
        level: @group.level,
        release: @group.release,
        first_seen_release: @group.first_seen_release,
        has_unhandled: @group.has_unhandled,
        first_seen_at: @group.first_seen_at,
        last_seen_at: @group.last_seen_at
      )
    end

    # Se il nuovo gruppo ha adottato un fingerprint reale che il sorgente teneva tra gli assorbiti,
    # lo si toglie di lì: altrimenti l'ingest continuerebbe a risolverlo al sorgente, contraddicendo
    # la divisione appena fatta.
    def release_absorbed_fingerprint!(fingerprint)
      return unless @group.merged_fingerprints.include?(fingerprint)

      @group.update!(merged_fingerprints: @group.merged_fingerprints - [ fingerprint ])
    end

    # Ricalcola i contatori dai dati REALI (a differenza della fusione, che somma perché le righe
    # potate non ci sono più: qui le occorrenze sono presenti e si contano). events_count del sorgente
    # si DECREMENTA per non buttare il cumulativo storico; gli altri numeri si ricalcolano sulle righe
    # rimaste. `users_count` è "almeno tanti" (utenti distinti tra le occorrenze conservate).
    def recount!(group)
      events = group.events
      users = events.where.not(user_hash: nil).distinct.count(:user_hash)
      group.update!(
        events_count: group == @group ? [ @group.events_count - moved_from_source, 0 ].max : events.count,
        users_count: users,
        # user_context_seen è MONOTÒNO (CYRA-380): il sorgente che aveva già ricevuto contesto utente
        # resta «tracciato» anche se la potatura ha lasciato zero user_hash tra le occorrenze conservate
        # (a differenza di users_count, che qui torna a zero); il nuovo gruppo è tracciato sse ne contiene.
        user_context_seen: group.user_context_seen? || users.positive?,
        first_seen_at: events.minimum(:occurred_at) || group.first_seen_at,
        last_seen_at: events.maximum(:occurred_at) || group.last_seen_at
      )
    end

    def moved_from_source
      @moved_from_source ||= @event_ids.size
    end

    def no_events_error
      AppError.new("Serve almeno un'occorrenza da separare", code: "R422-ERROR-005")
    end

    def unknown_events_error(missing)
      AppError.new(
        "Occorrenze non trovate in questo gruppo: #{missing.join(', ')}. Nessuna divisione eseguita.",
        code: "R422-ERROR-006"
      )
    end

    def drains_source_error
      AppError.new(
        "Non puoi separare tutte le occorrenze: il gruppo resterebbe vuoto. Per svuotarlo, eliminalo.",
        code: "R422-ERROR-007"
      )
    end

    def project = @group.project
  end
end
