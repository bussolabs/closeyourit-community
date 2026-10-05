# frozen_string_literal: true

# Backfill del gate di eleggibilità agenti (CYRA-184).
#
# Il gate è fail-closed: al deploy TUTTI i ticket preesistenti sono `pending`, quindi la coda degli
# agenti resta ferma finché questo task non popola i verdetti. Va lanciato NELLO STESSO rilascio che
# introduce il gate, non come seguito. Va RILANCIATO anche a ogni bump di
# Ticketing::AgentEligibilityText::PROMPT_VERSION, che rende stale l'intero parco (già valutato
# compreso) e ne impone la rivalutazione col prompt nuovo.
#
#   bin/rails agent_eligibility:backfill              # solo i ticket aperti (default)
#   bin/rails agent_eligibility:backfill[100]         # limita il numero di ticket accodati
#   bin/rails agent_eligibility:backfill[,all]        # anche quelli in lavorazione
#
# Di default tocca SOLO la categoria `open`: i ticket già in lavorazione hanno qualcuno addosso, e
# valutarli costa una chiamata al modello per un caso che non è il backlog da smistare. `all`
# estende ai non chiusi (scelta al primo backfill in produzione, 2026-07-29: 169 open contro 307
# non chiusi).
#
# Idempotente rispetto alle chiamate al modello: accoda i ticket la cui valutazione è STALE — mai
# valutati, corpo/allegati cambiati, o PROMPT_VERSION bumpata — e il job ri-controlla la guardia
# prima di spendere una chiamata. Dopo un bump del prompt questo ripesca anche i ticket GIÀ
# allowed/blocked, non solo quelli senza checksum: senza, i falsi verdetti della versione precedente
# resterebbero attivi per sempre. Le decisioni umane restano escluse (agent_eligibility_stale? le
# salta: sticky). Attenzione: rilanciarlo MENTRE la coda si sta ancora smaltendo ri-accoda gli stessi
# ticket (i job in eccesso escono sulla guardia, quindi non costano chiamate — solo voci di coda). A
# parco tutto valutato e fresco non accoda nulla.
namespace :agent_eligibility do
  desc "Accoda la (ri)valutazione di eleggibilità agenti per i ticket con verdetto stale (scope: open|all)"
  task :backfill, [ :limit, :scope ] => :environment do |_task, args|
    categories = Types::TicketStatus.categories
    scope = Ticketing::Ticket.joins(:status)
    scope = if args[:scope].to_s == "all"
      scope.where.not(types_ticket_statuses: { category: categories.fetch("done") })
    else
      scope.where(types_ticket_statuses: { category: categories.fetch("open") })
    end
    limit = args[:limit].presence&.to_i

    total = 0
    scope.find_each do |ticket|
      # Accoda SOLO i ticket la cui valutazione automatica è da rifare (mai valutati, contenuto
      # cambiato, o PROMPT_VERSION bumpata): è ciò che, dopo un bump del prompt, rivaluta anche i
      # ticket GIÀ allowed/blocked. Il predicato salta le decisioni umane (sticky). La staleness si
      # legge in Ruby perché il checksum è un SHA calcolato lato app, non filtrabile in SQL.
      next unless ticket.agent_eligibility_stale?

      # CADENZATO, e non è un dettaglio: al primo backfill reale 169 job partiti insieme hanno
      # saturato il rate limit del fornitore di allora in pochi secondi — 327 esecuzioni fallite con
      # un rate limit e appena 7 verdetti prodotti. Un backfill che chiama un LLM deve
      # auto-limitarsi, altrimenti fa un denial of service a se stesso e i retry lo peggiorano.
      # Il fail-closed regge (nessun ticket diventa lavorabile per errore) ma il lavoro non si fa.
      wait = (total / Ticketing::Constants::AGENT_ELIGIBILITY_BACKFILL_PER_MINUTE).minutes
      Ticketing::EvaluateAgentEligibilityJob.set(wait: wait).perform_later(ticket_id: ticket.id)
      total += 1
      break if limit && total >= limit
    end

    minutes = (total.to_f / Ticketing::Constants::AGENT_ELIGIBILITY_BACKFILL_PER_MINUTE).ceil
    puts "Accodata la valutazione per #{total} ticket, distribuita su circa #{minutes} minuti " \
         "(#{Ticketing::Constants::AGENT_ELIGIBILITY_BACKFILL_PER_MINUTE}/minuto per non saturare il rate limit)."
    puts "I ticket chiusi restano 'da valutare': non entrano nella coda agenti, quindi non serve." if total.positive?
  end
end
