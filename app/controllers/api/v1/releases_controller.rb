# frozen_string_literal: true

module Api
  module V1
    # Release tracking a token bearer: la CI registra la release deployata (version obbligatoria,
    # sha/build_time opzionali) — upsert idempotente per [project, version, environment], ripetere la
    # chiamata è innocuo. L'environment è quello del TOKEN (staging vs production), non del body.
    # GET elenca le release recenti del progetto del token. Envelope {data}/{error}.
    class ReleasesController < Api::V1::BaseController
      # Scope per azione (CYRA-37): la lettura richiede 'read', l'upsert da CI richiede 'ingest'.
      before_action -> { require_scope!(:read) }, only: :index
      before_action -> { require_scope!(:ingest) }, only: :create

      def index
        # CYRA-738 — la lista la costruisce Projects::Releases::Query, la stessa del canale CLI.
        # Il tetto di cinquanta è il contratto di questa API (non paginata), non parte della domanda.
        render_ok(ReleaseSerializer.new(::Projects::Releases::Query.call(project: Current.project).limit(50)))
      end

      def create
        version = params[:version].to_s.strip
        return render_error("R422-RELEASE-001", "version obbligatoria", status: :unprocessable_content) if version.blank?

        # L'environment è quello DEL TOKEN (già environment-specific), non del body: non falsificabile
        # dal chiamante. La CI usa il token dell'environment giusto (staging vs production).
        environment = Current.api_token.environment.code
        release = Current.project.releases.find_or_initialize_by(version: version, environment: environment)
        release.sha = params[:sha].presence || release.sha
        release.build_time = parse_time(params[:build_time]) || release.build_time
        release.proved_at = Time.current if proved_registration?(release)
        release.save!

        # Binding tag→release live: se il progetto ha un repo GitHub agganciato con tag_binding, marca
        # questa release come `current` per l'environment quando la stabilità del tag lo mappa (no-op
        # altrimenti). Il tag GitHub, se già arrivato, ha già tentato lo stesso binding (convergenza).
        Github::Releases::Reconcile.call(project: Current.project, version: version, environment: environment)

        render json: { data: ReleaseSerializer.new(release).as_json }, status: :created
      rescue ActiveRecord::RecordNotUnique
        # Race di creazione concorrente: al secondo giro la release esiste → update. Un solo retry.
        if (retried = !retried)
          retry
        else
          raise
        end
      end

      private

      def parse_time(raw)
        return nil if raw.blank?

        Time.zone.parse(raw.to_s)
      rescue ArgumentError
        nil
      end

      # CYRA-607 — il timbro «questa versione l'ha vista qualcuno in piedi». Tre condizioni, e la
      # terza non e' pignoleria.
      #
      # 1. Il chiamante DICE di aver verificato (`proved_at` nel corpo). Il valore non si legge: si
      #    timbra con l'ora del server. Quello che conta e' l'affermazione, non l'ora dichiarata.
      # 2. Porta il codice esatto: un timbro senza sigla non si puo' confrontare con niente.
      # 3. Il token e' quello dell'ambiente di PRODUZIONE di questo repository. L'ambiente arriva dal
      #    token, non dal corpo, quindi non e' falsificabile dal chiamante.
      #
      # La prima condizione e' quella che rende la cosa sicura OGGI. La CI che verifica davvero —
      # legge /version dalla produzione, confronta versione e codice, e solo allora registra — manda
      # `proved_at`. Quella vecchia registra dal lavoro che mette in linea, PRIMA di qualunque
      # controllo, e `proved_at` non lo manda: senza la condizione 1, ogni repository ancora sulla CI
      # vecchia timbrerebbe una spia verde attaccata a un filo staccato. Al momento in cui questo
      # viene scritto sono dieci su undici.
      #
      # Sullo staging non si timbra mai, e non serve una regola in piu': l'ambiente del token non e'
      # quello di produzione, quindi la condizione 3 basta da sola.
      def proved_registration?(release)
        return false if params[:proved_at].blank?
        return false if release.sha.blank?

        production_env_id = Current.project.github_repository&.production_environment_id
        production_env_id.present? && production_env_id == Current.api_token.environment_id
      end
    end
  end
end
