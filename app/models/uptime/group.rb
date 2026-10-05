# frozen_string_literal: true

module Uptime
  # Gruppo di monitor uptime: contenitore ORG-LEVEL (non per-progetto) che aggrega monitor anche di
  # progetti diversi in una status page unica. Gemello di Projects::Group ma sui monitor uptime.
  # Cancellazione: i monitor sopravvivono e diventano "senza gruppo" (dependent: :nullify).
  # `slug` = identificatore leggibile stabile per la status page pubblica (/status/g/:org/:slug),
  # generato dal nome alla creazione e NON riscritto al rename (URL pubblico stabile).
  class Group < ApplicationRecord
    self.table_name = "uptime_groups"

    include Iconable

    belongs_to :organization, class_name: "Organizations::Organization", inverse_of: :uptime_groups
    belongs_to :created_by, class_name: "Accounts::Account", optional: true

    has_many :monitors, class_name: "Uptime::Monitor", foreign_key: :group_id,
             inverse_of: :group, dependent: :nullify

    normalizes :name, with: ->(value) { value.strip }

    before_validation :ensure_slug

    validates :name, presence: true
    validates :slug, presence: true, uniqueness: { scope: :organization_id }

    scope :ordered, -> { order(:name) }
    # Gruppi con status page pubblica attiva (opt-in). Usato dal canale web pubblico (Website::).
    scope :public_status, -> { where(public_status_enabled: true) }

    # Status page pubblica del gruppo attiva? (gate del canale Website::). Opt-in, default false.
    def public? = public_status_enabled?

    private

    # Slug stabile derivato dal nome, unico per organizzazione. Generato SOLO se assente (create):
    # al rename lo slug NON cambia → l'URL pubblico resta stabile. Auto-suffisso -2/-3 su collisione.
    def ensure_slug
      return if slug.present?

      base = name.to_s.parameterize.presence || "group"
      candidate = base
      n = 2
      while organization_id && Uptime::Group.where(organization_id: organization_id)
                                            .where.not(id: id).exists?(slug: candidate)
        candidate = "#{base}-#{n}"
        n += 1
      end
      self.slug = candidate
    end
  end
end
