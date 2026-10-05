# frozen_string_literal: true

module Seo
  # Dai fatti raccolti ai rilievi, ciascuno con la sua prova. Qui e solo qui vivono le soglie e i
  # confronti: il crawler non giudica, il registro dei controlli dice quanto pesa ciò che troviamo.
  #
  # Due famiglie, come dice `Seo::Check#scope`:
  # - di pagina: si vedono guardando una pagina sola (manca l'h1, il titolo è lungo, è lenta);
  # - d'insieme: esistono solo confrontando le pagine fra loro (titoli duplicati, pagine orfane,
  #   hreflang che non si rispondono). Sono quelli che un controllo pagina-per-pagina non troverà
  #   mai, ed è la ragione per cui questa classe riceve tutto il giro e non una pagina.
  class Analyze < ApplicationService
    Candidate = Data.define(:check_key, :url, :evidence) do
      def initialize(check_key:, url: nil, evidence: {})
        super
      end
    end

    def initialize(crawl:, site:)
      @crawl = crawl
      @site = site
      @pages = crawl.pages
    end

    def call
      page_candidates + site_candidates
    end

    private

    def threshold(name) = Seo::Check.threshold(name)

    # --- di pagina --------------------------------------------------------------------------------

    def page_candidates
      @pages.flat_map { |page| candidates_for(page) }
    end

    def candidates_for(page)
      return [ blocked_candidate(page) ].compact if page[:blocked_by_robots]
      return [ loop_candidate(page) ] if page[:error] == "too_many_redirects"
      return [] if page[:error].present?

      [
        response_candidates(page),
        indexability_candidates(page),
        structure_candidates(page),
        content_candidates(page),
        performance_candidates(page)
      ].flatten.compact
    end

    # Una pagina vietata da robots.txt non è un problema di per sé: lo diventa quando è il sito
    # stesso a metterla nella propria sitemap, cioè a chiedere di indicizzarla e vietarla insieme.
    def blocked_candidate(page)
      return nil unless page[:in_sitemap]

      candidate("blocked_by_robots", page, { "reason" => "in_sitemap_but_disallowed" })
    end

    def loop_candidate(page)
      candidate("redirect_loop", page, { "chain" => page[:redirect_chain] })
    end

    def response_candidates(page)
      list = []
      status = page[:status_code].to_i
      list << candidate("broken_link", page, { "status" => status, "from" => page[:discovered_from] }) if status >= 400
      if page[:redirect_chain].size > threshold(:max_redirect_hops)
        list << candidate("redirect_chain", page, { "hops" => page[:redirect_chain].size, "chain" => page[:redirect_chain] })
      end
      list
    end

    def indexability_candidates(page)
      attributes = page[:attributes]
      return [] if attributes.blank?

      list = []
      directives = attributes[:robots_directives].to_s.downcase
      list << candidate("noindex", page, { "directives" => attributes[:robots_directives] }) if directives.include?("noindex")

      canonical = attributes[:canonical_url]
      if canonical.blank?
        list << candidate("canonical_missing", page)
      elsif page[:in_sitemap] && !same_resource?(canonical, page[:url])
        # In sitemap (quindi il sito la vuole indicizzata) ma il canonical manda altrove: le due
        # dichiarazioni si contraddicono, e vince quella che toglie la pagina dai risultati.
        list << candidate("canonical_points_elsewhere", page, { "canonical" => canonical })
      end

      list << candidate("missing_from_sitemap", page) if missing_from_sitemap?(page)
      list
    end

    def structure_candidates(page)
      attributes = page[:attributes]
      return [] if attributes.blank?

      list = []
      title = attributes[:title]
      if title.blank?
        list << candidate("missing_title", page)
      elsif title.length > threshold(:title_max_length)
        list << candidate("title_too_long", page, { "length" => title.length, "title" => title })
      end

      list << candidate("missing_meta_description", page) if attributes[:meta_description].blank?
      list << candidate("missing_h1", page, { "found" => 0 }) if attributes[:h1s].empty?
      list << candidate("multiple_h1", page, { "found" => attributes[:h1s].size, "h1s" => attributes[:h1s] }) if attributes[:h1s].size > 1
      list << candidate("lang_missing", page) if attributes[:lang].blank?
      # Solo sulla home: pretendere dati strutturati su ogni pagina di un sito qualsiasi produce
      # una lista lunga e inutile, mentre la home senza JSON-LD è un'occasione persa vera.
      list << candidate("missing_jsonld", page) if home?(page) && attributes[:jsonld_types].empty?
      list
    end

    def content_candidates(page)
      attributes = page[:attributes]
      return [] if attributes.blank?

      list = []
      if attributes[:word_count] < threshold(:thin_content_words)
        list << candidate("thin_content", page, { "words" => attributes[:word_count] })
      end
      if attributes[:images_without_alt].positive?
        list << candidate("images_without_alt", page,
                          { "without_alt" => attributes[:images_without_alt], "total" => attributes[:images_total] })
      end
      list
    end

    def performance_candidates(page)
      attributes = page[:attributes]
      list = []
      if page[:response_time_ms].to_i > threshold(:slow_response_ms)
        list << candidate("slow_response", page, { "ms" => page[:response_time_ms] })
      end
      return list if attributes.blank?

      if attributes[:html_bytes] > threshold(:oversized_html_bytes)
        list << candidate("oversized_html", page, { "bytes" => attributes[:html_bytes] })
      end
      list << candidate("mixed_content", page) if attributes[:mixed_content]
      list
    end

    # --- d'insieme --------------------------------------------------------------------------------

    def site_candidates
      [
        reachability_candidates,
        duplicate_candidates(:title, "duplicate_title"),
        duplicate_candidates(:meta_description, "duplicate_meta_description"),
        orphan_candidates,
        hreflang_candidates
      ].flatten.compact
    end

    def reachability_candidates
      list = []
      list << Candidate.new(check_key: "sitemap_unreachable", evidence: { "url" => "#{@site.base_url}/sitemap.xml" }) unless @crawl.sitemap_reachable
      list << Candidate.new(check_key: "robots_unreachable", evidence: { "url" => "#{@site.base_url}/robots.txt" }) unless @crawl.robots_reachable
      list
    end

    def duplicate_candidates(attribute, check_key)
      groups = analyzable_pages.group_by { |page| page[:attributes][attribute].to_s.strip.downcase }
                               .reject { |value, pages| value.blank? || pages.size < 2 }
      return [] if groups.empty?

      [ Candidate.new(
        check_key: check_key,
        evidence: {
          "groups" => groups.map { |value, pages| { "value" => pages.first[:attributes][attribute], "urls" => pages.map { |p| p[:url] } } }
        }
      ) ]
    end

    # Nella sitemap ma nessuna pagina del sito la linka: chi naviga non ci arriva mai, e per il
    # motore vale quanto i link che riceve — cioè niente.
    def orphan_candidates
      return [] if linked_urls.empty?

      analyzable_pages.filter_map do |page|
        next if home?(page) || !page[:in_sitemap]
        next if linked_urls.include?(page[:url])

        candidate("orphan_page", page)
      end
    end

    def hreflang_candidates
      pages_with_hreflang = analyzable_pages.select { |page| page[:attributes][:hreflangs].present? }
      return [] if pages_with_hreflang.empty?

      list = []
      missing_default = pages_with_hreflang.reject { |page| page[:attributes][:hreflangs].key?("x-default") }
      if missing_default.any?
        list << Candidate.new(check_key: "hreflang_missing_x_default",
                              evidence: { "urls" => missing_default.map { |page| page[:url] }.first(20) })
      end

      broken = non_reciprocal(pages_with_hreflang)
      if broken.any?
        list << Candidate.new(check_key: "hreflang_not_reciprocal",
                              evidence: { "pairs" => broken.first(20) })
      end
      list
    end

    # A dichiara B come alternativa, ma B non dichiara A: il motore scarta la coppia e le due
    # pagine restano a competere fra loro.
    def non_reciprocal(pages_with_hreflang)
      by_url = analyzable_pages.index_by { |page| page[:url] }

      pages_with_hreflang.flat_map do |page|
        page[:attributes][:hreflangs].filter_map do |locale, target|
          next if locale == "x-default" || same_resource?(target, page[:url])

          other = by_url[target]
          # Se la pagina puntata non è stata visitata non possiamo dire niente: il silenzio è più
          # onesto di un rilievo inventato.
          next if other.nil? || other[:attributes].blank?

          back = other[:attributes][:hreflangs].values
          { "from" => page[:url], "to" => target } unless back.any? { |value| same_resource?(value, page[:url]) }
        end
      end
    end

    # --- utilità ----------------------------------------------------------------------------------

    def analyzable_pages = @analyzable_pages ||= @pages.select { |page| page[:attributes].present? }

    def linked_urls
      @linked_urls ||= analyzable_pages.flat_map { |page| page[:attributes][:internal_links] }.to_set
    end

    def missing_from_sitemap?(page)
      return false unless @crawl.sitemap_reachable && @crawl.sitemap_urls.any?

      !page[:in_sitemap]
    end

    def home?(page) = page[:path].blank? || page[:path] == "/"

    def candidate(check_key, page, evidence = {})
      Candidate.new(check_key:, url: page[:url], evidence: evidence.merge("url" => page[:url]))
    end

    # Confronto fra URL che ignora la barra finale: `/chi-siamo` e `/chi-siamo/` sono la stessa
    # pagina per chiunque tranne che per un confronto di stringhe.
    def same_resource?(one, other)
      normalize(one) == normalize(other)
    end

    def normalize(url) = url.to_s.split("#").first.to_s.chomp("/")
  end
end
