# frozen_string_literal: true

module Guidance
  # Riferimento a una fonte di contesto dichiarato a un livello della gerarchia (org/gruppo/progetto).
  # `kind` dice al consumer come leggere `location` (un repo, una pagina di knowledge base, una URL, un
  # path); `required` segnala che va seguito (metadato, non incide sulla risoluzione). L'ereditarietà tra
  # livelli e l'override sulla stessa `key` li governa Guidance::Resolve — qui vivono solo forma e
  # integrità tenant. Un `enabled: false` è il segnale di DISABLE della key (vedi Guidance::Resolve).
  class Reference < ApplicationRecord
    # 0 repository · 1 knowledge_base · 2 url · 3 path — discriminatore che guida l'interpretazione di
    # location nel consumer; aggiungere un kind richiede codice, quindi enum e non lookup CRUD.
    enum :kind, { repository: 0, knowledge_base: 1, url: 2, path: 3 }, prefix: true

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :owner, polymorphic: true
    belongs_to :created_by, class_name: "Accounts::Account", optional: true

    normalizes :key, with: ->(key) { key.to_s.strip.downcase }
    normalizes :location, with: ->(value) { value.to_s.strip.presence }
    normalizes :instructions, with: ->(value) { value.to_s.strip.presence }

    validates :owner_type, inclusion: { in: Guidance::OWNER_TYPES }
    validates :key, presence: true, format: { with: Guidance::KEY_FORMAT },
                    uniqueness: { scope: %i[owner_type owner_id] }
    # Una reference È un puntatore a una fonte: senza location non c'è nulla da leggere e il resolver
    # esporrebbe un riferimento vuoto. `kind` dice come interpretarla, `location` dice dove punta.
    validates :location, presence: true
    validate :organization_matches_owner

    # Ordine deterministico dello slot nel risultato risolto: position poi key, tie-break id.
    scope :ordered, -> { order(:position, :key, :id) }

    private

    # Integrità tenant (anti-BOLA): la reference porta la stessa org del proprio owner. L'org come owner
    # espone la propria org via `id`; gruppo e progetto via `organization_id` (case come
    # Chat::MessageReference#referable_organization_id).
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
