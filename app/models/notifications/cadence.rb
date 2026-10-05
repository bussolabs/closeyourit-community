module Notifications
  # Cadenza di consegna per singola notifica × canale (email/telegram). L'in-app è sempre immediata e
  # non configurabile. Valori persistiti come stringhe nelle mappe email_cadences/telegram_cadences di
  # Alerting::Preference. daily/weekly = la notifica viene trattenuta (riga :queued) e riepilogata dal
  # job digest; immediate = consegna subito; off = niente notifica su quel canale.
  module Cadence
    IMMEDIATE = "immediate"
    DAILY = "daily"
    WEEKLY = "weekly"
    OFF = "off"

    VALUES = [ IMMEDIATE, DAILY, WEEKLY, OFF ].freeze

    # Cadenze che passano dal digest (bucket sulla riga :queued).
    DIGEST_BUCKETS = { DAILY => :daily, WEEKLY => :weekly }.freeze

    # Default per canale quando l'utente non ha impostato la cadenza dell'evento. Simmetrico:
    # quando il canale è ACCESO le notifiche partono immediate (l'email è accesa di default → storico
    # invariato; il Telegram parte spento a livello canale → nessun invio finché non lo si attiva).
    DEFAULT_EMAIL = IMMEDIATE
    DEFAULT_TELEGRAM = IMMEDIATE

    def self.valid?(value)
      VALUES.include?(value.to_s)
    end
  end
end
