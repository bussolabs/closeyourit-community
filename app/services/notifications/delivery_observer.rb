# frozen_string_literal: true

module Notifications
  # CYRA-672 — la riga della notifica diventa «inviata» QUI, quando il messaggio e' davvero uscito,
  # non quando lo si mette in coda.
  #
  # Prima, i servizi di consegna email scrivevano :sent subito dopo `deliver_later`, che accoda
  # soltanto. Se poi la spedizione falliva, la riga restava «inviata» per sempre: e' cosi' che
  # 3.718 email non partite sono rimaste invisibili per diciotto giorni (CYRA-671).
  #
  # ActionMailer chiama `delivered_email` solo dopo che il metodo di consegna e' tornato senza
  # sollevare. Se il fornitore rifiuta, il job va in errore e questo osservatore non viene mai
  # chiamato: la riga resta nello stato in cui era, che e' la verita'.
  class DeliveryObserver
    HEADER = "X-CloseYourIt-Notification-Ids"

    def self.delivered_email(message)
      header = message[HEADER]
      return if header.nil?

      ids = header.value.to_s.split(",").map(&:strip).reject(&:blank?)
      return if ids.empty?

      Alerting::Notification.where(id: ids).update_all( # rubocop:disable Rails/SkipsModelValidations
        status: Alerting::Notification.statuses[:sent], delivered_at: Time.current
      )
    end
  end
end
