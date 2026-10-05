# frozen_string_literal: true

module Cli
  module V1
    # Dataset AI via CLI (CYRA-646): stesso elenco, stessa ricerca e stessi filtri della sezione AI
    # del sito — se le due risposte divergessero, chi automatizza si troverebbe una raccolta diversa
    # da quella che ha davanti a video. La logica sta nel service condiviso ::Datasets::Save (schema
    # ≥1 input e ≥1 target, colonne rieditabili solo finché il dataset è vuoto, cronologia), qui solo
    # auth, gate e serializzazione.
    #
    # Contratto delle colonne (l'aperto della lavorazione): `columns` è una LISTA di oggetti, uno per
    # colonna, con `label` (obbligatoria), `kind`, `role`, `required` e `options`; il `code` — la
    # chiave con cui poi si scrivono i valori — si può dichiarare o lasciar derivare dalla label,
    # esattamente come fa il form del sito. `options` accetta sia la lista sia il testo separato da
    # virgole, che è la forma comoda da terminale.
    #
    # Controller FLAT (non Cli::V1::Datasets::*) per non ombreggiare il namespace ::Datasets dei
    # model, come Member::DatasetsController. Lettura (elenco, scheda) = visibilità del progetto;
    # creare, modificare ed eliminare = `datasets.manage` sul progetto. Anti-BOLA: il dataset si
    # cerca dentro visible_datasets (progetto non visibile → R404 prima del gate, mai 403).
    class DatasetsController < Cli::V1::BaseController
      before_action :set_dataset, only: %i[show update destroy]
      before_action -> { require_permission!("datasets.manage", scope: @dataset.project) },
                    only: %i[update destroy]

      def index
        project = filter_project
        return render_project_not_found if project == :not_found

        scope = filtered_datasets(project)
        records, meta = paginate(scope)
        render_ok(DatasetSerializer.new(records, params: { rows_counts: rows_counts(records) }), meta: meta)
      end

      def show
        render_ok(serialize(@dataset))
      end

      # Il progetto si nomina con la sua key ("ACME") o con l'UUID, sotto `project` o `project_id`:
      # da terminale si digita la key, un programma ha in mano l'UUID.
      def create
        project = resolve_project(params[:project].presence || params[:project_id])
        return render_project_not_found if project.nil?
        # Il gate risponde e ritorna false: senza questa uscita il dataset nascerebbe comunque, e la
        # risposta di divieto arriverebbe con la riga già scritta.
        return unless require_permission!("datasets.manage", scope: project)

        result = ::Datasets::Save.call(organization: Current.organization, actor: Current.account,
                                       true_actor: Current.account,
                                       params: dataset_params.merge(project_id: project.id))
        return render_dataset_error(result) unless result.ok?

        render_created(serialize(result.value))
      end

      # Modifica PARZIALE: si toccano solo i campi presenti. Mandare tutto sempre (come fa il form
      # web, che ha i campi sotto gli occhi) qui azzererebbe la descrizione a chi rinomina soltanto —
      # e, peggio, riscriverebbe lo schema delle colonne a chi non l'ha nominato.
      def update
        result = ::Datasets::Save.call(organization: Current.organization, actor: Current.account,
                                       true_actor: Current.account, dataset: @dataset,
                                       params: dataset_params(@dataset))
        return render_dataset_error(result) unless result.ok?

        render_ok(serialize(@dataset.reload))
      end

      def destroy
        @dataset.destroy
        render_no_content
      end

      private

      def set_dataset
        @dataset = visible_datasets.includes(:project, :columns).find(params[:id])
      end

      def visible_datasets
        ::Datasets::Dataset.where(project_id: visible_projects.select(:id))
      end

      def serialize(dataset)
        DatasetSerializer.new(dataset, params: { rows_counts: rows_counts([ dataset ]) })
      end

      # Un conteggio raggruppato per tutti i dataset serializzati: una query sola invece di una per
      # riga (Prosopite fermerebbe giustamente la seconda forma).
      def rows_counts(records)
        ::Datasets::Row.where(dataset_id: records.map(&:id)).group(:dataset_id).count
      end

      def filtered_datasets(project)
        scope = visible_datasets.includes(:project, :columns, :created_by).ordered
        scope = scope.where(project_id: project.id) if project
        scope = scope.where("datasets_datasets.name ILIKE ?", "%#{params[:q].to_s.strip}%") if params[:q].present?
        scope = scope.where(status: status_filter) if status_filter.any?
        scope
      end

      def status_filter
        @status_filter ||= Array(params[:status]).reject(&:blank?) & ::Datasets::Dataset.statuses.keys
      end

      # nil = nessun filtro; :not_found = filtro su un progetto che il token non vede (anti-BOLA: la
      # risposta è la stessa che darebbe un progetto inesistente).
      def filter_project
        return nil if params[:project].blank?

        resolve_project(params[:project]) || :not_found
      end

      def resolve_project(ref)
        ref = ref.to_s.strip
        return nil if ref.blank?

        visible_projects.find_by(key: ref.upcase) || visible_projects.find_by(id: ref)
      end

      # Solo le chiavi PRESENTI: senza il dataset (create) i campi valgono quello che arriva; con il
      # dataset (update) quello che manca resta com'era. `columns` entra solo se nominata — la sua
      # assenza vuol dire "non toccare lo schema", che ::Datasets::Save distingue da una lista vuota.
      def dataset_params(dataset = nil)
        attributes = {}
        attributes[:name] = field(:name, dataset&.name)
        attributes[:description] = field(:description, dataset&.description)
        attributes[:columns] = columns_param if params.key?(:columns)
        attributes
      end

      def field(key, current)
        params.key?(key) ? params[key].to_s : current
      end

      # Le colonne arrivano come lista di oggetti (JSON) o come mappa indicizzata (multipart), come
      # nel form del sito: normalizziamo a lista di hash a chiavi simbolo.
      def columns_param
        raw = params[:columns]
        list = raw.respond_to?(:values) && !raw.is_a?(Array) ? raw.values : Array(raw)
        list.map { |column| column_attributes(column) }
      end

      def column_attributes(column)
        attrs = (column.respond_to?(:to_unsafe_h) ? column.to_unsafe_h : column).symbolize_keys
        { label: attrs[:label], code: attrs[:code], kind: attrs[:kind], role: attrs[:role],
          options: attrs[:options], required: attrs[:required] }
      end

      def render_project_not_found
        render_error("R404-DATASET-001", I18n.t("datasets.errors.project_not_found"), status: :not_found)
      end

      def render_dataset_error(result)
        render_error(result.error.code, result.error.message,
                     status: result.error.status, details: result.error.details)
      end
    end
  end
end
