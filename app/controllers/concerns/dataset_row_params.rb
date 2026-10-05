# frozen_string_literal: true

# Lettura dei parametri di una riga di dataset dal canale CLI: `values[<codice colonna>]` per i valori
# scalari, `photos[<codice colonna>]` multipart per le immagini — la stessa forma del form del sito.
# Condiviso fra le righe (Cli::V1::Datasets::RowsController) e le previsioni
# (Cli::V1::Datasets::PredictionsController), che scrivono la stessa cosa: una riga del dataset.
module DatasetRowParams
  extend ActiveSupport::Concern

  private

  # `values` e `photos` sono mappe. Un client che manda `values=colore=rosso` consegna una String:
  # senza questo controllo finirebbe in un errore del server, invece del rifiuto leggibile che il
  # chiamante sa gestire. Rende l'errore e ritorna false (usabile con `return unless shaped?`).
  def shaped?
    return true if %i[values photos].all? { |key| !params.key?(key) || mapping?(params[key]) }

    render_error("R422-DATASET-003", I18n.t("datasets.errors.row_invalid"),
                 status: :unprocessable_content, details: { values: [ :invalid ] })
    false
  end

  def hash_param(key)
    raw = params[key]
    return {} unless mapping?(raw)

    (raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw).transform_keys(&:to_s)
  end

  # Una mappa, non "qualcosa che sa diventare un hash": un Array risponde a `to_h` e poi esplode sui
  # suoi elementi.
  def mapping?(value) = value.is_a?(ActionController::Parameters) || value.is_a?(Hash)
end
