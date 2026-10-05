# frozen_string_literal: true

module Agents
  # Riferimento al bundle skill versionato (repo `closeyourit-skills`) pinnato per un'organizzazione (B.2).
  # Un solo record per org (singleton): è la versione autoritativa che l'Agent Host clona ed esegue in skill-mode
  # (`claude --plugin-dir <clone>`). `version` è il nome directory del plugin (contratto client), `digest` è lo
  # SHA del commit atteso (verifica content-addressed dopo il clone). Additivo: non tocca Command/Instruction.
  class SkillBundle < ApplicationRecord
    belongs_to :organization, class_name: "Organizations::Organization", inverse_of: :skill_bundle

    normalizes :repo, :ref, :version, with: ->(value) { value.to_s.strip }
    normalizes :digest, with: ->(value) { value.to_s.strip.downcase }

    validates :repo, presence: true, format: { with: %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z} }
    validates :ref, presence: true
    # `version` finisce come segmento di path nel clone (`--plugin-dir <clone>/<version>`): niente separatori/traversal.
    validates :version, presence: true, format: { with: %r{\A[^/\s]+\z} }
    validate :version_without_traversal
    validates :digest, presence: true, format: { with: /\A[0-9a-f]{7,64}\z/ }
    validates :organization_id, uniqueness: true

    private

    def version_without_traversal
      errors.add(:version, :invalid) if version.to_s.include?("..")
    end
  end
end
