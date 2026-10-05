# frozen_string_literal: true

module Secrets
  # Promemoria di rotazione (CYRA-138, Fase 4 pezzo A2): giro giornaliero sui secret con la scadenza
  # già in preavviso o superata (Secrets::Variable.due_for_rotation, calcolato in A1) — per ognuno
  # chiama il dispatch che avvisa i responsabili del progetto. Org-wide: nessuno scoping di visibilità
  # qui (è un job di sistema), i destinatari sono calcolati per-progetto dal dispatch
  # (Alerting::Recipients.for_secrets). Idempotente: il dedup_key del dispatch è ancorato a (variabile,
  # scadenza), non alla data odierna — una rotazione mancata non genera un avviso a ogni esecuzione.
  class RotationReminderJob < ApplicationJob
    queue_as :notifications

    def perform
      # Precarica project/environment/organization: evita di rifare una query per record in loop
      # (Prosopite) sulle stesse associazioni lette dal dispatch/content.
      ::Secrets::Variable.due_for_rotation
                          .includes(:project, :environment, :organization)
                          .find_each do |variable|
        Secrets::Notifications::DispatchRotationDue.call(variable: variable)
      end
    end
  end
end
