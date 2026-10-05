# frozen_string_literal: true

module Analytics
  # Salt giornaliero del visitor_hash (identità cookieless stile Plausible). Vive su Postgres
  # condiviso — MAI in Solid Cache (SQLite locale per-container: web e worker divergerebbero).
  # Il giorno è ESPLICITAMENTE UTC (mai Date.current, che dipende da Time.zone): web e job con
  # TZ diverse devono produrre lo stesso hash. I salt oltre ANALYTICS_SALT_RETENTION_DAYS vengono
  # distrutti da Analytics::PruneJob → gli hash storici diventano irreversibili (postura GDPR).
  class Salt < ApplicationRecord
    validates :date, presence: true, uniqueness: true
    validates :value, presence: true

    # Il salt di oggi (UTC), creato al primo uso. Race-safe tra processi concorrenti:
    # find_or_create_by! + rescue RecordNotUnique (l'indice unico su date è l'arbitro).
    def self.current
      today = Time.current.utc.to_date
      find_or_create_by!(date: today) { |salt| salt.value = SecureRandom.hex(32) }
    rescue ActiveRecord::RecordNotUnique
      find_by!(date: today)
    end
  end
end
