# frozen_string_literal: true

module Reports
  # Il riepilogo dei dati di UNA persona in UNA organizzazione (CYRA-160): calcola i numeri e li
  # spedisce. Isolato dal dispatcher così un'organizzazione con un guasto nei dati non impedisce a
  # tutte le altre di ricevere il proprio.
  class DeliverJob < ApplicationJob
    queue_as :notifications

    def perform(preference_id)
      preference = Alerting::Preference.find_by(id: preference_id)
      # Fra l'accodamento e qui possono essere passati minuti: la frequenza può essere stata spenta,
      # o un altro giro può aver già spedito. Si ricontrolla, non si dà per buono.
      return if preference.nil? || !preference.report_due?

      report = Reports::PeriodicSummary.call(account: preference.account,
                                             organization: preference.organization,
                                             cadence: preference.report_cadence)
      deliver(preference, report) if report.any_data?
      # La data si scrive SEMPRE, anche quando non c'era niente da spedire: è la guardia del periodo,
      # non la ricevuta dell'email. Senza, un'organizzazione silenziosa verrebbe ricalcolata ogni
      # giorno fino al lunedì successivo, per poi non mandare niente ogni volta.
      preference.update!(report_last_sent_at: Time.current)
    end

    private

    # `deliver_now` e non `deliver_later`: siamo già dentro un job, e il riepilogo è una struttura in
    # memoria che ActiveJob non saprebbe serializzare per un secondo passaggio in coda.
    def deliver(preference, report)
      Reports::PeriodicMailer.summary(preference.account, preference.organization, report).deliver_now
    end
  end
end
