# frozen_string_literal: true

module Seo
  # Un giro di visita al sito. Esiste per due domande che nient'altro sa rispondere: "com'è andata
  # l'ultima volta" e "i rilievi aperti stanno scendendo o salendo".
  #
  # Un giro FALLITO resta qui con il suo motivo: senza questa riga un guasto del crawler sarebbe
  # indistinguibile da un sito improvvisamente a posto — la peggiore delle bugie, perché rassicura.
  class Audit < ApplicationRecord
    self.table_name = "seo_audits"

    belongs_to :site, class_name: "Seo::Site", inverse_of: :audits

    # Stato del giro, gestito dal sistema (workflow tecnico) → enum legittimo.
    enum :status, { running: 0, completed: 1, failed: 2 }, prefix: :status

    validates :started_at, presence: true

    # CYRA-818 — `id` come secondo criterio: due giri con lo stesso istante di partenza esistono
    # (una rivisita chiesta a mano mentre parte quella programmata), e senza pareggio dichiarato
    # PostgreSQL può restituirli in un ordine diverso a ogni lettura — la cronologia del dettaglio
    # e il numero dell'elenco finirebbero per nominare due giri diversi.
    scope :recent, -> { order(started_at: :desc, id: :desc) }
    scope :finished, -> { where.not(finished_at: nil) }

    # L'ultimo giro CONCLUSO di ciascun sito, uno per sito e in UNA query (CYRA-818).
    #
    # Serve alla riga dell'elenco, che mette la data dell'ultimo controllo accanto al numero di
    # pagine viste: sono due fatti che si leggono come uno solo, e devono venire dallo stesso giro.
    # Prima l'elenco caricava tutta la cronologia di tutti i siti e la riduceva in Ruby con
    # `index_by`, che tiene l'ULTIMO valore visto per chiave — su un ordinamento dal nuovo al vecchio
    # significa tenere il giro più VECCHIO. Da qui il numero che non tornava col dettaglio.
    #
    # Un giro `running` resta fuori: non ha ancora contato niente, e i suoi zeri accanto alla data
    # dell'ultimo controllo concluso sarebbero lo stesso disallineamento al contrario. È anche il
    # giro a cui `Seo::Site#last_audited_at` si riferisce, scritto a fine visita da `Seo::AuditSite`.
    scope :latest_per_site, lambda { |site_ids|
      where(site_id: site_ids).where.not(status: :running)
        .select("DISTINCT ON (site_id) *")
        .order(:site_id, started_at: :desc, id: :desc)
    }

    def duration_seconds
      return nil if started_at.blank? || finished_at.blank?

      (finished_at - started_at).round
    end
  end
end
