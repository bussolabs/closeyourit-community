# frozen_string_literal: true

module Cli
  module V1
    # Progetti del token (VisibleScope). Lettura: la visibilità È il gate (show fuori scope → R404, anti-BOLA).
    # Mutazioni gated per-azione: create (`projects.create`, org-level), update (`projects.edit`, scope progetto),
    # destroy (`projects.delete`, scope progetto). La logica di dominio vive in `Projects::Save`, condivisa col
    # canale Member (`rules/backend-channels.md`): qui solo auth/gate/serializzazione del canale CLI.
    class ProjectsController < Cli::V1::BaseController
      before_action :set_project!, only: %i[show update destroy]

      def index
        # with_attached_icon_image: il serializer legge icon_image.attached? per progetto → preload per
        # evitare un active_storage_attachments per riga (prosopite N+1).
        records, meta = paginate(visible_projects.with_attached_icon_image.order(:name))
        render_ok(ProjectSerializer.new(records), meta: meta)
      end

      # Mappa aggregata progetto CloseYourIt → repository GitHub per orchestratori multi-repo.
      # La visibilita dei progetti e il gate di lettura; includes evita una query repository per riga.
      def github_map
        scope = visible_projects.includes(:github_repository).order(:name)
        scope = scope.where.associated(:github_repository) if ActiveModel::Type::Boolean.new.cast(params[:connected_only])
        records, meta = paginate(scope)
        render_ok(GithubProjectMappingSerializer.new(records), meta: meta)
      end

      def show
        render_ok(ProjectSerializer.new(@project))
      end

      def create
        return unless require_permission!("projects.create")
        return render_group_not_found if group_requested? && resolved_group.nil?

        save(Current.organization.projects.new, attributes: create_params,
                                                group_id: resolved_group&.id, status: :created)
      end

      def update
        return unless require_permission!("projects.edit", scope: @project)
        return render_group_not_found if group_requested? && resolved_group.nil?

        # group passato → riassegna; non passato → non toccare (sentinel UNSET di Projects::Save).
        dimensions = group_requested? ? { group_id: resolved_group.id } : {}
        save(@project, attributes: update_params, **dimensions)
      end

      def destroy
        return unless require_permission!("projects.delete", scope: @project)

        ::Projects::Destroy.call(project: @project)
        render_no_content
      end

      private

      def save(project, attributes:, status: :ok, **dimensions)
        result = ::Projects::Save.call(
          project:, organization: Current.organization, attributes:, actor: Current.account, **dimensions
        )
        if result.ok?
          status == :created ? render_created(ProjectSerializer.new(project)) : render_ok(ProjectSerializer.new(project))
        else
          render_error(result.error.code, result.error.message, status: result.error.status, details: result.error.details)
        end
      end

      # Create e update: solo i campi passati. La key è SEMPRE esplicita (≤4 char) — la valida il model.
      # quick_bug_report_enabled/secret_approval_enabled sono i flag di funzionalità impostabili anche in
      # creazione (specchio del form progetto Member); la retention per-progetto vive nell'endpoint settings.
      def create_params
        params.permit(:name, :key, :color, :description, :icon, :quick_bug_report_enabled,
                      :secret_approval_enabled)
      end

      def update_params
        params.permit(:name, :key, :color, :description, :icon, :quick_bug_report_enabled,
                      :secret_approval_enabled)
      end

      def group_requested?
        params[:group_id].present? || params[:group_name].present?
      end

      # Gruppo entro l'org del token: per id (uuid) o per name. Fuori org / inesistente → nil → R422.
      def resolved_group
        @resolved_group ||=
          if params[:group_id].present?
            Current.organization.groups.find_by(id: params[:group_id])
          elsif params[:group_name].present?
            Current.organization.groups.find_by(name: params[:group_name])
          end
      # simplecov:disable Rails 8 castcasta un uuid malformato a nil → find_by(id:) NON solleva (ritorna nil, gestito
      # dal ramo normale); questo rescue è difesa per driver/input che sollevano, non raggiungibile qui.
      rescue ActiveRecord::StatementInvalid
        nil # group_id non-uuid → trattato come non trovato (R422)
      end
      # simplecov:enable

      def render_group_not_found
        render_error("R422-PROJECT-002", "Gruppo non trovato nell'organizzazione", status: :unprocessable_content)
      end
    end
  end
end
