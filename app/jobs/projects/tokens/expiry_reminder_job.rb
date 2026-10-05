# frozen_string_literal: true

module Projects
  module Tokens
    # Promemoria di scadenza delle credenziali di ingest (CYRA-716): giro giornaliero sui token la cui
    # scadenza è entro la finestra di preavviso o già passata (Projects::Token.due_for_expiry) — per
    # ognuno chiama il dispatch che avvisa chi ha tokens.manage sul progetto. Org-wide: nessuno
    # scoping di visibilità qui (è un giro di sistema), i destinatari sono calcolati per-progetto dal
    # dispatch. Idempotente: il dedup_key del dispatch è ancorato a (token, scadenza), non alla data
    # odierna — una scadenza lasciata passare non genera un avviso a ogni esecuzione.
    #
    # Gemello di Secrets::RotationReminderJob. I token senza scadenza (tutti quelli emessi prima di
    # CYRA-716) non entrano mai in questo giro: non hanno una data da ricordare.
    class ExpiryReminderJob < ApplicationJob
      queue_as :notifications

      def perform
        # Precarica project/environment/organization: il dispatch e il contenuto le leggono per ogni
        # token, e senza questo sarebbe una query per riga in loop (Prosopite).
        ::Projects::Token.due_for_expiry
                         .includes(:environment, project: :organization)
                         .find_each do |token|
          Projects::Tokens::Notifications::DispatchExpiring.call(token: token)
        end
      end
    end
  end
end
