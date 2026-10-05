# frozen_string_literal: true

module Home
  module Deferrals
    # Rimanda una card della coda a domani mattina per QUESTO account.
    #
    # Idempotente per costruzione: rimandare due volte la stessa card è lo stesso gesto ripetuto,
    # non due rimandi, quindi si sposta la scadenza invece di aggiungere una riga (l'indice unico
    # [account_id, card_key] lo impone comunque).
    #
    # La chiave NON viene validata qui: chi chiama deve averla già risolta con
    # Home::Approvals::Detail, che è l'unico posto che sa se questo account quella card può
    # davvero vederla. Scriverla senza quel passaggio vorrebbe dire accettare una key inventata.
    #
    #   Home::Deferrals::Defer.call(account:, organization:, card_key: "agent_plan:…") → Result
    class Defer < ApplicationService
      # Domani mattina: l'ora in cui si riapre il programma, non la mezzanotte. Rimandare a
      # mezzanotte vorrebbe dire ritrovarsi la card addosso a fine giornata di chi lavora tardi.
      MORNING_HOUR = 7

      def initialize(account:, organization:, card_key:, now: Time.current)
        @account = account
        @organization = organization
        @card_key = card_key.to_s.strip
        @now = now
      end

      def call
        return Result.err(blank_key) if @card_key.blank?

        deferral = ::Home::Deferral.find_or_initialize_by(account_id: @account.id, card_key: @card_key)
        deferral.organization_id ||= @organization.id
        deferral.until_at = tomorrow_morning
        return Result.ok(deferral) if deferral.save

        Result.err(AppError.new(I18n.t("home.deferrals.errors.invalid"),
                                code: "R422-HOMEDEFERRAL-001", details: deferral.errors.to_hash))
      rescue ActiveRecord::RecordNotUnique
        # Fra il find e il save un'altra richiesta ha scritto la stessa riga: doppio clic, due
        # schede aperte, un rinvio del browser. È lo stesso gesto arrivato due volte, non un
        # conflitto: si rilegge la riga che c'è e le si sposta la scadenza, che è quello che questo
        # servizio fa comunque. Senza questo, l'indice unico esce come 500 su un gesto innocuo.
        retry_after_race
      end

      private

      # Il secondo giro dopo una corsa persa: la riga adesso esiste di sicuro.
      def retry_after_race
        deferral = ::Home::Deferral.find_by(account_id: @account.id, card_key: @card_key)
        return Result.ok(deferral) if deferral&.update(until_at: tomorrow_morning)

        Result.err(AppError.new(I18n.t("home.deferrals.errors.invalid"), code: "R422-HOMEDEFERRAL-001"))
      end

      # Nel fuso di chi rimanda: «domani mattina» è un'ora del suo calendario, non del server.
      def tomorrow_morning
        @now.in_time_zone(Time.zone).tomorrow.change(hour: MORNING_HOUR)
      end

      def blank_key
        AppError.new(I18n.t("home.deferrals.errors.blank_key"), code: "R422-HOMEDEFERRAL-002")
      end
    end
  end
end
