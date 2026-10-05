# frozen_string_literal: true

module Agents
  # CYRA-621 — il numero di versione assegnato dal SERVER a una lavorazione, prima che il rilascio
  # parta. La macchina lo riceve e lo usa: non lo sceglie più.
  #
  # Il numero non è un'etichetta qualsiasi. È il nome con cui una versione viene chiamata per sempre:
  # nei messaggi di errore, nelle segnalazioni di chi usa il prodotto, nella cronologia delle novità,
  # nel confronto «questo problema c'era già prima o è arrivato con l'ultimo rilascio».
  class ReleaseAssignment < ApplicationRecord
    self.table_name = "agents_release_assignments"

    PHASES = %w[closer_staging closer_production].freeze

    belongs_to :workflow, class_name: "Agents::Workflow"
    belongs_to :github_repository, class_name: "Github::Repository"

    validates :execution_phase, inclusion: { in: PHASES }
    validates :version, presence: true
    # Il punto esatto di codice da pubblicare, e vale solo per la versione definitiva: sulla prova non
    # c'è ancora niente di atterrato da nominare. Quaranta esadecimali minuscoli — un abbreviato non
    # identifica niente e passerebbe.
    validates :sha, format: { with: /\A[0-9a-f]{40}\z/ }, allow_nil: true

    scope :for_phase, ->(phase) { where(execution_phase: phase) }
  end
end
