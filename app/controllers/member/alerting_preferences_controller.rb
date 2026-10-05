# frozen_string_literal: true

module Member
  # Preferenze di alert PERSONALI (per organizzazione). Non gated: ognuno gestisce le proprie.
  class AlertingPreferencesController < Member::BaseController
    permission_not_required "Preferenze di avviso personali: ognuno gestisce le proprie, per organizzazione."

    def show
      @preference = ::Alerting::Preference.for(account: Current.account, organization: Current.organization)
      # CYRA-444 — si arriva qui dalla tab Telegram per scegliere UNA colonna fra due: il parametro la
      # indica. Allowlist di un valore solo: qualunque altra cosa lascia la pagina com'era.
      @highlight_telegram = params[:highlight].to_s == "telegram"
    end

    def update
      @preference = ::Alerting::Preference.find_or_initialize_by(
        account_id: Current.account.id, organization_id: Current.organization.id
      )
      preset = ::Notifications::Preset.find(params[:preset])
      if @preference.update(preference_params(preset: preset))
        redirect_to member_notification_preferences_path, notice: notice_for(preset)
      else
        render :show, status: :unprocessable_content
      end
    end

    private

    def notice_for(preset)
      return t("member.notifications.saved") if preset.nil?

      t("member.notifications.presets.applied", name: preset.label)
    end

    def preference_params(preset: nil)
      permitted = params.permit(:email_enabled, :telegram_enabled, :min_level, :report_cadence,
                                :quiet_hours_enabled, :quiet_hours_start, :quiet_hours_end, :quiet_hours_tz,
                                email_cadences: {}, telegram_cadences: {})
      # Riepilogo periodico dei dati (CYRA-160): allowlist sul vocabolario dell'enum. Un valore fuori
      # vocabolario non azzera la scelta precedente — la lascia com'è, come per le cadenze ignote.
      permitted.delete(:report_cadence) unless ::Alerting::Preference.report_cadences.key?(permitted[:report_cadence].to_s)
      # Configurazione pronta (CYRA-443): scrive la matrice completa e SOSTITUISCE le cadenze del form
      # — è quello che si chiede premendo il bottone. Canali e ore silenziose restano quelli inviati.
      # Chiave fuori vocabolario → preset nil → vale il form, come per le cadenze ignote qui sotto.
      if preset
        permitted[:email_cadences] = preset.cadences
        permitted[:telegram_cadences] = preset.cadences
      else
        permitted[:email_cadences] = sanitize_cadences(permitted[:email_cadences])
        permitted[:telegram_cadences] = sanitize_cadences(permitted[:telegram_cadences])
      end
      permitted[:min_level] = nil if permitted[:min_level].blank?
      permitted[:quiet_hours_tz] = nil if permitted[:quiet_hours_tz].blank?
      # Quiet hours off → azzera la finestra (quiet_now? torna false).
      if permitted.delete(:quiet_hours_enabled).to_s != "1"
        permitted[:quiet_hours_start] = nil
        permitted[:quiet_hours_end] = nil
      else
        permitted[:quiet_hours_start] = permitted[:quiet_hours_start].presence
        permitted[:quiet_hours_end] = permitted[:quiet_hours_end].presence
      end
      permitted
    end

    # Allowlist: solo event_type del catalogo, solo cadenze valide. Scarta chiavi/valori ignoti (il
    # client non può iniettare event_type o cadenze arbitrarie nel jsonb).
    def sanitize_cadences(map)
      return {} if map.blank?

      map.to_h.slice(*::Notifications::Catalog.event_types)
         .select { |_event, cadence| ::Notifications::Cadence.valid?(cadence) }
    end
  end
end
