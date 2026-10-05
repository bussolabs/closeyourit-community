# frozen_string_literal: true

module Ticketing
  # Quali commenti storici sono, in realtà, l'analisi tecnica del ticket finita nel posto sbagliato
  # (CYRA-260). Ritorna gruppi di commenti in ordine cronologico: un gruppo è UN testo solo, spezzato
  # in più righe perché non entrava.
  #
  # PORO puro e senza scritture, come Ticketing::CommentShape — che NON estende: lì si decide dove
  # finisce un commento nella compattazione (resoconto o domanda), qui si decide se quel testo è anche
  # la coda dell'analisi tecnica. Le due risposte convivono: un commento può diventare versione del
  # resoconto E alimentare il campo analisi, e classificare male qui aggiunge testo, non lo sposta.
  #
  # IL SEGNALE È IL CONTESTO, NON LO STILE. Provato e scartato un punteggio per densità di parole
  # tecniche: sui dati veri classificava come non-analisi commenti che si aprono con "## Causa — su
  # Dart il trace_id non veniva propagato", perché quasi ogni resoconto di lavorazione parla di file e
  # di classi. Ciò che distingue davvero la coda di un'analisi è che il campo dell'analisi ERA PIENO
  # quando quel commento è stato scritto (vedi ANALYSIS_SATURATION_RATIO), oppure che il commento lo
  # dichiara da sé in apertura.
  class TechnicalAnalysisCandidates < ApplicationService
    # L'apertura con cui chi scriveva annunciava che stava continuando fuori dal campo. Ancorata
    # all'INIZIO del testo: "come da analisi tecnica del ticket" a metà di un resoconto di rilascio è
    # una citazione, non una continuazione, e prenderla porterebbe nel campo il testo sbagliato.
    DECLARED = /\A[^\n]{0,140}?(
      analisi\ tecnica\ estesa | analisi\ estesa | dettaglio\ tecnico | design\ implementativo |
      approfondimento\ tecnico | nota\ tecnica | (?:dettagli|testo)\ che\ non\ (?:stavano|entrava) |
      segue\ (?:l')?analisi | segue\ technical_analysis
    )/xi

    def initialize(ticket:)
      @ticket = ticket
    end

    # => [[Comment, Comment], [Comment]] — vuoto se il ticket non ha niente da recuperare.
    def call
      return [] if long_comments.empty?

      grouped.select { |group| analysis?(group) }
    end

    private

    # Solo i commenti oltre il tetto: sotto, il testo è già dove deve stare e non c'è niente da
    # spostare. Fuori le righe di servizio scritte dall'app e le domande di chiarimento, che hanno già
    # casa nelle righe di primo livello (stessa esclusione di MigrateCommentsToReports).
    def long_comments
      @long_comments ||= begin
        comments = @ticket.comments.order(:created_at).reject do |comment|
          comment.full_body.to_s.length <= Ticketing::Constants::COMMENT_MAX_CHARS || comment.kind_service?
        end
        # Una query sola per ticket, non una per commento, e solo sui commenti rimasti.
        question_ids = Agents::Clarification.where(question_comment_id: comments.map(&:id))
                                            .pluck(:question_comment_id)
        comments.reject { |comment| question_ids.include?(comment.id) }
      end
    end

    # Consecutivi, stesso autore, entro la finestra: è così che si presenta un testo tagliato in due.
    def grouped
      long_comments.each_with_object([]) do |comment, groups|
        last = groups.last&.last
        if last && last.author_id == comment.author_id &&
           comment.created_at - last.created_at <= Ticketing::Constants::ANALYSIS_RECOMPOSE_WINDOW
          groups.last << comment
        else
          groups << [ comment ]
        end
      end
    end

    def analysis?(group)
      saturated? || group.first.full_body.to_s.match?(DECLARED)
    end

    # "Il campo era pieno": si misura su quello che c'è ADESSO. È un'approssimazione consapevole — il
    # campo potrebbe essere stato riscritto dopo — ma nell'unica direzione innocua: un campo oggi
    # pieno che allora era vuoto fa prendere un commento in più, e il testo integrale finisce
    # comunque in allegato senza sovrascrivere niente.
    def saturated?
      return @saturated if defined?(@saturated)

      threshold = Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS *
               Ticketing::Constants::ANALYSIS_SATURATION_RATIO
      @saturated = @ticket.technical_analysis.to_s.strip.length >= threshold
    end
  end
end
