# frozen_string_literal: true

module Connections
  # CELLA della matrice: una funzionalità su una piattaforma. Dice a che punto è (status) e da quale
  # versione è arrivata agli utenti (release). Join con payload, come Connections::ProjectEnvironment.
  #
  # La versione non è testo libero ma un rimando a una release già registrata: così "disponibile
  # dalla 2.1.0" è verificabile e porta con sé sha, data e link al tag. Il prezzo è che su un
  # progetto senza release registrate la versione non si può indicare — per questo release resta
  # opzionale anche sugli stati rilasciati e la matrice segnala il buco invece di bloccarlo.
  class FeaturePlatform < ApplicationRecord
    belongs_to :feature,
               class_name: "Product::Feature",
               inverse_of: :feature_platforms
    belongs_to :platform,
               class_name: "Types::Platform",
               inverse_of: :feature_platforms
    belongs_to :status,
               class_name: "Types::FeatureStatus",
               inverse_of: :feature_platforms
    belongs_to :release,
               class_name: "Projects::Release",
               inverse_of: :feature_platforms,
               optional: true
    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true

    validates :platform_id, uniqueness: { scope: :feature_id }
    validate :platform_matches_feature_organization
    validate :status_matches_feature_organization
    # Solo alla creazione: se l'org disattiva uno stato, le celle già scritte restano valide
    # (disattivare toglie lo stato dalle scelte future, non riscrive la storia).
    validate :status_must_be_active, on: :create
    validate :release_matches_group_and_platform
    validate :release_only_when_released

    # Celle "rilasciate": è lì che ci si aspetta di trovare una versione.
    scope :released, lambda {
      joins(:status).where(types_feature_statuses: { category: %i[available deprecated] })
    }

    # Dato incompleto, non errore: lo stato dice che è nelle mani degli utenti ma non sappiamo da
    # quando. La matrice lo segnala con un marker e lo conta nell'header.
    def release_missing? = status.present? && status.released? && release_id.blank?

    private

    def platform_matches_feature_organization
      feature_org_id = feature&.organization_id
      return if feature_org_id.blank? || platform.blank?

      errors.add(:platform, :invalid) if platform.organization_id != feature_org_id
    end

    def status_matches_feature_organization
      feature_org_id = feature&.organization_id
      return if feature_org_id.blank? || status.blank?

      errors.add(:status, :invalid) if status.organization_id != feature_org_id
    end

    def status_must_be_active
      return if status.blank?

      errors.add(:status, :inactive) unless status.active?
    end

    # "Disponibile dalla 2.1.0" ha senso solo se la funzionalità È nelle mani degli utenti: su uno
    # stato pianificato o in lavorazione una versione sarebbe un obiettivo, non un fatto, e la
    # matrice mostrerebbe "in sviluppo, disponibile dalla 2.1.0". Nel flusso normale non si vede
    # mai: Product::Cells::Set stacca la versione quando lo stato non è rilasciato.
    def release_only_when_released
      return if release_id.blank? || status.blank?

      errors.add(:release, :invalid) unless status.released?
    end

    # La release deve appartenere a un progetto DEL GRUPPO che dichiara QUELLA piattaforma:
    # "disponibile su iOS dalla 2.1.0" ha senso solo se la 2.1.0 è una release di un progetto del
    # prodotto che gira su iOS. Una sola EXISTS, e solo quando una release è stata indicata.
    def release_matches_group_and_platform
      return if release_id.blank? || feature.blank? || platform_id.blank?

      valid = ::Projects::Project
              .where(id: release.project_id, group_id: feature.category&.group_id)
              .where(id: ::Connections::ProjectPlatform.where(platform_id: platform_id).select(:project_id))
              .exists?

      errors.add(:release, :invalid) unless valid
    end
  end
end
