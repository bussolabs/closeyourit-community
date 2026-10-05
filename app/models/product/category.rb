# frozen_string_literal: true

module Product
  # Riga-gruppo della matrice ("Auth", "Notifiche"): raccoglie le funzionalità di un macro-progetto
  # e ne fissa l'ordine. Scoped al gruppo e non all'org: due prodotti hanno la loro "Auth"
  # indipendente. Non è una lookup Types:: perché possiede figli e porta la struttura della matrice,
  # non una classificazione riusabile (rules/rails/lookup-tables.md).
  class Category < ApplicationRecord
    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :feature_categories
    belongs_to :group,
               class_name: "Projects::Group",
               inverse_of: :feature_categories
    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true

    # L'ordine sta sull'associazione e non in uno scope a valle: un `.ordered` dopo l'includes
    # rifarebbe la query annullando il preload (stesso motivo di Knowledge::Page#attachments).
    has_many :features,
             -> { order(:position, :name) },
             class_name: "Product::Feature",
             foreign_key: :category_id,
             inverse_of: :category,
             dependent: :destroy

    normalizes :name, with: ->(name) { name.strip }

    validates :name, presence: true, uniqueness: { scope: :group_id, case_sensitive: false }
    validate :organization_matches_group

    scope :ordered, -> { order(:position, :name) }

    private

    # Integrità tenant: l'org denormalizzata deve combaciare con quella del gruppo che possiede
    # la matrice. Una divergenza renderebbe visibile una categoria fuori dal proprio tenant.
    def organization_matches_group
      group_org_id = group&.organization_id
      return if group_org_id.blank? || organization_id.blank?

      errors.add(:organization, :mismatch) if organization_id != group_org_id
    end
  end
end
