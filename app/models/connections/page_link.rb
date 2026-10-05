# frozen_string_literal: true

module Connections
  # Collegamento pagina KB↔pagina KB: `page` è la sorgente (quella che scrive il wikilink),
  # `related` la destinazione. Direzionale in scrittura, simmetrico in lettura (scope `involving`:
  # entrambe le show mostrano il collegamento, una come "Collegate" e l'altra come "Citata da").
  #
  # Dato DERIVATO dal corpo: lo riscrive interamente Knowledge::Links::Sync ad ogni salvataggio —
  # mai creato o modificato a mano dall'interfaccia. Per questo non ha `kind` né `created_by`
  # (a differenza di Connections::TicketLink, che nasce da una scelta esplicita dell'utente).
  #
  # `target_title` è il titolo COSÌ COM'È SCRITTO nel wikilink: Knowledge::Links::Render lo usa per
  # riagganciare `[[…]]` a questa riga anche quando la destinazione è stata poi rinominata.
  class PageLink < ApplicationRecord
    belongs_to :page,
               class_name: "Knowledge::Page",
               inverse_of: :links
    belongs_to :related,
               class_name: "Knowledge::Page",
               inverse_of: :inverse_links

    validates :related_id, uniqueness: { scope: :page_id }
    validate :not_self_link
    validate :same_organization

    # Tutti i collegamenti che coinvolgono le pagine date, da entrambe le direzioni.
    scope :involving, ->(pages) { where(page_id: pages).or(where(related_id: pages)) }

    # Il capo opposto della relazione rispetto alla pagina data (per rendere "collegata a X").
    def other_page(source)
      page_id == source.id ? related : page
    end

    private

    def not_self_link
      errors.add(:related, :invalid) if page_id.present? && page_id == related_id
    end

    # Integrità tenant: mai un collegamento cross-organizzazione. Sync risolve i wikilink solo
    # dentro l'org della sorgente; qui la difesa in profondità (come Connections::TicketLink).
    def same_organization
      return if page.blank? || related.blank?

      page_org = page.organization_id
      related_org = related.organization_id
      return if page_org.blank? || related_org.blank?

      errors.add(:related, :invalid) if page_org != related_org
    end
  end
end
