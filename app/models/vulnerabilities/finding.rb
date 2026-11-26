# frozen_string_literal: true

module Vulnerabilities
  # L'occorrenza: questo pacchetto, in questo progetto, è colpito da questo advisory. È la riga che
  # l'utente vede, triagia e promuove a ticket.
  #
  # Il vocabolario di stato è lo stesso di Errors::Group (unresolved/resolved/ignored → qui
  # open/resolved/ignored) perché il gesto è lo stesso: `resolved` la mette la scansione quando il
  # pacchetto è stato aggiornato, `ignored` la mette una persona che ha deciso di convivere col
  # rischio. La scansione non riapre mai una voce ignorata: sarebbe un modo per rimettere in lista ciò
  # che qualcuno ha già valutato. Ma la decisione è a tempo (CYRA-1144): porta un motivo, chi l'ha
  # presa e il giorno in cui scade, e quel giorno il controllo giornaliero la riapre e avvisa
  # (Vulnerabilities::ReopenExpiredIgnoresJob). Le voci ignorate prima di CYRA-1144 non hanno scadenza
  # e restano ignorate finché qualcuno non le riapre.
  class Finding < ApplicationRecord
    self.table_name = "vulnerabilities_findings"

    belongs_to :project, class_name: "Projects::Project", inverse_of: :vulnerability_findings
    belongs_to :package, class_name: "Vulnerabilities::Package", inverse_of: :findings
    belongs_to :advisory, class_name: "Vulnerabilities::Advisory", inverse_of: :findings
    belongs_to :ticket, class_name: "Ticketing::Ticket", optional: true
    # Chi ha deciso di ignorare. Facoltativo: le voci ignorate prima di CYRA-1144 non lo sanno, e un
    # account rimosso lo svuota (on_delete: :nullify) senza cancellare la decisione.
    belongs_to :ignored_by, class_name: "Accounts::Account", optional: true

    enum :status, { open: 0, resolved: 1, ignored: 2 }, prefix: :status

    validates :first_seen_at, presence: true
    validates :last_seen_at, presence: true
    validates :package_id, uniqueness: { scope: :advisory_id }

    # CYRA-1144 — la regola per ignorare, uguale su ogni canale: pagina e riga di comando passano
    # entrambe da Vulnerabilities::IgnoreFinding, che salva in questo contesto. Solo nel contesto
    # `:ignore`: la scansione che aggiorna `last_seen_at` di una voce ignorata prima di questa regola
    # non deve fallire perché quella voce non ha una scadenza.
    with_options on: :ignore do
      validates :triage_note, presence: true
      validates :ignored_until, presence: true
      validate :ignored_until_in_the_future
    end

    scope :recent, -> { order(last_seen_at: :desc) }
    scope :promotable, -> { status_open.joins(:advisory).merge(Vulnerabilities::Advisory.promotable) }
    # Ordine di lettura naturale della sezione: prima ciò che fa più male.
    scope :by_severity, lambda {
      joins(:advisory).order("vulnerabilities_advisories.severity DESC", last_seen_at: :desc)
    }
    # Ignorate la cui scadenza è arrivata: il giorno di scadenza la decisione non vale più.
    scope :ignore_expired, ->(today = Date.current) { status_ignored.where(ignored_until: ..today) }

    delegate :severity, :promotable?, :display_id, to: :advisory, prefix: false
    delegate :name, :version, :ecosystem, :coordinates, to: :package, prefix: :package

    def promoted? = ticket_id.present?

    # C'è un aggiornamento concreto da suggerire? Senza `fixed_version` OSV non dichiara una versione
    # che risolve, e l'unica mossa possibile è rimuovere o sostituire la dipendenza.
    def fixable? = fixed_version.present?

    # Riaprire a mano annulla la decisione: scadenza e autore si svuotano, il motivo resta come
    # memoria di cosa era stato valutato.
    def reopen!
      update!(status: :open, resolved_at: nil, ignored_until: nil, ignored_by: nil)
    end

    private

    def ignored_until_in_the_future
      return if ignored_until.nil? || ignored_until > Date.current

      errors.add(:ignored_until, :must_be_future)
    end
  end
end
