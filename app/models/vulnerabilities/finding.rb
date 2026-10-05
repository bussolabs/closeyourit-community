# frozen_string_literal: true

module Vulnerabilities
  # L'occorrenza: questo pacchetto, in questo progetto, è colpito da questo advisory. È la riga che
  # l'utente vede, triagia e promuove a ticket.
  #
  # Il vocabolario di stato è lo stesso di Errors::Group (unresolved/resolved/ignored → qui
  # open/resolved/ignored) perché il gesto è lo stesso: `resolved` la mette la scansione quando il
  # pacchetto è stato aggiornato, `ignored` la mette una persona che ha deciso di convivere col
  # rischio. Una voce ignorata NON torna aperta da sola: sarebbe un modo per rimettere in lista ciò
  # che qualcuno ha già valutato.
  class Finding < ApplicationRecord
    self.table_name = "vulnerabilities_findings"

    belongs_to :project, class_name: "Projects::Project", inverse_of: :vulnerability_findings
    belongs_to :package, class_name: "Vulnerabilities::Package", inverse_of: :findings
    belongs_to :advisory, class_name: "Vulnerabilities::Advisory", inverse_of: :findings
    belongs_to :ticket, class_name: "Ticketing::Ticket", optional: true

    enum :status, { open: 0, resolved: 1, ignored: 2 }, prefix: :status

    validates :first_seen_at, presence: true
    validates :last_seen_at, presence: true
    validates :package_id, uniqueness: { scope: :advisory_id }

    scope :recent, -> { order(last_seen_at: :desc) }
    scope :promotable, -> { status_open.joins(:advisory).merge(Vulnerabilities::Advisory.promotable) }
    # Ordine di lettura naturale della sezione: prima ciò che fa più male.
    scope :by_severity, lambda {
      joins(:advisory).order("vulnerabilities_advisories.severity DESC", last_seen_at: :desc)
    }

    delegate :severity, :promotable?, :display_id, to: :advisory, prefix: false
    delegate :name, :version, :ecosystem, :coordinates, to: :package, prefix: :package

    def promoted? = ticket_id.present?

    # C'è un aggiornamento concreto da suggerire? Senza `fixed_version` OSV non dichiara una versione
    # che risolve, e l'unica mossa possibile è rimuovere o sostituire la dipendenza.
    def fixable? = fixed_version.present?
  end
end
