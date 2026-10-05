# frozen_string_literal: true

module Knowledge
  # Snapshot immutabile di una pagina KB a un dato momento: congela title/body/kind + autore.
  # Append-only (mai modificato/cancellato singolarmente): la pagina resta la LIVE/HEAD, le
  # versioni sono la cronologia. Numerazione monotòna per pagina; l'ultima (numero massimo) = live.
  # Scritto sync, in transazione, da Knowledge::RecordVersion (pattern Ticketing::Event/RecordActivity).
  class Version < ApplicationRecord
    belongs_to :page, class_name: "Knowledge::Page", inverse_of: :versions
    belongs_to :created_by, class_name: "Accounts::Account", optional: true
    belongs_to :organization, class_name: "Organizations::Organization"

    # Stesso mapping di Knowledge::Page: lo snapshot congela anche il tipo.
    enum :kind, { note: 0, decision: 1, guide: 2 }, prefix: true

    # Immutabile: uno snapshot non si riscrive mai (una modifica = una NUOVA versione).
    attr_readonly :page_id, :number, :title, :body, :tech_spec, :kind, :created_by_id, :organization_id

    validates :number, presence: true, uniqueness: { scope: :page_id }
    validates :title, presence: true
    validates :body, presence: true
    # Integrità tenant: l'org denormalizzata sulla Version deve combaciare con quella della pagina
    # (a sua volta denormalizzata su knowledge_pages, non più derivata dal progetto). Coerente con
    # Ticketing::Event: lo scoping d'audit passa da organization_id, una divergenza sarebbe un buco.
    validate :organization_matches_page

    # Cronologia deterministica: il numero monotòno dà un ordine totale e stabile.
    scope :chronological, -> { order(:number) }

    # URL amichevoli e scoped alla pagina: /pages/:page_id/versions/:number (risolti via number,
    # non UUID — il numero è unico per pagina e leggibile).
    def to_param
      number.to_s
    end

    private

    def organization_matches_page
      page_org_id = page&.organization_id
      return if page_org_id.blank? || organization_id.blank?

      errors.add(:organization, :mismatch) if organization_id != page_org_id
    end
  end
end
