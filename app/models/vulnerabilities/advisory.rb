# frozen_string_literal: true

module Vulnerabilities
  # Cache locale di un record OSV.dev. È l'unica tabella del dominio SENZA organizzazione né
  # progetto: un advisory è dato pubblico, identico per tutti i tenant. Duplicarlo per organizzazione
  # significherebbe rifare la stessa richiesta N volte senza guadagnare isolamento — che resta
  # garantito comunque, perché a un advisory si arriva solo attraverso un finding, che è del progetto.
  #
  # `severity` è la scala GHSA che OSV espone in `database_specific.severity`, non il punteggio CVSS:
  # è quella che un umano legge e quella su cui è tarato il gate del ticket automatico. Il vettore
  # CVSS grezzo resta in `cvss` per chi vuole il dettaglio.
  class Advisory < ApplicationRecord
    self.table_name = "vulnerabilities_advisories"

    has_many :findings, class_name: "Vulnerabilities::Finding", foreign_key: :advisory_id,
             inverse_of: :advisory, dependent: :destroy

    # Vocabolario fisso di un database esterno (GHSA) → enum legittimo.
    enum :severity, { unknown: 0, low: 1, moderate: 2, high: 3, critical: 4 }, prefix: :severity

    validates :osv_id, presence: true, uniqueness: true

    scope :promotable, -> { where(severity: %i[high critical]) }
    scope :by_severity, -> { order(severity: :desc) }

    # Scala GHSA → enum. Tutto ciò che non riconosciamo resta `unknown`: una severity inventata è
    # peggio di una assente, perché il gate del ticket automatico ci si appoggia.
    SEVERITY_FROM_OSV = {
      "LOW" => :low, "MODERATE" => :moderate, "MEDIUM" => :moderate,
      "HIGH" => :high, "CRITICAL" => :critical
    }.freeze

    def self.severity_from(value) = SEVERITY_FROM_OSV.fetch(value.to_s.upcase, :unknown)

    # Solo alta e critica aprono un ticket da sole. `unknown` NON promuove mai: OSV non sempre
    # classifica, e un advisory senza gravità non è un advisory grave.
    def promotable? = severity_high? || severity_critical?

    # Il CVE è l'identificatore con cui la gente cerca; l'id OSV è il nostro. Mostriamo il primo se c'è.
    def display_id = aliases.find { |value| value.start_with?("CVE-") } || osv_id

    def osv_url = url.presence || "https://osv.dev/vulnerability/#{osv_id}"

    # Prima versione che risolve per QUESTO pacchetto. Si legge dalla copia locale di `affected`:
    # nessuna richiesta a OSV per un advisory già noto, che è il caso normale quando la stessa CVE
    # tocca più progetti della stessa organizzazione.
    def fixed_version_for(ecosystem:, name:, version:)
      Vulnerabilities::Osv::FixedVersion.call(
        affected: affected, ecosystem: ecosystem, name: name, version: version
      )
    end

    # Un advisory viene rivisto dopo la pubblicazione: oltre questa età lo rileggiamo invece di
    # fidarci della copia (la gravità può essere stata alzata).
    def stale?(now = Time.current)
      refreshed_at.blank? || refreshed_at < now - Vulnerabilities::Constants::ADVISORY_REFRESH_AFTER
    end
  end
end
