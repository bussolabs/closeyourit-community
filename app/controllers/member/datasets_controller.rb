# frozen_string_literal: true

module Member
  # Dataset AI (sezione AI): colonne dinamiche + foto + colonna result → prompt ottimizzato per
  # predire il result. Lettura = visibilità del progetto (anti-BOLA via visible.datasets);
  # creazione/modifica/eliminazione gated `datasets.manage` sullo scope del progetto. Controller flat
  # (non Member::Datasets::*) per non ombreggiare il namespace ::Datasets (model). Le sub-risorse
  # (righe/training/predizioni) vivono in Member::Datasets::* nelle fasi successive.
  class DatasetsController < Member::BaseController
    before_action :set_dataset, only: %i[show edit update destroy]
    before_action :require_dataset_management, only: %i[edit update destroy]

    # CYRA-924 — every column sorts (C9).
    SORT_COLUMNS = {
      "name" => "LOWER(datasets_datasets.name)",
      "project" => "(SELECT LOWER(projects.name) FROM projects WHERE projects.id = datasets_datasets.project_id)",
      "columns" => "(SELECT COUNT(*) FROM datasets_columns WHERE datasets_columns.dataset_id = datasets_datasets.id)",
      "status" => :status,
      "created" => :created_at
    }.freeze

    def index
      @status_counts = visible.datasets.group(:status).count
      @pagination = paginate(sorted(filtered_datasets, columns: SORT_COLUMNS))
      @datasets = @pagination.records
      @can_create = can_any?("datasets.manage")
    end

    def show
      @columns = @dataset.columns.ordered.to_a
      @input_columns = @columns.select(&:role_input?)
      @target_columns = @columns.select(&:role_target?)
      # Colonne mostrate nella griglia righe: input poi target (gli attributi da predire in coda).
      @display_columns = @input_columns + @target_columns
      # CYRA-684 — i campioni crescono senza limite: griglia a pagine, conteggio dal totale.
      @rows_pagination = paginate(@dataset.rows.purpose_sample.ordered
                                          .includes(cells: { image_attachment: :blob }))
      @rows = @rows_pagination.records
      @rows_count = @rows_pagination.total
      @trainings = @dataset.trainings.ordered.to_a
      @has_trained = @trainings.any?(&:status_done?)
      @predictions = @dataset.predictions.ordered.includes(:training).limit(10).to_a
      @can_manage = can?("datasets.manage", scope: @dataset.project)
      @can_train = can?("datasets.train", scope: @dataset.project)
      # Activity-log generalizzato: blocco Audit (ultimo evento) + cronologia nel modale.
      @activity_events = @dataset.activity_events.chronological.includes(:actor, :true_actor).to_a
      @last_activity = @activity_events.last
    end

    def new
      @dataset = ::Datasets::Dataset.new
      @projects = manageable_projects
    end

    def create
      project = visible.projects.find_by(id: params.dig(:dataset, :project_id))
      return redirect_to(new_member_dataset_path, alert: t("datasets.errors.project_not_found")) if project.nil?
      return redirect_to(root_path, alert: t("member.forbidden")) unless can?("datasets.manage", scope: project)

      result = ::Datasets::Save.call(organization: Current.organization, actor: Current.account,
                                     true_actor: Current.true_account, params: save_params(project))
      if result.ok?
        redirect_to member_dataset_path(result.value), notice: t("member.datasets.created")
      else
        rerender_new(result)
      end
    end

    def edit
      @locked_columns = @dataset.rows.exists?
      @columns = @dataset.columns.ordered.to_a
    end

    def update
      result = ::Datasets::Save.call(organization: Current.organization, actor: Current.account,
                                     true_actor: Current.true_account, dataset: @dataset,
                                     params: save_params(@dataset.project))
      if result.ok?
        redirect_to member_dataset_path(@dataset), notice: t("member.datasets.updated")
      else
        @locked_columns = @dataset.rows.exists?
        @columns = @dataset.columns.ordered.to_a
        @errors = result.error.details || {}
        flash.now[:alert] = result.error.message
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      @dataset.destroy
      redirect_to member_datasets_path, notice: t("member.datasets.deleted")
    end

    private

    # Anti-BOLA: dataset di un progetto non visibile → RecordNotFound (404, mai 403).
    def set_dataset
      @dataset = visible.datasets.includes(:project, :columns).find(params[:id])
    end

    def filtered_datasets
      scope = visible.datasets.includes(:project, :columns).ordered
      scope = scope.where("datasets_datasets.name ILIKE ?", "%#{search_q}%") if search_q.present?
      scope = scope.where(project_id: filter_ids(:project_id)) if filter_ids(:project_id).any?
      scope = scope.where(status: filter_ids(:status)) if filter_ids(:status).any?
      scope
    end

    # Progetti su cui l'utente può creare dataset (per le option del form).
    def manageable_projects
      visible.projects.order(:name).select { |project| can?("datasets.manage", scope: project) }
    end

    def save_params(project)
      {
        project_id: project.id,
        name: params.dig(:dataset, :name),
        description: params.dig(:dataset, :description),
        columns: columns_param
      }
    end

    # Il form invia le colonne con nomi indicizzati (columns[N][...]) → params[:columns] è un hash keyed
    # per indice; normalizziamo a lista di hash a chiavi simbolo (robusto a righe rimosse/riordino).
    # Ogni colonna porta il suo `role` (input/target).
    def columns_param
      raw = params[:columns]
      list = raw.respond_to?(:values) ? raw.values : Array(raw)
      list.map do |column|
        attrs = (column.respond_to?(:to_unsafe_h) ? column.to_unsafe_h : column).symbolize_keys
        { label: attrs[:label], kind: attrs[:kind], role: attrs[:role], options: attrs[:options], required: attrs[:required] }
      end
    end

    def rerender_new(result)
      @dataset = ::Datasets::Dataset.new(name: params.dig(:dataset, :name),
                                         description: params.dig(:dataset, :description))
      @projects = manageable_projects
      @errors = result.error.details || {}
      flash.now[:alert] = result.error.message
      render :new, status: :unprocessable_content
    end

    def require_dataset_management
      require_permission!("datasets.manage", scope: @dataset.project)
    end
  end
end
