# frozen_string_literal: true

module Secrets
  module Notifications
    # Promemoria di rotazione (CYRA-138, Fase 4 pezzo A2): dato un secret con rotation_status
    # :due_soon/:overdue (calcolato in A1 da Secrets::Variable), avvisa i responsabili del progetto —
    # owner + chi ha secrets.manage (Alerting::Recipients.for_secrets). Gemello strutturale di
    # Ticketing::Notifications::DispatchEvent: rule_id nil, subject = la variabile, gating preferenze
    # via Preference#channels_for, in-app SEMPRE consegnata. Idempotente: il dedup_key è ancorato a
    # (variabile, rotate_by) — non alla data odierna — così un overdue prolungato senza rotazione non
    # spamma a ogni esecuzione del job ricorrente, ma una rotazione reale (rotate_by si sposta) riarma
    # l'avviso da sola.
    class DispatchRotationDue < ApplicationService
      def self.call(...) = new(...).call

      def initialize(variable:, at: Time.current)
        @variable = variable
        @at = at
      end

      def call
        return Result.ok(0) unless notifiable?

        content = Content.for(variable: @variable)
        delivered = 0
        Alerting::Recipients.for_secrets(project: @variable.project).each do |account|
          delivered += deliver_to(account, content)
        end
        Result.ok(delivered)
      end

      private

      # Guardia difensiva: SOLO due_soon/overdue (mai ok/none). Il job ricorrente filtra già con lo
      # scope due_for_rotation (A1), ma il dispatch resta sicuro anche invocato direttamente
      # (console/test) su una variabile che non è (più) in scadenza.
      def notifiable?
        %i[due_soon overdue].include?(@variable.rotation_status)
      end

      def organization
        @organization ||= @variable.project.organization
      end

      def deliver_to(account, content)
        pref = Alerting::Preference.for(account: account, organization: organization)
        channels = pref.channels_for(:secret_rotation_due, connected_telegram: account.connected_telegram?)

        count = 0
        count += deliver_in_app(account, content) # in-app SEMPRE
        telegram = deliver_telegram(account, content, channels[:telegram])
        unless ::Notifications::Deliver.reached_by_telegram?(telegram)
          count += deliver_email(account, content, pref, channels[:email])
        end
        count + (telegram&.ok? ? 1 : 0)
      end

      def deliver_in_app(account, content)
        result = Deliver.in_app(
          account: account, variable: @variable, organization: organization,
          event_type: :secret_rotation_due, content: content, dedup_key: dedup_key(account, "in_app")
        )
        result.ok? ? 1 : 0
      end

      def deliver_email(account, content, pref, decision)
        return 0 unless decision[:deliver]

        result = Deliver.email(
          account: account, variable: @variable, organization: organization,
          event_type: :secret_rotation_due, content: content, dedup_key: dedup_key(account, "email"),
          quiet: pref.quiet_now?(at: @at), bucket: decision[:bucket]
        )
        result.ok? ? 1 : 0
      end

      # Torna il Result della consegna (nil se il canale è spento): serve a decidere la mail (CYRA-853).
      def deliver_telegram(account, content, decision)
        return unless decision[:deliver]

        Deliver.telegram(
          account: account, variable: @variable, organization: organization,
          event_type: :secret_rotation_due, content: content, dedup_key: dedup_key(account, "telegram"),
          bucket: decision[:bucket]
        )
      end

      # Una notifica per (variabile, scadenza, account, canale): rotate_by cambia quando il secret
      # viene ruotato (nuova finestra → nuovo avviso); se resta overdue senza rotazione, rotate_by
      # resta lo stesso → stessa key → niente spam giornaliero (idempotenza voluta, non un bug).
      def dedup_key(account, via)
        "secret_rotation:#{@variable.id}:#{@variable.rotate_by.to_i}:#{account.id}:#{via}"
      end
    end
  end
end
