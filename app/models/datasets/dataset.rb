# frozen_string_literal: true

module Datasets
  # Un dataset = uno schema di colonne dinamiche (una delle quali è il result/target) + righe di dati
  # (scalari + foto) su cui si allena un prompt. Radice di tenancy = il progetto: chi vede il progetto
  # vede il dataset (nessun ulteriore RBAC per la lettura).
  class Dataset < ApplicationRecord
    belongs_to :project,
               class_name: "Projects::Project",
               inverse_of: :datasets
    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true

    has_many :columns,
             class_name: "Datasets::Column",
             foreign_key: :dataset_id,
             inverse_of: :dataset,
             dependent: :destroy
    has_many :rows,
             class_name: "Datasets::Row",
             foreign_key: :dataset_id,
             inverse_of: :dataset,
             dependent: :destroy
    has_many :trainings,
             class_name: "Datasets::Training",
             foreign_key: :dataset_id,
             inverse_of: :dataset,
             dependent: :destroy
    has_many :predictions,
             class_name: "Datasets::Prediction",
             foreign_key: :dataset_id,
             inverse_of: :dataset,
             dependent: :destroy

    # Activity-log generalizzato (polimorfico): cronologia create/update del dataset.
    has_many :activity_events,
             class_name: "Activity::Event",
             as: :subject,
             dependent: :destroy

    # Il progetto è radice di tenancy E di visibilità: spostarlo cambierebbe chi lo vede (BOLA).
    attr_readonly :project_id
    delegate :organization_id, to: :project

    normalizes :name, with: ->(name) { name.strip }
    normalizes :description, with: ->(description) { description.to_s.strip }

    validates :name, presence: true

    # `draft` alla creazione, `trained` dopo un training riuscito. (Nessuno stato intermedio: il gap a 1
    # è voluto — un ex `ready` mai usato è stato rimosso; reintrodurlo richiederebbe la transizione.)
    enum :status, { draft: 0, trained: 2 }, prefix: :status

    scope :ordered, -> { order(created_at: :desc) }

    # Colonne Input (dati forniti, es. foto) e Target (attributi da predire), ordinate. Più target ammessi.
    def input_columns = columns.select(&:role_input?).sort_by(&:position)

    def target_columns = columns.select(&:role_target?).sort_by(&:position)
  end
end
