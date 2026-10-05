# frozen_string_literal: true

module Seo
  # La visita: dalla home e dalla sitemap fino al tetto di pagine, seguendo solo i link interni.
  # Ritorna fatti grezzi — una riga per pagina più ciò che si vede solo dall'alto (sitemap
  # raggiungibile, robots raggiungibile) — e nessun giudizio: quelli li dà Seo::Analyze.
  #
  # Tre vincoli che non sono negoziabili, perché il sito visitato non è nostro:
  # 1. robots.txt si rispetta, sempre;
  # 2. si resta sullo stesso host: un link verso l'esterno si conta, non si segue;
  # 3. c'è un tetto di pagine e una pausa fra le richieste.
  class Crawl < ApplicationService
    # Mezzo secondo fra una richiesta e l'altra: su un sito piccolo è impercettibile, su uno grande
    # è la differenza fra una visita e un piccolo attacco. Sequenziale di proposito — la
    # concorrenza qui guadagnerebbe minuti e costerebbe la fiducia di chi ospita il sito.
    REQUEST_PAUSE = 0.5

    Result = Data.define(:pages, :sitemap_urls, :sitemap_reachable, :robots_reachable, :error) do
      def initialize(pages: [], sitemap_urls: [], sitemap_reachable: true, robots_reachable: true, error: nil)
        super
      end
    end

    def initialize(site:, fetcher: Seo::Fetch, pause: REQUEST_PAUSE)
      @site = site
      @fetcher = fetcher
      @pause = pause
    end

    def call
      robots = load_robots
      sitemap = load_sitemap(robots)
      seeds = build_seeds(sitemap.urls)

      pages = visit(seeds, robots, sitemap.urls.to_set)

      Result.new(pages:, sitemap_urls: sitemap.urls, sitemap_reachable: sitemap.reachable,
                 robots_reachable: @robots_reachable)
    rescue StandardError => e
      Result.new(error: e.class.name.demodulize.underscore)
    end

    private

    def base_uri = URI.parse(@site.base_url)

    def load_robots
      response = @fetcher.call(url: "#{@site.base_url}/robots.txt")
      @robots_reachable = response.ok?
      # Un robots.txt assente non vieta niente: è così che si comportano i motori veri.
      response.ok? ? Seo::Robots.parse(response.body) : Seo::Robots.permissive
    end

    def load_sitemap(robots)
      return Seo::Sitemap::Result.new(urls: [], reachable: true, error: nil) unless @site.follow_sitemap

      # La sitemap dichiarata dal robots.txt vince su quella indovinata: è quella che il
      # proprietario del sito considera la sua.
      url = robots.sitemaps.first.presence || "#{@site.base_url}/sitemap.xml"
      Seo::Sitemap.call(url:, fetcher: @fetcher)
    end

    def build_seeds(sitemap_urls)
      ([ home_url ] + sitemap_urls.filter_map { |url| normalize(url) if same_host?(url) }).uniq
    end

    def home_url = normalize(@site.base_url)

    def visit(seeds, robots, sitemap_set)
      queue = seeds.map { |url| [ url, url == home_url ? "seed" : "sitemap" ] }
      seen = seeds.to_set
      pages = []

      while (entry = queue.shift)
        break if pages.size >= @site.max_pages

        url, discovered_from = entry
        path = path_of(url)

        unless robots.allowed?(path)
          # Non si scarica ciò che è vietato. Resta però il fatto — una pagina vietata che sta
          # nella sitemap è una contraddizione del sito, e Analyze la solleva.
          pages << blocked_page(url, discovered_from, sitemap_set.include?(url))
          next
        end

        response = @fetcher.call(url:)
        page = build_page(url, response, discovered_from, sitemap_set.include?(url))
        pages << page

        enqueue_links(page, queue, seen) if page[:attributes].present?
        sleep(@pause) if @pause.positive?
      end

      pages
    end

    def enqueue_links(page, queue, seen)
      page[:attributes][:internal_links].each do |raw_link|
        link = normalize(raw_link)
        next if link.nil? || seen.include?(link) || !same_host?(link)

        seen << link
        queue << [ link, page[:url] ]
      end
    end

    # `https://sito.test` e `https://sito.test/` sono la stessa pagina: senza questa normalizzazione
    # la home verrebbe visitata due volte e finirebbe in elenco come due righe diverse — una dalla
    # base dichiarata dall'utente, l'altra dal link del menu. Si tocca solo il path vuoto e il
    # frammento: una barra finale su `/chi-siamo/` la lasciamo com'è, perché lì può davvero
    # trattarsi di due indirizzi distinti e sarebbe il sito a doverlo chiarire col canonical.
    def normalize(url)
      uri = URI.parse(url.to_s)
      uri.fragment = nil
      uri.path = "/" if uri.path.blank?
      uri.to_s
    rescue URI::InvalidURIError
      nil
    end

    def build_page(url, response, discovered_from, in_sitemap)
      attributes = response.ok? && response.html? ? Seo::Extract.call(html: response.body, url: response.final_url || url) : nil

      {
        url: url,
        path: path_of(url),
        status_code: response.status_code,
        redirect_chain: response.redirect_chain,
        response_time_ms: response.response_time_ms,
        in_sitemap: in_sitemap,
        discovered_from: discovered_from,
        blocked_by_robots: false,
        error: response.error,
        attributes: attributes,
        observation: observation_of(response, attributes)
      }
    end

    # Fin dove siamo arrivati su questa pagina (CYRA-808). Non è diagnostica: è ciò che a valle
    # distingue «il problema non c'è più» da «non sono riuscito a guardare», e senza di esso un
    # timeout varrebbe quanto una verifica riuscita.
    #
    # `attributes` presenti = HTML letto davvero. Nessun errore di trasporto = il server ha
    # risposto, anche se con un 404 o con un PDF: di quella pagina sappiamo stato, salti e tempo,
    # non cosa c'è dentro. Tutto il resto — timeout, indirizzo bloccato, catena di salti infinita —
    # è un tentativo e basta.
    def observation_of(response, attributes)
      return :analyzed if attributes.present?

      response.error.blank? ? :responded : :attempted
    end

    # Vietata da robots.txt: non l'abbiamo nemmeno aperta. Sappiamo solo che il sito la vieta e se
    # la mette comunque nella propria sitemap.
    def blocked_page(url, discovered_from, in_sitemap)
      {
        url: url, path: path_of(url), status_code: nil, redirect_chain: [], response_time_ms: nil,
        in_sitemap: in_sitemap, discovered_from: discovered_from, blocked_by_robots: true,
        error: nil, attributes: nil, observation: :attempted
      }
    end

    def path_of(url)
      uri = URI.parse(url)
      uri.query.present? ? "#{uri.path}?#{uri.query}" : uri.path.presence || "/"
    rescue URI::InvalidURIError
      "/"
    end

    def same_host?(url)
      URI.parse(url).host == base_uri.host
    rescue URI::InvalidURIError
      false
    end
  end
end
