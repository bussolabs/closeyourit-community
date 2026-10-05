# frozen_string_literal: true

module Datasets
  # Crea o aggiorna un dataset con le sue colonne. Ogni colonna ha ruolo Input (dato fornito, es. la
  # foto) o Target (attributo da predire). Un dataset ha ≥1 input e ≥1 target (multi-attributo). In
  # creazione il progetto è risolto via VisibleScope (anti-BOLA, come Ideas::CreateIdea). In modifica il
  # progetto è immutabile e le colonne sono rieditabili SOLO finché il dataset non ha righe (cambiare lo
  # schema con dati dentro li invaliderebbe). Result pattern, tutto in transazione.
  class Save < ApplicationService
    # Tipi ammessi per una colonna: le foto sono sempre input (l'AI predice valori scalari, non immagini).
    def initialize(organization:, actor:, params:, dataset: nil, true_actor: nil)
      @organization = organization
      @actor = actor
      @params = params
      @dataset = dataset
      @true_actor = true_actor
    end

    def call
      @dataset ? update : create
    end

    private

    def create
      project = visible_projects.find_by(id: @params[:project_id])
      return err_project if project.nil?

      dataset = project.datasets.new(name: @params[:name], description: @params[:description], created_by: @actor)
      persist(dataset, columns_spec)
    end

    def update
      @dataset.assign_attributes(name: @params[:name], description: @params[:description])
      # Colonne rieditabili solo su dataset senza righe: altrimenti si salva solo nome/descrizione.
      # `columns` ASSENTE dai params è diverso da lista vuota: il form web le manda sempre, un PATCH
      # da terminale che rinomina soltanto non deve portarsi via lo schema (CYRA-646).
      spec = @params.key?(:columns) && !@dataset.rows.exists? ? columns_spec : nil
      persist(@dataset, spec)
    end

    def persist(dataset, spec)
      schema_error = spec && validate_schema(spec)
      return schema_err(schema_error) if schema_error

      was_new = dataset.new_record?
      ActiveRecord::Base.transaction do
        dataset.save!
        replace_columns(dataset, spec) unless spec.nil?
        record_activity(dataset, was_new)
      end
      Result.ok(dataset)
    rescue ActiveRecord::RecordInvalid => e
      Result.err(AppError.new(I18n.t("datasets.errors.invalid"),
                              code: "R422-DATASET-001", details: e.record.errors.to_hash))
    end

    # 'updated' solo se sono cambiate colonne PROPRIE del dataset (niente evento su solo cambio
    # schema colonne: replace_columns non tocca colonne del dataset → saved_changes vuoto).
    def record_activity(dataset, was_new)
      if was_new
        Activity::Record.call(subject: dataset, action: "created", actor: @actor, true_actor: @true_actor)
      else
        changed = dataset.saved_changes.keys - %w[updated_at created_at]
        return if changed.empty?

        Activity::Record.call(subject: dataset, action: "updated", data: { fields: changed },
                              actor: @actor, true_actor: @true_actor)
      end
    end

    def replace_columns(dataset, spec)
      # `includes(:cells)` perché destroy_all cerca le celle di OGNI colonna: senza, sono N query
      # identiche in fila (Prosopite le ferma, ed è giusto — è lo stesso schema riscritto N volte).
      dataset.columns.includes(:cells).destroy_all
      spec.each_with_index { |attrs, index| dataset.columns.create!(attrs.merge(position: index)) }
    end

    # Normalizza i params grezzi del form (lista colonne, ognuna con role) in attributi di colonna.
    def columns_spec
      Array(@params[:columns]).map { |column| column_attributes(column) }
    end

    def column_attributes(column)
      kind = Datasets::Column.kinds.key?(column[:kind].to_s) ? column[:kind].to_sym : :text
      {
        code: derive_code(column[:code], column[:label]),
        label: column[:label].to_s,
        kind: kind,
        role: role_for(column[:role], kind),
        required: ActiveModel::Type::Boolean.new.cast(column[:required]) || false,
        options: split_options(column[:options])
      }
    end

    # Una foto è sempre input (photo≠target). Altrimenti input/target dal form, default input.
    def role_for(role, kind)
      return :input if kind == :photo

      %w[input target].include?(role.to_s) ? role.to_sym : :input
    end

    # ≥1 input e ≥1 target, valutato prima di toccare il DB (schema del dataset).
    def validate_schema(spec)
      roles = spec.map { |column| column[:role].to_s }
      return :no_input unless roles.include?("input")

      :no_target unless roles.include?("target")
    end

    def schema_err(key)
      Result.err(AppError.new(I18n.t("datasets.errors.#{key}"), code: "R422-DATASET-001"))
    end

    # Code esplicito se fornito, altrimenti derivato dalla label (il model normalizza + valida il formato).
    def derive_code(code, label)
      return code if code.present?

      label.to_s.parameterize(separator: "_")
    end

    # options del form = stringa separata da virgole → array di valori (usato per kind=category).
    def split_options(raw)
      return raw if raw.is_a?(Array)

      raw.to_s.split(",").map(&:strip).reject(&:blank?)
    end

    def visible_projects
      Authorization::VisibleScope.new(account: @actor, organization: @organization).projects
    end

    def err_project
      Result.err(AppError.new(I18n.t("datasets.errors.project_not_found"), code: "R404-DATASET-001", status: :not_found))
    end
  end
end
