# frozen_string_literal: true

module Cli
  module V1
    # Preferenze di alert PERSONALI (per organizzazione) via CLI, singleton. Non gated: ognuno gestisce
    # le proprie — specchio di Member::AlertingPreferencesController. Stessi campi permessi del canale
    # Member (toggle per sorgente + min_level + quiet hours). Ownership: sempre su Current.account.
    class AlertPreferencesController < Cli::V1::BaseController
      def show
        render_ok(AlertPreferenceSerializer.new(current_preference))
      end

      def update
        pref = ::Alerting::Preference.find_or_initialize_by(
          account_id: Current.account.id, organization_id: Current.organization.id
        )
        if pref.update(preference_params)
          render_ok(AlertPreferenceSerializer.new(pref))
        else
          render_error("R422-ALERT-003", pref.errors.full_messages.to_sentence,
                       status: :unprocessable_content, details: pref.errors.to_hash)
        end
      end

      private

      def current_preference
        ::Alerting::Preference.for(account: Current.account, organization: Current.organization)
      end

      # Stesso set e stessa normalizzazione del canale Member: quiet_hours_enabled è un flag di comodo
      # (non colonna) → off azzera start/end (quiet_now? torna false).
      def preference_params
        permitted = params.permit(:in_app_enabled, :email_enabled, :errors_enabled, :uptime_enabled,
                                  :tickets_enabled, :chat_enabled, :servers_enabled, :min_level,
                                  :quiet_hours_enabled, :quiet_hours_start, :quiet_hours_end, :quiet_hours_tz)
        permitted[:min_level] = nil if permitted[:min_level].blank?
        permitted[:quiet_hours_tz] = nil if permitted[:quiet_hours_tz].blank?
        if permitted.delete(:quiet_hours_enabled).to_s != "1"
          permitted[:quiet_hours_start] = nil
          permitted[:quiet_hours_end] = nil
        else
          permitted[:quiet_hours_start] = permitted[:quiet_hours_start].presence
          permitted[:quiet_hours_end] = permitted[:quiet_hours_end].presence
        end
        permitted
      end
    end
  end
end
