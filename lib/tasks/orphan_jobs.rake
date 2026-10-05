# frozen_string_literal: true

# CYRA-786 — i job in attesa su una coda che nessun pool serve non ripartiranno mai e non falliranno
# mai. Vanno tolti a mano, una volta: che non se ne creino di nuovi lo garantisce
# Ops::RecurringQueueCoverage (CYRA-785).
#
# Due comandi separati e non un flag: `report` non tocca niente e si può lanciare in produzione senza
# pensarci, `delete` cancella e chiede conferma. Chi cancella ha già letto i numeri.
namespace :jobs do
  namespace :orphans do
    desc "Elenca i job in attesa su code che nessun pool serve (sola lettura)"
    task report: :environment do
      summary = Ops::OrphanRecurringJobs.summary

      if summary[:count].zero?
        puts "Nessun job orfano: ogni coda con lavoro in attesa è servita da un pool."
        next
      end

      puts "Job orfani: #{summary[:count]}"
      puts "Dal #{summary[:oldest_at]} al #{summary[:newest_at]}"
      summary[:queues].each { |queue, count| puts "  #{queue}: #{count}" }
      puts
      puts "Per rimuoverli: bin/rails jobs:orphans:delete CONFIRM=#{summary[:token]}"
    end

    desc "Rimuove i job orfani. Richiede CONFIRM=<numero atteso>"
    task delete: :environment do
      summary = Ops::OrphanRecurringJobs.summary
      expected = ENV["CONFIRM"].to_s

      if summary[:count].zero?
        puts "Niente da rimuovere."
        next
      end

      # La conferma è l'IMPRONTA dell'insieme, non il conteggio: due orfani diversi fanno comunque
      # "due", quindi un numero lascerebbe cancellare job diversi da quelli letti nel report. Con
      # l'impronta, se l'insieme è cambiato fra report e delete il comando si ferma.
      if expected != summary[:token]
        abort "L'elenco degli orfani non è quello che hai visto (impronta attuale " \
              "#{summary[:token]}, CONFIRM=#{expected.presence || '(vuoto)'}). " \
              "Rilancia `bin/rails jobs:orphans:report` e guarda cosa è cambiato."
      end

      puts "Rimuovo #{summary[:count]} job orfani (#{summary[:oldest_at]} → #{summary[:newest_at]})"
      puts "Code: #{summary[:queues].inspect}"

      # Si cancellano gli id di QUESTO riassunto, non un elenco ricalcolato: un orfano arrivato nel
      # frattempo non è fra quelli che il numero confermato descriveva.
      puts "Rimossi: #{Ops::OrphanRecurringJobs.delete!(job_ids: summary[:job_ids])}"
    end
  end
end
