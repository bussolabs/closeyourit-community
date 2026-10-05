# frozen_string_literal: true

module Vulnerabilities
  # Un lockfile trovato nel repository del progetto: dove sta, di che ecosistema è, e la firma del
  # contenuto già letto. `content_digest` è il freno al lavoro inutile — un lockfile immutato non si
  # riparsa — ma NON salta il confronto con OSV: gli advisory nuovi escono su versioni ferme da mesi.
  #
  # `parse_error` tiene in vita il manifest anche quando il parse fallisce: sparire in silenzio
  # significherebbe mostrare "nessuna vulnerabilità" per un file che non siamo riusciti a leggere.
  class Manifest < ApplicationRecord
    self.table_name = "vulnerabilities_manifests"

    belongs_to :project, class_name: "Projects::Project", inverse_of: :vulnerability_manifests
    has_many :packages, class_name: "Vulnerabilities::Package", foreign_key: :manifest_id,
             inverse_of: :manifest, dependent: :destroy

    validates :path, presence: true, uniqueness: { scope: :project_id }
    validates :ecosystem, presence: true, inclusion: { in: Vulnerabilities::Ecosystem::ALL }

    scope :ordered, -> { order(:path) }
    scope :parsed, -> { where(parse_error: nil) }
    scope :failing, -> { where.not(parse_error: nil) }

    # Il contenuto è cambiato rispetto all'ultima lettura? Un digest ancora assente conta come
    # cambiato: non abbiamo mai letto questo file.
    def changed_content?(digest) = content_digest.blank? || content_digest != digest

    def display_name = path

    def self.digest_for(content) = Digest::SHA256.hexdigest(content.to_s)
  end
end
