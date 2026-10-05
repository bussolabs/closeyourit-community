# frozen_string_literal: true

module Servers
  # Giro giornaliero della previsione disco (CYRA-679): per ogni host attivo stima quando il volume
  # dati saturerà (Servers::DiskForecast) e avvisa (server_disk_forecast) SOLO quando la stima entra
  # sotto SERVERS_DISK_FORECAST_ALERT_DAYS — non a ogni giro con la stima bassa. L'isteresi sta in
  # disk_forecast_state sull'host: si riarma quando la stima risale oltre CLEAR_DAYS o sparisce.
  class ForecastJob < ApplicationJob
    queue_as :batch

    def perform
      Servers::Host.active.status_up.find_each do |host|
        forecast = Servers::DiskForecast.call(host: host).value
        previous = host.disk_forecast_state.is_a?(Hash) ? host.disk_forecast_state : {}

        if forecast.nil? || forecast[:days] > Servers::Constants::DISK_FORECAST_CLEAR_DAYS
          host.update!(disk_forecast_state: {}) if previous.present?
          next
        end

        alerting = forecast[:days] <= Servers::Constants::DISK_FORECAST_ALERT_DAYS
        was_alerted = previous["alerted_at"].present?
        state = { "days" => forecast[:days], "slope_pct_per_day" => forecast[:slope_pct_per_day],
                  "current_pct" => forecast[:current_pct],
                  "alerted_at" => was_alerted ? previous["alerted_at"] : nil }.compact

        if alerting && !was_alerted
          state["alerted_at"] = Time.current.iso8601
          host.update!(disk_forecast_state: state)
          Alerting::EvaluateJob.perform_later(
            event_type: "server_disk_forecast", subject_type: "Servers::Host", subject_id: host.id,
            project_id: nil, organization_id: host.organization_id, value: forecast[:days]
          )
        else
          host.update!(disk_forecast_state: state)
        end
      end
    end
  end
end
