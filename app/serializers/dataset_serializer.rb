# frozen_string_literal: true

# Dataset AI (Datasets::Dataset) per la CLI: metadati + SCHEMA delle colonne, che è ciò che serve per
# scrivere una riga senza dover aprire il sito. `project` è la key umana (quella che si digita da
# terminale), `project_id` l'UUID per chi automatizza.
#
# `rows_count` arriva dal controller in un colpo solo (`params[:rows_counts]`, un conteggio raggruppato
# per dataset): calcolarlo qui riga per riga sarebbe un N+1 su un elenco paginato. Senza params —
# altri contesti — si conta il singolo dataset, che è una query sola.
class DatasetSerializer < ApplicationSerializer
  attributes :id, :project_id, :name, :description, :created_at, :updated_at

  attribute(:status)       { |dataset| dataset.status }
  attribute(:project)      { |dataset| dataset.project.key }
  attribute(:project_name) { |dataset| dataset.project.name }
  attribute(:author)       { |dataset| dataset.created_by&.name }
  attribute(:rows_count)   { |dataset| DatasetSerializer.rows_count(dataset, params) }
  attribute(:columns)      { |dataset| DatasetColumnSerializer.new(dataset.columns.sort_by(&:position)).serializable_hash }

  def self.rows_count(dataset, params)
    counts = params && params[:rows_counts]
    counts ? counts.fetch(dataset.id, 0) : dataset.rows.count
  end
end
