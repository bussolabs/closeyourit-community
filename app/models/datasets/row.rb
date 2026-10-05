# frozen_string_literal: true

module Datasets
  # Una riga di dati del dataset. I valori delle celle SCALARI (incluso il result per le righe sample)
  # stanno in `cell_values` (jsonb keyed per column code); le celle foto sono record Datasets::Cell.
  # `purpose` distingue le righe di training (sample) dall'input di inferenza (prediction).
  class Row < ApplicationRecord
    belongs_to :dataset,
               class_name: "Datasets::Dataset",
               inverse_of: :rows

    has_many :cells,
             class_name: "Datasets::Cell",
             foreign_key: :row_id,
             inverse_of: :row,
             dependent: :destroy

    enum :purpose, { sample: 0, prediction: 1 }, prefix: :purpose

    scope :ordered, -> { order(:position, :created_at) }

    # Valore scalare per column code (nil se assente). cell_values è sempre un Hash (default {}).
    def value_for(code) = (cell_values || {}).fetch(code.to_s, nil)
  end
end
