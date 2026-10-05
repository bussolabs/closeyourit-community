# frozen_string_literal: true

module Seo
  # Scrive l'esito del giro: aggiorna lo stato delle pagine e mette in pari i rilievi.
  #
  # Il cuore è il confronto fra ciò che il giro ha trovato e ciò che era già aperto:
  # - candidato nuovo            → si apre il rilievo;
  # - candidato già noto         → si riconferma (data e prova aggiornate, stato intatto);
  # - rilievo aperto non trovato → si chiude da solo, perché il problema non c'è più.
  #
  # Un rilievo `ignored` non partecipa: non si riapre e non si richiude. Chi ha deciso di
  # conviverci ha già dato la sua risposta, e ridargliela ogni giorno sarebbe solo rumore.
  #
  # La terza riga di quell'elenco pretende una condizione che non si vede a occhio: che il giro
  # abbia DAVVERO potuto guardare (CYRA-808). Un rilievo non ritrovato su una pagina andata in
  # timeout non è sparito, è solo smesso di osservare — e chiuderlo farebbe migliorare l'elenco dei
  # problemi proprio quando il controllo peggiora.
  class RecordAudit < ApplicationService
    Report = Data.define(:opened, :reconfirmed, :resolved, :pages_count, :open_count,
                         :unverified_count)

    def initialize(site:, audit:, crawl:, candidates:, now: Time.current)
      @site = site
      @audit = audit
      @crawl = crawl
      @candidates = candidates
      @now = now
    end

    def call
      ActiveRecord::Base.transaction do
        pages_by_url = upsert_pages
        opened, reconfirmed = sync_issues(pages_by_url)
        resolved = close_disappeared(opened + reconfirmed, pages_by_url)
        open_count = @site.issues.status_open.count
        unverified_count = unread_pages.size

        @audit.update!(status: :completed, finished_at: @now, pages_count: pages_by_url.size,
                       issues_open_count: open_count, pages_unverified_count: unverified_count)

        Report.new(opened:, reconfirmed:, resolved:, pages_count: pages_by_url.size, open_count:,
                   unverified_count:)
      end
    end

    private

    def upsert_pages
      @crawl.pages.each_with_object({}) do |page, acc|
        record = @site.pages.find_or_initialize_by(url: page[:url])
        record.first_seen_at ||= @now
        record.assign_attributes(page_attributes(page))
        record.save!
        acc[page[:url]] = record
      end
    end

    def page_attributes(page)
      base = {
        path: page[:path],
        status_code: page[:status_code],
        redirect_chain: page[:redirect_chain],
        response_time_ms: page[:response_time_ms],
        in_sitemap: page[:in_sitemap],
        discovered_from: page[:discovered_from],
        last_seen_at: @now
      }
      attributes = page[:attributes]
      return base if attributes.blank?

      base.merge(
        title: attributes[:title],
        meta_description: attributes[:meta_description],
        canonical_url: attributes[:canonical_url],
        robots_directives: attributes[:robots_directives],
        hreflangs: attributes[:hreflangs],
        lang: attributes[:lang],
        h1s: attributes[:h1s],
        h2_count: attributes[:h2_count],
        word_count: attributes[:word_count],
        jsonld_types: attributes[:jsonld_types],
        images_total: attributes[:images_total],
        images_without_alt: attributes[:images_without_alt],
        internal_links_count: attributes[:internal_links].size,
        external_links_count: attributes[:external_links_count],
        html_bytes: attributes[:html_bytes]
      )
    end

    def sync_issues(pages_by_url)
      existing = @site.issues.index_by { |issue| [ issue.check_key, issue.page_id ] }
      opened = []
      reconfirmed = []

      @candidates.each do |candidate|
        page = candidate.url && pages_by_url[candidate.url]
        key = [ candidate.check_key, page&.id ]
        severity = Seo::Check.find(candidate.check_key)&.severity || :medium

        if (issue = existing[key])
          issue.touch_seen!(@now, candidate.evidence, severity)
          reconfirmed << issue
        else
          opened << @site.issues.create!(page:, check_key: candidate.check_key, severity:,
                                         evidence: candidate.evidence, first_seen_at: @now,
                                         last_seen_at: @now)
        end
      end

      [ opened, reconfirmed ]
    end

    # Chiude ciò che il giro non ha più trovato — ma solo dove ha davvero guardato, e solo per i
    # controlli che ha davvero potuto eseguire.
    #
    # Due filtri, e sono due domande diverse:
    #
    # 1. ABBIAMO APERTO QUESTA PAGINA? Restano intoccati i rilievi di pagine che stavolta non sono
    #    finite nel giro: col tetto di `max_pages` o un menu cambiato una pagina può semplicemente
    #    non essere stata visitata. Per la stessa ragione, un giro senza pagine non chiude niente.
    #
    # 2. SIAMO ARRIVATI ABBASTANZA IN FONDO PER DIRLO? È la parte che mancava (CYRA-808). Una
    #    pagina in timeout, vietata da robots.txt o che risponde con un PDF finisce comunque in
    #    elenco, con `attributes` nulli: i controlli sul contenuto non producono candidati, e senza
    #    questo filtro l'assenza del candidato veniva letta come «problema sparito». Il risultato
    #    era che l'elenco migliorava proprio nel giro in cui non si è visto niente.
    #    Ogni controllo dichiara in `Seo::Check#needs` quanto serve per potersi dire eseguito, e il
    #    confronto è col livello raggiunto SU QUELLA pagina. I rilievi d'insieme (page_id nullo) si
    #    misurano sul giro intero: basta una pagina letta perché un confronto fra pagine torni
    #    possibile.
    #
    # Solo i rilievi APERTI: un ignorato resta ignorato (non gli si cambia stato alle spalle) e un
    # già risolto non si tocca.
    def close_disappeared(seen_issues, pages_by_url)
      return [] if pages_by_url.empty?

      seen_ids = seen_issues.map(&:id).to_set
      levels = observation_levels(pages_by_url)

      stale = @site.issues.status_open
                   .where(page_id: levels.keys)
                   .reject { |issue| seen_ids.include?(issue.id) }
                   .select { |issue| verified?(issue, levels) }
      stale.each { |issue| issue.update!(status: :resolved, resolved_at: @now) }
    end

    # `page_id` → fin dove siamo arrivati su quella pagina, più `nil` → fin dove è arrivato il giro
    # (il massimo fra le pagine: i controlli d'insieme confrontano le pagine fra loro, e una sola
    # letta basta a renderli di nuovo possibili).
    def observation_levels(pages_by_url)
      levels = @crawl.pages.each_with_object({}) do |page, acc|
        record = pages_by_url[page[:url]]
        acc[record.id] = page[:observation] if record
      end
      levels[nil] = Seo::Check.richest_observation(levels.values)
      levels
    end

    def verified?(issue, levels)
      check = Seo::Check.find(issue.check_key) || Seo::Check.new(issue.check_key)
      check.verifiable_with?(levels[issue.page_id])
    end

    # Le pagine che il giro ha toccato senza riuscire a leggerle: è il numero che rende onesto
    # `pages_count`. Dieci pagine "viste" di cui otto mute somigliano a un giro pieno, e un elenco
    # di problemi che non scende sembrerebbe un guasto invece dell'unica risposta onesta.
    def unread_pages
      @crawl.pages.select { |page| Seo::Check.observation(page[:observation]) == :attempted }
    end
  end
end
