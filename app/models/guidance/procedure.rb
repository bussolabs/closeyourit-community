# frozen_string_literal: true

module Guidance
  # Procedura testuale (`content`) applicabile al lavoro sul progetto, dichiarata a un livello della
  # gerarchia. A differenza della reference si può COMPORRE lungo i livelli:
  # - application_mode: `inherit` partecipa alla catena (nearest-wins o accumulo, vedi merge_strategy),
  #   `replace` taglia netto la catena e vince da solo, `disable` sopprime la key ereditata;
  # - merge_strategy (attivo solo con `inherit`): `override` usa il content del livello più vicino,
  #   `append` accoda il content del livello più vicino a quello ereditato.
  # La composizione è tutta in Guidance::Resolve; qui vivono solo forma e integrità tenant. Un
  # `enabled: false` equivale a `disable` (sopprime la key).
  class Procedure < ApplicationRecord
    # 0 inherit · 1 replace · 2 disable — vedi commento di classe per la semantica in risoluzione.
    enum :application_mode, { inherit: 0, replace: 1, disable: 2 }, prefix: :application
    # 0 override · 1 append — come si combina il content quando application_mode è inherit.
    enum :merge_strategy, { override: 0, append: 1 }, prefix: :merge

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :owner, polymorphic: true
    belongs_to :created_by, class_name: "Accounts::Account", optional: true

    normalizes :key, with: ->(key) { key.to_s.strip.downcase }
    normalizes :content, with: ->(value) { value.to_s.strip }

    validates :owner_type, inclusion: { in: Guidance::OWNER_TYPES }
    validates :content, presence: true
    validates :key, presence: true, format: { with: Guidance::KEY_FORMAT },
                    uniqueness: { scope: %i[owner_type owner_id] }
    validate :organization_matches_owner

    # Ordine deterministico dello slot nel risultato risolto: position poi key, tie-break id.
    scope :ordered, -> { order(:position, :key, :id) }

    private

    # Integrità tenant (anti-BOLA): la procedura porta la stessa org del proprio owner. Vedi
    # Guidance::Reference#organization_matches_owner per il case sui tre tipi di owner.
    def organization_matches_owner
      return if owner.blank? || organization_id.blank?

      errors.add(:organization, :mismatch) if owner_organization_id != organization_id
    end

    def owner_organization_id
      case owner
      when Organizations::Organization then owner.id
      else owner.try(:organization_id)
      end
    end
  end
end
