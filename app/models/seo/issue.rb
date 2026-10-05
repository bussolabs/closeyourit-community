# frozen_string_literal: true

module Seo
  # Il rilievo: questo controllo, su questa pagina (o su questo sito), è fallito — e `evidence` dice
  # perché, con i valori in mano. È la riga che una persona legge, triagia e promuove a ticket.
  #
  # Il vocabolario di stato è quello di Vulnerabilities::Finding, perché il gesto è lo stesso:
  # `resolved` la mette la scansione quando il problema non c'è più, `ignored` la mette una persona
  # che ha deciso di conviverci. Un rilievo ignorato NON torna aperto da solo alla visita
  # successiva: sarebbe un modo per rimettere in lista ciò che qualcuno ha già valutato.
  class Issue < ApplicationRecord
    self.table_name = "seo_issues"

    belongs_to :site, class_name: "Seo::Site", inverse_of: :issues
    belongs_to :page, class_name: "Seo::Page", inverse_of: :issues, optional: true
    belongs_to :ticket, class_name: "Ticketing::Ticket", optional: true

    # Copiata dal registry alla creazione, non derivata a ogni lettura: così l'ordinamento "prima
    # ciò che fa più male" è una colonna e non un join, e ritoccare il listino in Seo::Check non
    # riscrive la storia dei rilievi già aperti.
    enum :severity, { low: 0, medium: 1, high: 2, critical: 3 }, prefix: :severity
    enum :status, { open: 0, resolved: 1, ignored: 2 }, prefix: :status

    validates :check_key, presence: true,
              inclusion: { in: ->(_record) { Seo::Check.keys } },
              uniqueness: { scope: %i[site_id page_id] }
    validates :first_seen_at, :last_seen_at, presence: true

    scope :recent, -> { order(last_seen_at: :desc) }
    # Ordine di lettura naturale della sezione: prima ciò che fa più male, poi ciò che si è visto
    # più di recente.
    scope :by_severity, -> { order(severity: :desc, last_seen_at: :desc) }
    scope :for_area, ->(area) { where(check_key: Seo::Check.for_area(area).map(&:key)) }
    # Ciò che vale la pena promuovere a ticket senza pensarci troppo.
    scope :promotable, -> { status_open.where(severity: %i[high critical]) }

    delegate :project, :project_id, to: :site

    def check = Seo::Check.find(check_key)

    def label = check&.label || check_key

    def explanation = check&.explanation.presence

    def area = check&.area

    def promoted? = ticket_id.present?

    # L'URL a cui si riferisce il rilievo: quella della pagina finché esiste, altrimenti quella
    # congelata nella prova. Un rilievo che non sa più di cosa parlava non serve a nessuno.
    def url = page&.url || evidence["url"]

    # Riconferma alla visita successiva: il problema c'è ancora. Non tocca lo stato — un `ignored`
    # riconfermato resta ignorato — ma aggiorna la prova, che nel frattempo può essere cambiata
    # (un title duplicato oggi lo è con pagine diverse da ieri).
    def touch_seen!(instant, evidence_payload = nil, severity_now = nil)
      attributes = { last_seen_at: instant }
      attributes[:evidence] = evidence_payload if evidence_payload.present?
      attributes[:severity] = severity_now if severity_now.present? && status_open?
      update!(attributes)
    end
  end
end
