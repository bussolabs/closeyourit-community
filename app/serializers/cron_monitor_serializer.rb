# frozen_string_literal: true

# Cron/heartbeat monitor (canale CLI, sola lettura). status = unknown/ok/late/missed (enum string,
# salute gestita dal sistema). expected_interval_minutes + grace_minutes definiscono la finestra attesa
# del check-in; last_check_in_at è l'ultimo heartbeat ricevuto.
class CronMonitorSerializer < ApplicationSerializer
  attributes :id, :project_id, :environment_id, :name, :slug, :status,
             :expected_interval_minutes, :grace_minutes, :last_check_in_at, :created_at
end
