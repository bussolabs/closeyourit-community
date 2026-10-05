# frozen_string_literal: true

module Vulnerabilities
  # Cosa succede DOPO che la scansione ha scritto le righe nuove: l'avviso a chi di dovere e, per le
  # sole gravità alta e critica, il ticket automatico.
  #
  # Separato dalla scansione di proposito: la scrittura dei finding deve poter avvenire anche se
  # l'alerting è configurato male, e questo pezzo deve poter essere provato senza toccare la rete.
  #
  # Il ticket automatico NON scatta su `unknown`: OSV non classifica sempre, e "gravità che non
  # conosciamo" non è "gravità alta". Chi vuole quelle apre il ticket a mano dalla sezione.
  class NotifyFindings < ApplicationService
    def initialize(findings:)
      @findings = Array(findings)
    end

    def call
      @findings.each do |finding|
        enqueue_alert(finding)
        promote(finding) if auto_promote?(finding)
      end

      Result.ok(@findings.size)
    end

    private

    def enqueue_alert(finding)
      Alerting::EvaluateJob.perform_later(
        event_type: "vulnerability_new",
        subject_type: "Vulnerabilities::Finding",
        subject_id: finding.id,
        project_id: finding.project_id,
        environment_id: nil
      )
    end

    # Due condizioni, entrambe necessarie: gravità che merita un'interruzione, e progetto che non ha
    # spento l'automatismo. Il flag esiste perché un progetto con centinaia di dipendenze transitive
    # può volere l'elenco senza il backlog.
    def auto_promote?(finding)
      finding.promotable? && finding.project.vulnerability_auto_ticket?
    end

    def promote(finding)
      reporter = finding.project.organization.owner
      # Senza un proprietario non c'è un reporter valido: il ticket non si crea, ma la riga e
      # l'avviso restano — non è un motivo per perdere la segnalazione.
      return if reporter.nil?

      Vulnerabilities::PromoteToTicket.call(group: finding, reporter: reporter)
    end
  end
end
