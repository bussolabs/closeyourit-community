# frozen_string_literal: true

# CYRA-732 — l'UNICO posto della suite nel browser in cui si conta il tempo, e lo si conta come
# passo fra due controlli della condizione, mai come attesa cieca prima di guardare.
#
# Serve dove Capybara non arriva: Capybara riprova da sé le sue asserzioni sulla pagina
# (`have_css`, `have_text`, `have_current_path`), quindi lì non serve nulla. Non riprova invece una
# condizione che sta ALTROVE — una riga scritta a database dalla richiesta che il browser ha appena
# mandato per conto suo, o uno stato interno al browser che si legge con `evaluate_script`. Per
# quelle il tempo di risposta non è noto: si ricontrolla finché la condizione è vera, entro la
# stessa finestra che Capybara concede a tutto il resto.
module SystemWaitHelpers
  # L'orologio è MONOTONO di proposito: `Time.current` lo congelano gli spec che viaggiano nel tempo
  # (`freeze_time`), e con l'orologio fermo la scadenza non arriva mai — l'attesa diventa un blocco
  # senza fine invece di un rosso leggibile.
  def wait_until(descrizione = "condizione attesa", timeout: Capybara.default_max_wait_time, interval: 0.05)
    scadenza = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

    loop do
      return true if yield

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > scadenza
        raise "#{descrizione}: non soddisfatta entro #{timeout}s"
      end

      Kernel.sleep(interval)
    end
  end
end

RSpec.configure do |config|
  config.include SystemWaitHelpers, type: :system
end
