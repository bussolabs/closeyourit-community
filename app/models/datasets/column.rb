# frozen_string_literal: true

module Datasets
  # Definizione di una colonna del dataset, creata dall'utente alla creazione. `kind` è il tipo
  # (incl. photo, consumata dall'AI in multimodale); `role` distingue gli Input (dati forniti, es. la
  # foto) dai Target (attributi da predire). Più target ammessi (multi-attributo). Per kind=category,
  # `options` è lo spazio dei valori ammessi (output space del prompt per i target categoriali).
  class Column < ApplicationRecord
    belongs_to :dataset,
               class_name: "Datasets::Dataset",
               inverse_of: :columns

    has_many :cells,
             class_name: "Datasets::Cell",
             foreign_key: :column_id,
             inverse_of: :column,
             dependent: :destroy

    normalizes :code, with: ->(code) { code.to_s.strip.downcase.gsub(/\s+/, "_") }
    normalizes :label, with: ->(label) { label.strip }

    enum :kind, { text: 0, number: 1, category: 2, boolean: 3, photo: 4 }, prefix: :kind
    enum :role, { input: 0, target: 1 }, prefix: :role

    validates :code, presence: true,
              format: { with: /\A[a-z][a-z0-9_]*\z/ },
              uniqueness: { scope: :dataset_id }
    validates :label, presence: true
    validate :photo_cannot_be_target
    validate :category_needs_options

    scope :ordered, -> { order(:position, :label) }

    # options è un array di stringhe (spazio valori per kind=category e per i target categoriali).
    def option_values = Array(options).map(&:to_s).map(&:strip).reject(&:blank?)

    private

    # Una foto è sempre un input: si predicono valori scalari, non immagini.
    def photo_cannot_be_target
      errors.add(:role, :invalid) if kind_photo? && role_target?
    end

    def category_needs_options
      return unless kind_category?

      errors.add(:options, :blank) if option_values.empty?
    end
  end
end
