# frozen_string_literal: true

# Addestramento di un dataset (Datasets::Training) per la CLI: gli stessi campi che la pagina mostra —
# stato, accuratezza complessiva, accuratezza per attributo da predire, prompt ottimizzato, motivo del
# fallimento — così chi segue l'avanzamento da terminale legge quello che leggerebbe a video.
#
# `accuracy` e `per_target` arrivano GREZZI (0..1): la pagina li rende in percentuale, un programma li
# vuole com'è stato misurato. Finché l'addestramento non è finito valgono nil e {}: un'accuratezza a
# zero direbbe "misurato male", non "non ancora misurato".
class DatasetTrainingSerializer < ApplicationSerializer
  attributes :id, :dataset_id, :error_code, :error_message, :created_at, :updated_at

  attribute(:status)        { |training| training.status }
  attribute(:accuracy)      { |training| training.metrics&.dig("overall_accuracy") }
  attribute(:per_target)    { |training| training.metrics&.dig("per_target") || {} }
  attribute(:system_prompt) { |training| training.system_prompt }
  attribute(:author)        { |training| training.created_by&.name }
end
