# frozen_string_literal: true

module Ticketing
  # Registra il resoconto di lavorazione di un ticket (CYRA-220). Un resoconto non si modifica: se il
  # ticket ne ha già uno, questo ne scrive la versione successiva e la precedente resta leggibile.
  #
  # Idempotenza SERVER-side, non a carico del chiamante: ripostare lo stesso identico testo non crea
  # una versione nuova, ritorna quella corrente. È l'unica regola che copre insieme CLI, web e la
  # migrazione dei vecchi commenti — l'alternativa (far controllare al chiamante se ha già postato,
  # come fa oggi deliver.sh grepando i commenti) va riscritta in ogni chiamante e si dimentica.
  # Attenzione: identico al CORRENTE, non a una versione qualsiasi. Tornare a una stesura precedente
  # è un cambiamento reale e merita la sua versione.
  class RecordReport < ApplicationService
    def initialize(ticket:, author:, body:, source: :manual)
      @ticket = ticket
      @author = author
      @body = body
      @source = source
    end

    def call
      return Result.ok(current) if unchanged?

      report = @ticket.reports.new(body: @body, author: @author, source: @source)
      return invalid(report) unless report.save

      announce(report)
      Result.ok(report)
    end

    private

    # `reorder`, non `order`: l'associazione ha già `order(:version)` ascendente e un secondo `order`
    # ci si ACCODA invece di sostituirlo (ORDER BY version ASC, version DESC → vince l'ASC), che
    # restituirebbe la versione 1 spacciandola per la corrente.
    def current
      @current ||= @ticket.reports.reorder(version: :desc).first
    end

    # Confronto fra valori NORMALIZZATI: il corrente è già passato dal normalizes del model, il testo
    # in arrivo no. Misurare un lato grezzo e uno normalizzato farebbe nascere una versione nuova per
    # un CRLF o uno spazio in coda — cioè per niente.
    def unchanged?
      return false if current.blank?

      Ticketing::Report.normalize_value_for(:body, @body) == current.body
    end

    # La riga in discussione dice SOLO che il resoconto è cambiato: il testo sta nel resoconto. Nasce
    # dopo il save del resoconto e in una chiamata separata — se fallisse la notifica, il resoconto è
    # comunque salvo, che è l'ordine di importanza giusto.
    #
    # Una versione nata da un respingimento ha la sua riga (CYRA-389): "resoconto aggiornato alla
    # versione 3" farebbe credere che qualcuno abbia raccontato altro lavoro fatto, mentre quello che
    # c'è da leggere è il motivo per cui il lavoro torna indietro.
    def announce(report)
      comment = @ticket.comments.create(
        body: I18n.t("ticketing.reports.service_line.#{service_line_key(report)}", version: report.version),
        author: @author, kind: :service
      )
      Ticketing::BroadcastComment.call(comment: comment) if comment.persisted?
    end

    def service_line_key(report)
      return "review_rejection" if report.source_review_rejection?

      report.version == 1 ? "created" : "updated"
    end

    # Messaggio i18n dedicato (non i full_messages grezzi: evita "translation missing" nel flash).
    # I dettagli per-campo restano in details, che è ciò che la CLI stampa.
    def invalid(report)
      Result.err(AppError.new(I18n.t("ticketing.reports.errors.invalid"),
                              code: "R422-REPORT-001", details: report.errors.to_hash))
    end
  end
end
