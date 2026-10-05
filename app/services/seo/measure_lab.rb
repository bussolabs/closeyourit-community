# frozen_string_literal: true

module Seo
  # Una misura di velocità su un sito, per una strategia (CYRA-539). È il gemello di `AuditSite`:
  # l'unico punto che sa cosa fare quando qualcosa va storto.
  #
  # La riga nasce `running` PRIMA della chiamata: un worker ucciso a metà lascia una riga visibile
  # invece del nulla. Qualsiasi guasto la porta a `failed` con il motivo, e la riga riuscita
  # precedente non si tocca MAI — la scheda mostra i numeri buoni di prima dicendo che sono vecchi.
  # Cancellarli perché l'ultimo tentativo è andato male sarebbe perdere l'unica cosa che sappiamo.
  #
  # LA CHIAVE È DELL'ORGANIZZAZIONE DEL SITO (CYRA-546), risolta qui e non passata da chi chiama: è
  # l'unico dato da cui si possa ricavare chi paga questa misura, e ricavarlo altrove aprirebbe la
  # porta a misurare il sito di uno con la chiave di un altro.
  class MeasureLab < ApplicationService
    def initialize(site:, strategy:, now: Time.current,
                   client: Seo::PageSpeed::Client.for(organization: site.project.organization_id))
      @site = site
      @strategy = strategy.to_s
      @now = now
      @client = client
    end

    def call
      # Senza collegamento non si misura e non si lascia traccia. Ci si arriva solo se la chiave è
      # sparita fra l'accodamento e l'esecuzione — il dispatcher salta già chi non l'ha collegata —
      # e una riga fallita racconterebbe una configurazione, non il sito. La scadenza NON si sposta:
      # così il sito riparte da sé appena la chiave torna, invece di aspettare un altro giro.
      return if @client.nil?

      run = @site.lab_runs.create!(strategy: @strategy, status: :running, url: @site.base_url,
                                   started_at: @now)
      response = @client.run(url: @site.base_url, strategy: @strategy)
      complete(run, Seo::PageSpeed::Parse.call(response))
    rescue Seo::PageSpeed::Client::Error => e
      # La quota finita vale per tutti i siti di QUESTA organizzazione, non per questo sito soltanto:
      # si alza l'interruttore così il dispatcher smette di accodare invece di produrre una riga
      # fallita per ogni suo sito. Le altre organizzazioni non ne sanno niente: pagano con un'altra
      # chiave e la loro quota è intatta.
      raise_quota_flag if e.reason == "quota_exceeded"
      fail_run(run, e.reason)
    rescue StandardError => e
      fail_run(run, e.class.name.demodulize.underscore)
      raise
    end

    private

    def complete(run, attrs)
      run.update!(attrs.merge(status: :completed, finished_at: Time.current))
      finish(last_error: nil)
      run
    end

    def fail_run(run, reason)
      run&.update!(status: :failed, finished_at: Time.current, error: reason)
      finish(last_error: reason)
      nil
    end

    # La prossima scadenza si scrive comunque, anche dopo un fallimento: senza, un sito che Google
    # non raggiunge verrebbe ritentato a ogni giro del dispatcher, cioè ogni ora, per sempre.
    #
    # Qui la misura è chiusa e scritta, quindi è anche il momento in cui la scheda velocità ha
    # qualcosa di nuovo da dire a chi la sta guardando (CYRA-824) — compreso il caso in cui non è
    # riuscita: i numeri che restano in pagina sono quelli del giro precedente, e il riquadro
    # ricaricato lo dice invece di farli passare per freschi.
    def finish(last_error:)
      @site.update!(last_lab_run_at: @now, next_lab_run_at: @site.next_lab_run_after(@now),
                    last_lab_error: last_error)
      Seo::Broadcast.state(@site)
    end

    def raise_quota_flag
      key = Seo::PageSpeed::Constants.quota_exhausted_key(@site.project.organization_id)
      Rails.cache.write(key, true, expires_in: Seo::PageSpeed::Constants::QUOTA_EXHAUSTED_TTL)
    end
  end
end
