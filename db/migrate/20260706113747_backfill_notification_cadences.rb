class BackfillNotificationCadences < ActiveRecord::Migration[8.1]
  # Preferenza sorgente disattivata (email) → cadenza "off" per ogni evento di quella sorgente nella
  # nuova mappa email_cadences. Preserva le mute esistenti nel nuovo modello per-evento. Mapping
  # inline (non dipende da Notifications::Catalog, che può evolvere): la migrazione resta autoconsistente.
  SOURCE_EVENTS = {
    "errors_enabled" => %w[error_new error_regression],
    "uptime_enabled" => %w[uptime_down uptime_up uptime_ssl_expiring cron_missed],
    "performance_enabled" => %w[metric_threshold],
    "tickets_enabled" => %w[
      ticket_created ticket_assigned ticket_status_changed ticket_milestone_changed
      ticket_commented ticket_mentioned ticket_review_requested ticket_review_rejected ticket_review_approved
    ],
    "chat_enabled" => %w[chat_message chat_mentioned],
    "servers_enabled" => %w[
      server_down server_up server_cpu server_mem server_disk server_temp server_service_failed server_smart_failing
    ]
  }.freeze

  class Preference < ActiveRecord::Base
    self.table_name = "alerting_preferences"
  end

  def up
    Preference.reset_column_information

    Preference.find_each do |pref|
      off = {}
      SOURCE_EVENTS.each do |column, events|
        next if pref[column] # true = sorgente abilitata: niente da spegnere

        events.each { |event_type| off[event_type] = "off" }
      end
      next if off.empty?

      pref.update_columns(email_cadences: off) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def down
    # Le cadenze per-evento non si ricostruiscono nei booleani di sorgente → down non ripristinabile.
  end
end
