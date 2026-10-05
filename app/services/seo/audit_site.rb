# frozen_string_literal: true

module Seo
  # Un giro completo su un sito: visita, analizza, scrive. È il punto in cui i quattro servizi si
  # incontrano, e l'unico che sa cosa fare quando qualcosa va storto.
  #
  # Un giro fallito NON è un sito a posto: si registra come fallito, con il motivo, e non tocca i
  # rilievi esistenti. Il contrario — chiudere tutto perché non abbiamo visto niente — sarebbe una
  # bugia rassicurante, la peggiore specie di bugia in uno strumento di controllo.
  class AuditSite < ApplicationService
    def initialize(site:, now: Time.current, crawler: Seo::Crawl)
      @site = site
      @now = now
      @crawler = crawler
    end

    def call
      audit = @site.audits.create!(status: :running, started_at: @now)
      # CYRA-824 — «il controllo è partito» è già una notizia per chi ha la scheda aperta, ed è
      # l'unica onesta finché non c'è un esito: nessuna percentuale inventata, solo il giro che
      # compare in corso nella storia dei controlli.
      Seo::Broadcast.state(@site)
      crawl = @crawler.call(site: @site)

      return fail_audit(audit, crawl.error) if crawl.error.present?
      return fail_audit(audit, "no_pages") if crawl.pages.empty?

      candidates = Seo::Analyze.call(crawl:, site: @site)
      report = Seo::RecordAudit.call(site: @site, audit:, crawl:, candidates:, now: @now)
      finish(last_error: nil)
      # Dopo la scrittura, mai durante: un guasto dell'alerting non deve far perdere il giro.
      Seo::NotifyIssues.call(issues: report.opened)
      report
    rescue StandardError => e
      fail_audit(audit, e.class.name.demodulize.underscore) if audit
      raise
    end

    private

    def fail_audit(audit, error)
      audit.update!(status: :failed, finished_at: @now, error: error)
      finish(last_error: error)
      nil
    end

    # La prossima scadenza si scrive comunque, anche dopo un fallimento: senza, un sito che non
    # risponde verrebbe ritentato a ogni giro del dispatcher, cioè ogni ora, per sempre.
    #
    # È anche il punto in cui il giro è FINITO davvero, riuscito o fallito che sia, e tutto ciò che
    # la scheda mostra è già scritto: rilievi, pagine ed esito sono stati committati da RecordAudit,
    # e qui si chiude la riga del sito. Il segnale parte da dopo, mai da dentro la transazione —
    # chi lo riceve va a rileggere, e leggerebbe uno stato che non c'è ancora (CYRA-824).
    def finish(last_error:)
      @site.update!(last_audited_at: @now, next_audit_at: @site.next_audit_after(@now), last_error:)
      Seo::Broadcast.state(@site)
    end
  end
end
