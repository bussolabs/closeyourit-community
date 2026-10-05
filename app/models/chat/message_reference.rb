# frozen_string_literal: true

module Chat
  # Risorsa taggata in un messaggio (la feature distintiva): referable polimorfico verso una delle
  # risorse di dominio. Persistita SOLO se la risorsa è nell'intersezione delle visibilità dei
  # partecipanti (garantito a monte da Chat::References::Parse); qui il model blinda comunque
  # l'integrità tenant (referable della stessa org) e l'unicità del tag.
  class MessageReference < ApplicationRecord
    # Tipi taggabili ammessi. Aggiungerne uno richiede codice (whitelist esplicita, no dato utente).
    ALLOWED_TYPES = %w[
      Projects::Project Ticketing::Ticket Errors::Group Metrics::Group Logs::Entry Uptime::Monitor
    ].freeze

    belongs_to :message, class_name: "Chat::Message", inverse_of: :references
    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :referable, polymorphic: true

    validates :referable_type, inclusion: { in: ALLOWED_TYPES }
    validates :referable_id, uniqueness: { scope: %i[message_id referable_type] }
    validate :organization_matches_message
    validate :referable_in_organization

    private

    # Integrità tenant: la reference porta la stessa org del proprio messaggio (specchio di
    # Chat::Message#organization_matches_conversation — senza questa guardia una reference potrebbe
    # nascere con org disallineata e bucare lo scoping per organization_id). Il fallback su
    # organization&.id copre il messaggio ancora non salvato (build in cascata nei test).
    def organization_matches_message
      message_org_id = message&.organization_id || message&.organization&.id
      return if message_org_id.blank? || organization_id.blank?

      errors.add(:organization, :mismatch) if organization_id != message_org_id
    end

    # Integrità tenant: la risorsa taggata dev'essere della stessa org del messaggio. Il Project porta
    # l'org direttamente; le altre risorse la raggiungono via project (project_id denormalizzato).
    def referable_in_organization
      return if referable.blank? || organization_id.blank?

      resource_org = referable_organization_id
      return if resource_org.blank?

      errors.add(:referable, :mismatch) if resource_org != organization_id
    end

    def referable_organization_id
      case referable
      when Projects::Project then referable.organization_id
      else referable.try(:project)&.organization_id
      end
    end
  end
end
