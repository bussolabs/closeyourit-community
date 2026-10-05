# frozen_string_literal: true

module Member
  module Monitoring
    # Galleria session replay (UI Member): sfoglia le sessioni registrate e guardane una qualsiasi.
    # Lettura per chiunque veda il progetto (scoping visible.replay_sessions, anti-BOLA);
    # nessuna chiave RBAC — read = visibilità di scope, come analytics/logs/errors.
    class ReplaysController < Member::BaseController
      permission_not_required "Registrazioni dei progetti visibili: sola lettura, il confine è la visibilità dei " \
                              "progetti.",
                              only: %i[index show player]

      # CYRA-737 — la base condivisa delle pagine-elenco dell'area di controllo.
      include Indexable

      # Whitelist ordinamento (contratto Sortable). Solo colonne indicizzate/denormalizzate.
      SORT_COLUMNS = {
        "started" => :started_at,
        "duration" => :duration_ms,
        "events" => :events_count,
        "user" => :user_hash,
        "page" => "LOWER(replays_sessions.entry_path)"
      }.freeze

      # Parametri che restringono l'elenco: con uno di questi attivo la pagina vuota è «nessun
      # risultato», non «la funzione non è mai partita» — due messaggi diversi.
      FILTER_PARAMS = %i[q environment project_id with_errors].freeze

      before_action :set_session, only: %i[show player]

      # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
      remembers_filters :environment, :project_id, :with_errors, :q, only: :index

      def index
        scope = visible.replay_sessions.includes(:project).recent
        scope = filter_by_project(scope)
        scope = scope.for_environment(filter_ids(:environment)) if filter_ids(:environment).any?
        scope = scope.for_user(filter_ids(:user_hash)) if filter_ids(:user_hash).any?
        scope = scope.with_errors if params[:with_errors] == "1"
        scope = filter_by_search(scope, "replays_sessions.entry_path")

        @sessions = paginated(scope, columns: SORT_COLUMNS)
        @error_counts = error_counts_for(@sessions)
        load_filter_projects
        @environments = visible.replay_sessions.distinct.pluck(:environment).compact.sort
        @filtering = FILTER_PARAMS.any? { |key| params[key].present? }
        set_activation_hints if @sessions.empty? && !@filtering
      end

      def show
        @errors_count = @session.errors_count
        @error_groups = related_error_groups
      end

      # Eventi rrweb uniti (JSON) per il player standalone. Riusa Replays::Read.
      def player
        result = Replays::Read.call(session: @session)
        if result.err?
          render json: { error: { code: result.error.code, message: result.error.message } }, status: result.error.status
        else
          render json: { data: { events: result.value } }
        end
      end

      private

      # CYRA-376 — la pagina vuota diceva QUANDO compaiono le sessioni, mai COME farle comparire.
      # Servono due elenchi: i progetti che registrano già (dove guardare) e quelli su cui
      # l'interruttore si può davvero accendere — piattaforma web dichiarata E permesso di
      # modificare quel progetto, altrimenti l'invito porterebbe su una porta chiusa. Il filtro
      # `can?` gira in memoria sul solo elenco dei candidati: il resolver è memoizzato per
      # richiesta, quindi nessuna query per progetto.
      def set_activation_hints
        @capable_projects = visible.projects.session_replay_capable.order(:name).to_a
        @collecting_projects = @capable_projects.select(&:session_replay_enabled?)
        @activatable_projects = (@capable_projects - @collecting_projects)
                                .select { |project| can?("projects.edit", scope: project) }
      end

      # Anti-BOLA: sessione non visibile (altra org o progetto non assegnato) → RecordNotFound.
      def set_session
        @session = visible.replay_sessions.find(params[:id])
      end

      # Conteggio errori per sessione in UNA query (no N+1 in lista). Chiave [project_id, replay_session_id]
      # per correttezza cross-progetto (l'id è client-generato, collisioni ~nulle ma scoping esatto).
      def error_counts_for(sessions)
        return {} if sessions.empty?

        Errors::Event
          .where(project_id: sessions.map(&:project_id), replay_session_id: sessions.map(&:replay_session_id))
          .group(:project_id, :replay_session_id).count
      end

      # Gruppi d'errore della sessione (per i link "vai all'errore" nella show), scoped al progetto.
      def related_error_groups
        ids = Errors::Event.where(project_id: @session.project_id, replay_session_id: @session.replay_session_id)
                           .distinct.pluck(:group_id)
        return Errors::Group.none if ids.empty?

        @session.project.error_groups.where(id: ids).recent.limit(20)
      end
    end
  end
end
