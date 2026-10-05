# frozen_string_literal: true

# Previsione di un dataset (Datasets::Prediction) per la CLI: gli stessi campi che la pagina mostra —
# stato, valori predetti per ogni attributo target, dati in ingresso, motivo del fallimento.
#
# `input_row` è la riga così com'è nell'elenco delle righe (stessi `values`, stessi metadati delle
# foto): chi legge una previsione vede l'ingresso nella forma con cui l'ha scritto, e la foto la
# scarica dall'endpoint delle righe. Finché non è finita, `predicted_values` è {} — non un valore
# vuoto per ogni target, che sembrerebbe una risposta.
class DatasetPredictionSerializer < ApplicationSerializer
  attributes :id, :dataset_id, :training_id, :input_row_id, :error_code, :error_message,
             :created_at, :updated_at

  attribute(:status)           { |prediction| prediction.status }
  attribute(:predicted_values) { |prediction| prediction.predicted_values || {} }
  attribute(:author)           { |prediction| prediction.created_by&.name }
  attribute(:input_row)        { |prediction| DatasetRowSerializer.new(prediction.input_row).serializable_hash }
end
