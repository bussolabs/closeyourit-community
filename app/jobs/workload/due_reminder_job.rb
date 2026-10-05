# frozen_string_literal: true

module Workload
  # CYRA-147 — promemoria di scadenza delle attività (Workload::Action). Giro giornaliero sulle action
  # ANCORA aperte in scadenza (Action.due_soon) che, per ognuna, accoda l'allarme rule-based org-scoped
  # workload_due_soon via Alerting::EvaluateJob — i destinatari (i partecipanti) li risolve Evaluate dal
  # subject. Le action sono team-scoped: l'organizzazione arriva da action.team. Idempotente: l'anti-spam
  # dell'alerting collassa i giri ravvicinati; su una scadenza persistente resta ~un promemoria al giorno.
  class DueReminderJob < ApplicationJob
    queue_as :notifications

    def perform
      # Precarica team→organization: evita una query per record nel loop (Prosopite) per leggere l'org.
      Workload::Action.due_soon.includes(team: :organization).find_each do |action|
        organization = action.team&.organization
        next if organization.nil?

        Alerting::EvaluateJob.perform_later(
          event_type: "workload_due_soon", subject_type: "Workload::Action",
          subject_id: action.id, project_id: nil, organization_id: organization.id
        )
      end
    end
  end
end
