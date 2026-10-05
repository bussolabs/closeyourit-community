# frozen_string_literal: true

# Preferenze di alert personali per organizzazione (canale CLI). Stessi campi gestiti dal canale
# Member: toggle per sorgente + min_level + finestra quiet-hours (start/end in minuti dalla mezzanotte,
# tz IANA). quiet-hours attiva sse start/end sono valorizzati.
class AlertPreferenceSerializer < ApplicationSerializer
  attributes :in_app_enabled, :email_enabled, :errors_enabled, :uptime_enabled, :tickets_enabled,
             :chat_enabled, :servers_enabled, :min_level,
             :quiet_hours_start, :quiet_hours_end, :quiet_hours_tz
end
