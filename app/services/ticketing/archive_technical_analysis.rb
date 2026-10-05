# frozen_string_literal: true

module Ticketing
  # Rimette in ordine l'analisi tecnica di un ticket storico (CYRA-260): il testo integrale — quello
  # nel campo PIÙ quello finito nei commenti perché il campo era pieno — diventa un markdown allegato
  # al ticket, e nel campo resta una spiegazione che ci sta.
  #
  # SOSTITUISCE il campo invece di accodarsi, e non è una scorciatoia: il criterio con cui un
  # commento entra qui è proprio che il campo fosse SATURO (Ticketing::TechnicalAnalysisCandidates),
  # quindi nella quasi totalità dei casi lo spazio per accodare non esiste. Niente si perde: il testo
  # che c'era è la prima sezione dell'allegato, e la cronologia del ticket registra il cambio come
  # ogni altra modifica del corpo.
  #
  # Ordine delle operazioni: PRIMA l'allegato, POI il campo. Se il processo muore in mezzo, il
  # ticket ha un allegato in più e il campo intatto — ripetibile. Al contrario si perderebbe il testo.
  class ArchiveTechnicalAnalysis < ApplicationService
    # Server AI non configurato: non è un guasto di passaggio ma una cosa da sistemare, e il ripiego
    # sul troncamento la nasconderebbe (vedi #summarize).
    UNCONFIGURED_CODE = "R502-LLM-002"

    # fallback: ripiegare sul troncamento se il modello non risponde. Default FALSE, e la scelta sta
    # nel chiamante come in Ticketing::CompactCommentJob: ripiegare al primo errore vorrebbe dire
    # che un'AI spenta per dieci minuti lascia 62 analisi troncate per sempre — marcate come fatte,
    # quindi mai più riprese da un rilancio. Il job ci arriva solo all'ultimo tentativo.
    def initialize(ticket:, client: nil, fallback: false)
      @ticket = ticket
      @client = client
      @fallback = fallback
    end

    # => Result.ok(nil) se non c'era niente da fare, Result.ok(ticket) se ha archiviato.
    def call
      return Result.ok(nil) if @ticket.analysis_recomposed_at.present?

      groups = Ticketing::TechnicalAnalysisCandidates.call(ticket: @ticket)
      return Result.ok(nil) if groups.empty?

      # L'allegato si scrive comunque, anche se poi la spiegazione fallisce: mettere il testo al
      # sicuro non dipende dalla riuscita di una chiamata a un provider. Al tentativo dopo il
      # controllo sul nome lo trova già lì e non lo rifà.
      attach_markdown(groups)
      write_summary(groups)
    end

    private

    def attachment_name = "analisi-tecnica-#{@ticket.code}.md"

    # Il markdown è la fonte completa: prima quello che stava nel campo, poi i pezzi dai commenti in
    # ordine cronologico, ognuno con autore e data. VERBATIM — nessuna riscrittura, come la passata A
    # della compattazione: qui si sposta il testo di qualcuno, non lo si migliora.
    def markdown(groups)
      parts = [ "# Analisi tecnica — #{@ticket.code}", "", "> #{@ticket.title}", "" ]
      if @ticket.technical_analysis.present?
        parts += [ "## Dal campo del ticket", "", @ticket.technical_analysis, "" ]
      end
      groups.flatten.each do |comment|
        parts += [ "## #{comment.author&.name || I18n.t('ticketing.analysis_archive.unknown_author')} — " \
                   "#{I18n.l(comment.created_at.to_date, format: :long)}", "", comment.full_body, "" ]
      end
      parts.join("\n")
    end

    def attach_markdown(groups)
      return if @ticket.files.any? { |file| file.filename.to_s == attachment_name }

      @ticket.files.attach(
        io: StringIO.new(markdown(groups)),
        filename: attachment_name,
        content_type: "text/markdown"
      )
    end

    def write_summary(groups)
      body = full_text(groups)
      summary = summarize(body)
      # Err del modello e nessun ripiego concesso: NON si scrive e NON si marca il ticket, così il
      # tentativo dopo lo ritrova da fare. È la differenza fra un provider che ha un brutto minuto e
      # un'analisi troncata per sempre.
      return summary if summary.is_a?(Result)

      # Il tetto è già rispettato da SummarizeAnalysis (clamp incondizionato). Se nonostante quello
      # non ci sta, si ferma: meglio un ticket da guardare a mano che un'analisi tagliata a metà.
      return Result.err(too_long_error) if summary.length > Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS

      previous = Ticketing::EmbeddingText.checksum(ticket: @ticket)
      @ticket.update!(technical_analysis: summary, analysis_recomposed_at: Time.current)
      # Il re-embed non arriva da solo: qui non si passa da Ticketing::UpdateTicket, che è il posto
      # dove normalmente vive questa decisione.
      if Ticketing::EmbeddingText.checksum(ticket: @ticket) != previous
        Ticketing::EmbedTicketJob.perform_later(ticket_id: @ticket.id)
      end
      Result.ok(@ticket)
    end

    # => String da scrivere, oppure il Result.err da restituire al chiamante perché ritenti.
    #
    # Il ripiego vale sugli err — AI spenta dal god, quota finita, risposta vuota. NON quando il
    # server AI non è configurato (CYRA-765): quella è una configurazione da sistemare, e coprirla
    # con 62 troncamenti definitivi la renderebbe invisibile — i ticket resterebbero marcati come
    # fatti, quindi mai più ripresi da un rilancio.
    def summarize(body)
      result = Ticketing::SummarizeAnalysis.call(body: body, attachment_name: attachment_name,
                                                 organization: @ticket.project.organization_id, client: @client)
      return result.value if result.ok?
      return result unless @fallback
      return result if result.error.code == UNCONFIGURED_CODE

      # Il ripiego NON passa in silenzio: chi legge la scheda vedrebbe un testo che finisce con "…"
      # senza sapere se è una spiegazione o un taglio, e nessuno saprebbe quali ticket rivedere.
      # Stessa scelta del warning di Embeddings::EmbedText: il taglio si vede nei log.
      Rails.logger.warn("[analysis-archive] #{@ticket.code}: troncato invece di spiegato " \
                        "(#{result.error.code}) — il testo integrale è in #{attachment_name}")
      Ticketing::SummarizeAnalysis.fallback(body: body, attachment_name: attachment_name)
    end

    def full_text(groups)
      [ @ticket.technical_analysis.presence, *groups.flatten.map(&:full_body) ].compact.join("\n\n")
    end

    def too_long_error
      AppError.new(I18n.t("ticketing.analysis_archive.errors.too_long", code: @ticket.code),
                   code: "R422-ANALYSIS-001")
    end
  end
end
