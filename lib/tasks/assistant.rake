# frozen_string_literal: true

namespace :assistant do
  # Diagnostica dell'assistente help. Risponde a "perché la chat risponde sempre «Non sono riuscito
  # a rispondere»". NON stampa MAI il valore della chiave — solo la sua lunghezza.
  # In produzione: kamal app exec --reuse "bin/rails assistant:healthcheck"
  #
  # SENZA argomento (CYRA-765): l'AI la offre il sistema con UNA chiave, non più una per
  # organizzazione. Il conteggio dei falliti resta globale per lo stesso motivo — un guasto del
  # server AI riguarda tutti, e ristringerlo a un'organizzazione nasconderebbe metà del sintomo.
  desc "Healthcheck del server AI: configurazione, modello, ping live, messaggi falliti"
  task healthcheck: :environment do
    key = ENV["AI_API_KEY"].to_s
    puts "AI_BASE_URL: #{ENV['AI_BASE_URL'].presence || '(assente)'}"
    puts "AI_API_KEY: length=#{key.length} vuota=#{key.strip.empty?}"
    puts "modello: #{Ai::Llm::Constants::MODEL}"

    # Distribuzione dei fallimenti persistiti nelle ultime 24 ore: discrimina configurazione/auth
    # (R502-LLM-002) da upstream (R502-LLM-001), nessun testo (R502-LLM-004), rate-limit
    # (R429-LLM-001), server giù (R503-LLM-001) e timeout (R504-LLM-001). La finestra corta serve a
    # separare il guasto di adesso dallo storico: su tutto il tempo un problema chiuso mesi fa
    # continuerebbe a pesare quanto quello in corso.
    failed = Assistant::Message.where(status: :failed)
                               .where(created_at: 24.hours.ago..)
                               .group(:error_code).count
    puts "messaggi falliti nelle ultime 24h per error_code: #{failed.inspect}"

    # Ping live: un giro vero end-to-end contro il server AI. Riporta esito, tempo e codice errore
    # (mai la chiave). Il tempo conta quanto l'esito — il DGX mette in coda, e «lento» è un guasto
    # diverso da «rotto».
    print "ping live: "
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      text = Ai::Llm::Client.new.generate_content(
        system: "Rispondi con una parola",
        contents: [ { role: "user", parts: [ { text: "ping" } ] } ]
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      puts "OK in #{elapsed.round(2)}s (#{text.to_s.strip.truncate(60).inspect})"
    rescue KeyError => e
      puts "FAIL: server AI non configurato (#{e.message})"
    rescue Ai::Llm::Client::Error => e
      puts "FAIL #{e.code} dopo #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)}s: #{e.message}"
    rescue StandardError => e
      puts "FAIL #{e.class}: #{e.message}"
    end
  end
end
