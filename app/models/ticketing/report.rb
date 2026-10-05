# frozen_string_literal: true

module Ticketing
  # Resoconto di lavorazione di un ticket, versionato e append-only. Il corrente è la versione col
  # numero più alto: non esiste una riga HEAD da tenere allineata, quindi non esiste il caso in cui
  # HEAD e cronologia divergono.
  #
  # Una versione non si riscrive MAI (attr_readonly): correggere un resoconto significa scriverne uno
  # nuovo. È ciò che rende il resoconto una traccia storica invece che uno stato mutevole — e ciò che
  # permette alla migrazione dei vecchi commenti di produrre versioni fedeli all'originale.
  class Report < ApplicationRecord
    include LengthBudget

    belongs_to :ticket,
               class_name: "Ticketing::Ticket",
               inverse_of: :reports
    # L'autore può sparire senza portarsi via il resoconto: il nome resta congelato in author_name.
    belongs_to :author,
               class_name: "Accounts::Account",
               optional: true
    # Il commento da cui la migrazione ha ricavato questa versione. Vuoto per i resoconti nati dopo.
    belongs_to :source_comment,
               class_name: "Ticketing::Comment",
               optional: true

    # `review_rejection` (CYRA-389) = la motivazione con cui una persona ha respinto il lavoro
    # consegnato. Sta qui perché il resoconto è il posto del testo lungo di un ticket — e perché è
    # l'unico posto che si legge sia dalle pagine sia dalla CLI, quindi l'agente che deve rifare il
    # lavoro trova il perché con i comandi che ha già. Marcata, non anonima: è testo di resoconto ma
    # NON è il racconto di un lavoro consegnato (vedi lo scope `delivered`).
    enum :source, { manual: 0, agent: 1, migrated: 2, review_rejection: 3 }, prefix: true

    attr_readonly :ticket_id, :author_id, :author_name, :version, :body, :source, :source_comment_id

    # Ortografia italiana prima del salvataggio (vedi Text::ItalianOrthography): il resoconto lo
    # scrive quasi sempre l'agente che ha lavorato il ticket, ed è immutabile — se sbaglia un accento
    # quella versione se lo tiene per sempre.
    normalizes :body,
               with: ->(value) { Text::ItalianOrthography.correct(LengthBudget.normalize_newlines(value)).strip }

    before_validation :assign_version, on: :create
    before_validation :snapshot_author_name, on: :create

    validates :body, presence: true
    validates :version, numericality: { only_integer: true, greater_than: 0 },
                        uniqueness: { scope: :ticket_id }
    length_budget :body, maximum: Ticketing::Constants::REPORT_MAX_CHARS
    validate :author_belongs_to_organization

    # Cronologia deterministica: il numero dà un ordine totale e stabile anche fra versioni scritte
    # nello stesso secondo (la migrazione ne scrive molte in una transazione sola).
    scope :chronological, -> { order(:version) }

    # Le stesure che raccontano un LAVORO CONSEGNATO (CYRA-389): tutte tranne le motivazioni di un
    # respingimento. Serve dove il prodotto mostra "cosa è stato consegnato" — la coda Approvazioni —
    # perché lì l'ultima stesura in assoluto sarebbe la motivazione con cui si è respinto il giro
    # prima, e chi torna a decidere la leggerebbe come il lavoro di adesso.
    scope :delivered, -> { where.not(source: :review_rejection) }

    # URL leggibili e scoped al ticket: /tickets/:ticket_id/report/versions/:version.
    def to_param
      version.to_s
    end

    private

    # `||=`: la migrazione dati assegna il numero a mano per ricostruire l'ordine cronologico dei
    # vecchi commenti, e deve poterlo fare anche su un retry.
    def assign_version
      self.version ||= ticket&.reports&.maximum(:version).to_i + 1
    end

    def snapshot_author_name
      self.author_name ||= author&.name
    end

    # Isolamento tenant (anti-BOLA): specchio di Ticketing::Comment#author_belongs_to_organization —
    # ci scrive anche la CLI, quindi il controllo non può vivere solo nel controller.
    def author_belongs_to_organization
      org_id = ticket&.project&.organization_id
      return if org_id.blank? || author.blank?
      return if Connections::Membership.exists?(account_id: author.id, organization_id: org_id)

      errors.add(:author, :not_member)
    end
  end
end
