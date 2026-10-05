# frozen_string_literal: true

# CYRA-785 — un giro ricorrente su una coda che nessun pool serve non produce errori: i job si
# accodano e restano lì. È durato quattro settimane senza che nulla lo segnalasse.
#
# Il gate vero è lo spec (spec/services/ops/recurring_queue_coverage_spec.rb): diventa rosso prima
# del merge, che è il momento giusto per accorgersene. Questo initializer è la seconda rete, per il
# caso in cui la configurazione arrivi in produzione senza passare da lì — un `queue:` tolto a mano
# sul server, o una gemma aggiornata che sposta la coda del wrapper dei task `command:`.
#
# SEGNALA, non blocca. Un raise all'avvio trasformerebbe un giro fermo — grave ma silenzioso — in
# un'applicazione che non parte, e un refuso in `queue:` diventerebbe un'interruzione di servizio.
# Rails.error.report lo fa arrivare dove arrivano gli altri guasti: CloseYourIt sorveglia sé stesso,
# quindi il rilievo compare fra gli errori del progetto invece di restare in un log che nessuno legge.
Rails.application.config.after_initialize do
  next if Rails.env.test?

  scoperti = Ops::RecurringQueueCoverage.uncovered
  next if scoperti.empty?

  list = scoperti.map { |task| "#{task[:key]} → #{task[:queue]}" }.join(", ")
  message = "Giri ricorrenti su code che nessun pool di config/queue.yml serve: #{list}. " \
              "Non gireranno mai e non falliranno mai."

  Rails.logger.error(message)
  Rails.error.report(
    Ops::RecurringQueueCoverage::UncoveredQueue.new(message),
    handled: true,
    source: "application.ops",
    context: { uncovered: scoperti }
  )
rescue StandardError => e
  # Un controllo di salute non può essere ciò che impedisce l'avvio.
  Rails.logger.error("Controllo copertura code ricorrenti non riuscito: #{e.class}: #{e.message}")
end
