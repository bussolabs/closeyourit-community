# frozen_string_literal: true

# Riscrittura delle analisi tecniche storiche nella forma a etichette (CYRA-266).
#
# La regola di knowledge-base/global/closeyourit-writing.md è arrivata dopo il testo: su 426 analisi
# in produzione 423 sono muri di prosa senza appigli, 134 sopra il bersaglio e 59 a ridosso del tetto.
# Qui ognuna viene riorganizzata in **Approccio:** / **Perché:** / **Rischi:** / **Aperto:**, senza
# aggiungere niente che non ci fosse.
#
#   bin/rails analysis_relabel:relabel                  # DRY RUN: cosa succederebbe, zero scritture
#   bin/rails 'analysis_relabel:relabel[20,sample]'     # chiama l'AI su 20 analisi e STAMPA il prima/dopo
#   bin/rails 'analysis_relabel:relabel[,apply]'        # esegue davvero, cadenzato
#   bin/rails 'analysis_relabel:relabel[50,apply]'      # limita a 50 ticket
#
# Le VIRGOLETTE attorno al task non sono decorative: in zsh le parentesi quadre sono un glob, e senza
# virgolette il comando muore con "no matches found" prima ancora di arrivare a Rails.
#
# Il default è `dry` come per comment_compaction, e per la stessa ragione: qui si RISCRIVE il testo
# scritto da qualcuno. Il `sample` esiste per scoprire un prompt sbagliato alla chiamata numero 5
# invece che alla 423.
#
# DA LANCIARE DOPO `comment_compaction:compact[,apply]`: la sua passata C riscrive il campo di una
# sessantina di ticket, e rietichettare prima significherebbe farlo due volte sugli stessi — la
# seconda su un testo che il modello ha appena scritto.
#
# Idempotente su due livelli: il ticket marcato (`analysis_relabeled_at`) non viene ripreso, e
# un'analisi già a etichette non arriva nemmeno al modello (Ticketing::RelabelAnalysis#skip?).
# I ticket con l'automazione in corso vengono saltati SENZA marcatura: li riprende il rilancio.
namespace :analysis_relabel do
  desc "Riscrive le analisi tecniche nella forma a etichette (modi: dry|sample|apply, default dry)"
  task :relabel, [ :limit, :mode ] => :environment do |_task, args|
    mode = args[:mode].presence || "dry"
    abort "Modo sconosciuto: #{mode} (attesi: dry, sample, apply)" unless %w[dry sample apply].include?(mode)

    target = Ticketing::Constants::TECHNICAL_ANALYSIS_TARGET_CHARS

    # La selezione vive in un PORO testabile (Ticketing::RelabelCandidates), non qui: è la decisione
    # che sbagliata salta ticket in silenzio, e un rake è il posto che nessuno testa.
    selection = Ticketing::RelabelCandidates.call(limit: args[:limit].presence&.to_i)
    workable = selection[:workable]
    locked = selection[:locked]
    candidates = workable + locked

    if candidates.empty?
      puts "Niente da fare: le analisi hanno già le etichette, o sono già state riscritte."
      next
    end

    over_target = workable.count { |t| t.technical_analysis.length > target }
    puts "#{candidates.size} analisi da riscrivere su #{candidates.map(&:project_id).uniq.size} progetti."
    puts "  lavorabili adesso: #{workable.size} (di cui #{over_target} oltre il bersaglio di #{target})"
    puts "  saltate, automazione in corso: #{locked.size}" if locked.any?

    case mode
    when "dry"
      workable.first(20).each do |ticket|
        puts format("  %-10s %5d char · %s…", ticket.code, ticket.technical_analysis.length,
                    ticket.technical_analysis.tr("\n", " ").truncate(60))
      end
      puts "  … e altre #{workable.size - 20}" if workable.size > 20
      puts "\nDRY RUN: nessuna scrittura, nessuna chiamata al modello. Rilancia con [,apply] per eseguire."
    when "sample"
      # Chiama il modello ma NON scrive: serve a leggere il prima/dopo prima di fidarsi.
      workable.first(args[:limit].presence&.to_i || 5).each do |ticket|
        result = Ticketing::RelabelAnalysis.call(body: ticket.technical_analysis,
                                                 organization: ticket.project.organization_id)
        puts "\n══ #{ticket.code} (#{ticket.technical_analysis.length} char)"
        puts "   PRIMA: #{ticket.technical_analysis.tr("\n", " ").truncate(200)}"
        puts "   DOPO:  #{result.value.to_s.tr("\n", " ").truncate(300)}" if result.ok?
        puts "   ERRORE: #{result.error.code} #{result.error.message}" if result.err?
      end
      puts "\nSAMPLE: nessuna scrittura. Leggi il prima/dopo qui sopra prima di lanciare [,apply]."
    when "apply"
      # Cadenzato come la compattazione, e per lo stesso motivo: il tetto non è il nostro throughput
      # ma il rate limit del provider.
      per_minute = Ticketing::Constants::COMMENT_COMPACTION_PER_MINUTE
      workable.each_with_index do |ticket, index|
        Ticketing::RelabelAnalysisJob.set(wait: (index / per_minute).minutes).perform_later(ticket_id: ticket.id)
      end
      puts "Accodate #{workable.size} riscritture su circa #{(workable.size.to_f / per_minute).ceil} " \
           "minuti (#{per_minute}/minuto per non saturare il rate limit)."
      puts "Saltate #{locked.size} in lavorazione: rilancia il task quando l'automazione è finita." if locked.any?
      puts "Freno d'emergenza: spegni 'la riscrittura delle analisi tecniche' in Valhalla → i job restanti escono senza scrivere."
    end
  end
end
