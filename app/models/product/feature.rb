# frozen_string_literal: true

module Product
  # Riga della matrice ("2FA", "Apple login"): una funzionalità del prodotto. La disponibilità sulle
  # singole piattaforme sta nelle celle (Connections::FeaturePlatform), qui c'è solo la funzionalità
  # in sé più il rimando opzionale alla pagina della base di conoscenza che la spiega.
  class Feature < ApplicationRecord
    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :features
    belongs_to :category,
               class_name: "Product::Category",
               inverse_of: :features
    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true
    # Link alla KB a livello di funzionalità, non di cella: la pagina spiega cosa fa la
    # funzionalità, non com'è stata implementata su una singola piattaforma.
    belongs_to :knowledge_page,
               class_name: "Knowledge::Page",
               inverse_of: :features,
               optional: true

    has_many :feature_platforms,
             class_name: "Connections::FeaturePlatform",
             foreign_key: :feature_id,
             inverse_of: :feature,
             dependent: :destroy
    has_many :platforms, through: :feature_platforms, source: :platform

    normalizes :name, with: ->(name) { name.strip }

    validates :name, presence: true, uniqueness: { scope: :category_id, case_sensitive: false }
    validate :organization_matches_category
    validate :knowledge_page_matches_organization

    scope :ordered, -> { order(:position, :name) }

    delegate :group, :group_id, to: :category

    private

    def organization_matches_category
      category_org_id = category&.organization_id
      return if category_org_id.blank? || organization_id.blank?

      errors.add(:organization, :mismatch) if organization_id != category_org_id
    end

    # Anti-BOLA di secondo livello: il controller risolve già la pagina dentro lo scope visibile,
    # qui si blocca comunque un id di un altro tenant arrivato per altre vie.
    def knowledge_page_matches_organization
      return if knowledge_page.blank? || organization_id.blank?

      errors.add(:knowledge_page, :invalid) if knowledge_page.organization_id != organization_id
    end
  end
end
