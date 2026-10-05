# frozen_string_literal: true

# Compattazione dei commenti storici (CYRA-222).
#
# I resoconti di lavorazione finivano dentro i commenti: 562 su 587 superano i 240 caratteri. Qui il
# testo integrale diventa una versione del resoconto (passata A, deterministica) e il commento
# diventa un riassunto entro il tetto (passata B, con l'AI).
#
# Passata C (CYRA-260): nei commenti non c'erano solo resoconti. Su 62 ticket c'è finita l'ANALISI
# TECNICA, spinta fuori dal campo perché il campo era pieno — tutti quei ticket hanno
# technical_analysis fra 1.383 e 1.491 caratteri su un tetto di 1.500, e i commenti si aprono con
# "ANALISI TECNICA ESTESA (il campo dedicato ha un limite di 1500 caratteri)". Lì il testo integrale
# diventa un markdown allegato al ticket e nel campo resta una spiegazione che ci sta.
#
#   bin/rails comment_compaction:compact                # DRY RUN: cosa succederebbe, zero scritture
#   bin/rails comment_compaction:compact[20,sample]     # chiama l'AI su 20 commenti e STAMPA i riassunti
#   bin/rails comment_compaction:compact[,apply]        # esegue davvero (A subito, B cadenzata)
#   bin/rails comment_compaction:compact[50,apply]      # limita a 50 commenti
#
# Il default è `dry` — a differenza di agent_eligibility:backfill che agisce subito. La differenza è
# che lì si scrive un verdetto in un campo vuoto, qui si RISCRIVE il testo scritto da qualcuno.
#
# `sample` esiste per scoprire un prompt sbagliato alla chiamata numero 5 invece che alla 400: chiama
# il modello davvero, stampa gli accostamenti originale/riassunto e non scrive niente.
#
# PRIMA DI `apply` IN PRODUZIONE: la sezione Resoconto deve essere già online, altrimenti la passata A
# sposta il testo in un posto che nessuno può leggere e la B fa puntare 562 commenti a una pagina che
# darebbe 404.
#
# Idempotente: la passata A non può duplicare (indice unico su source_comment_id), la B salta i
# commenti con compacted_at, e il job ricontrolla entrambe le guardie all'esecuzione.
namespace :comment_compaction do
  desc "Sposta i commenti lunghi nei resoconti e li riassume (modi: dry|sample|apply, default dry)"
  task :compact, [ :limit, :mode ] => :environment do |_task, args|
    mode = args[:mode].presence || "dry"
    abort "Modo sconosciuto: #{mode} (attesi: dry, sample, apply)" unless %w[dry sample apply].include?(mode)

    max = Ticketing::Constants::COMMENT_MAX_CHARS
    scope = Ticketing::Comment.where(compacted_at: nil).where("length(body) > ?", max)
                              .includes(ticket: :project).order(:created_at)
    scope = scope.limit(args[:limit].to_i) if args[:limit].present?
    comments = scope.to_a

    # Passata C (CYRA-260), perimetro calcolato a parte e PRIMA di uscire: quella scope qui sopra
    # guarda `compacted_at` e `body`, che dopo la passata B sono "già fatto" e "riassunto". Un
    # rilancio a compattazione finita — il caso normale se si archivia in un secondo momento —
    # troverebbe zero commenti e uscirebbe senza archiviare niente. Qui si misura il testo VERO.
    archivable = Ticketing::Ticket
                 .where(analysis_recomposed_at: nil)
                 .where(id: Ticketing::Comment.where("length(COALESCE(NULLIF(original_body, ''), body)) > ?", max)
                                              .select(:ticket_id))
                 .includes(:comments, :project)
                 .select { |ticket| Ticketing::TechnicalAnalysisCandidates.call(ticket: ticket).any? }

    # Fino al CYRA-765 qui si scartavano le organizzazioni senza il servizio collegato: l'AI la offre
    # ora il sistema, quindi non c'è più niente da collegare e il perimetro è quello di sopra.
    if comments.empty? && archivable.empty?
      puts "Niente da fare: i commenti stanno tutti entro i #{max} caratteri e non c'è analisi da archiviare."
      next
    end

    question_ids = Agents::Clarification.where(question_comment_id: comments.map(&:id))
                                        .pluck(:question_comment_id)
    shapes = comments.to_h { |c| [ c.id, Ticketing::CommentShape.call(comment: c, question_comment_ids: question_ids) ] }
    reports = comments.count { |c| shapes[c.id] == :report }
    questions = comments.count { |c| shapes[c.id] == :question }

    puts "#{comments.size} commenti oltre #{max} caratteri su #{comments.map(&:ticket_id).uniq.size} ticket."
    puts "  resoconti (→ versione del resoconto + riassunto): #{reports}"
    puts "  domande di chiarimento (→ solo riassunto, restano nel loro record): #{questions}"
    puts "  analisi tecnica da riportare nella scheda (→ markdown allegato + spiegazione): #{archivable.size} ticket"

    case mode
    when "dry"
      comments.first(20).each do |comment|
        puts format("  [%-8s] %s… (%d char, ticket %s)", shapes[comment.id],
                    comment.body.to_s.tr("\n", " ").truncate(70), comment.body.to_s.length, comment.ticket_id)
      end
      puts "  … e altri #{comments.size - 20}" if comments.size > 20
      archivable.first(20).each do |ticket|
        groups = Ticketing::TechnicalAnalysisCandidates.call(ticket: ticket)
        chars = groups.flatten.sum { |c| c.full_body.to_s.length }
        puts format("  [analisi ] %-10s %d gruppi, %d char → allegato (campo attuale: %d char)",
                    ticket.code, groups.size, chars, ticket.technical_analysis.to_s.length)
      end
      puts "  … e altri #{archivable.size - 20} ticket con analisi da archiviare" if archivable.size > 20
      puts "\nDRY RUN: nessuna scrittura, nessuna chiamata al modello. Rilancia con [,apply] per eseguire."
    when "sample"
      # Chiama il modello ma NON scrive: serve a leggere i riassunti prima di fidarsi.
      comments.each do |comment|
        version = Ticketing::Report.find_by(source_comment_id: comment.id)&.version
        result = Ticketing::SummarizeComment.call(body: comment.body, report_version: version,
                                                  organization: comment.ticket.project.organization_id)
        puts "\n── #{comment.id} (#{comment.body.to_s.length} char)"
        puts "   ORIGINALE: #{comment.body.to_s.tr("\n", " ").truncate(160)}"
        puts(result.ok? ? "   RIASSUNTO: #{result.value}" : "   ERRORE: #{result.error.code} #{result.error.message}")
      end
      # Stesso assaggio per la passata C: il prompt della spiegazione va letto prima di lanciarlo su
      # 62 ticket, esattamente come quello dei riassunti.
      archivable.first(args[:limit].presence&.to_i || 5).each do |ticket|
        groups = Ticketing::TechnicalAnalysisCandidates.call(ticket: ticket)
        body = [ ticket.technical_analysis.presence, *groups.flatten.map(&:full_body) ].compact.join("\n\n")
        result = Ticketing::SummarizeAnalysis.call(body: body, attachment_name: "analisi-tecnica-#{ticket.code}.md",
                                                   organization: ticket.project.organization_id)
        puts "\n══ #{ticket.code} (#{body.length} char da spiegare)"
        puts(result.ok? ? "   SPIEGAZIONE: #{result.value.tr("\n", " ")}" : "   ERRORE: #{result.error.code} #{result.error.message}")
      end
      puts "\nSAMPLE: nessuna scrittura. Leggi i riassunti qui sopra prima di lanciare [,apply]."
    when "apply"
      # Passata A per ticket, subito e senza modello: il testo integrale va al sicuro adesso, non fra
      # settanta minuti e non dipendendo dalla riuscita di 562 chiamate a un provider.
      versions = 0
      Ticketing::Ticket.where(id: comments.map(&:ticket_id).uniq).find_each do |ticket|
        versions += Ticketing::MigrateCommentsToReports.call(ticket: ticket).value.size
      end
      puts "Passata A: create #{versions} versioni di resoconto (testo integrale al sicuro)."

      # Passata B cadenzata: vedi COMMENT_COMPACTION_PER_MINUTE per il perché del ritmo.
      per_minute = Ticketing::Constants::COMMENT_COMPACTION_PER_MINUTE
      comments.each_with_index do |comment, index|
        Ticketing::CompactCommentJob.set(wait: (index / per_minute).minutes).perform_later(comment_id: comment.id)
      end
      puts "Passata B: accodati #{comments.size} riassunti su circa #{(comments.size.to_f / per_minute).ceil} " \
           "minuti (#{per_minute}/minuto per non saturare il rate limit)."

      # Passata C (CYRA-260) accodata DOPO la B e con la sua coda di attesa: le due chiamano lo stesso
      # provider, e sommare i ritmi vorrebbe dire raddoppiare le richieste al minuto. L'ordine di
      # esecuzione fra le due resta comunque indifferente (Ticketing::Comment#full_body).
      offset = (comments.size.to_f / per_minute).ceil
      archivable.each_with_index do |ticket, index|
        Ticketing::ArchiveAnalysisJob
          .set(wait: (offset + (index / per_minute)).minutes)
          .perform_later(ticket_id: ticket.id)
      end
      puts "Passata C: accodate #{archivable.size} analisi da archiviare, a partire da fra #{offset} minuti."
      puts "Freno d'emergenza: spegni 'il riassunto dei commenti storici' in Valhalla → i job restanti escono senza scrivere."
    end
  end
end
