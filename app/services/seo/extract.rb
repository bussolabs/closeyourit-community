# frozen_string_literal: true

module Seo
  # Da HTML servito ad attributi della pagina. Non giudica: raccoglie e normalizza, e basta —
  # stessa filosofia dello script che alimenta l'audit fatto a mano. La severità la decide
  # Seo::Analyze leggendo il registro dei controlli.
  #
  # È l'HTML SERVITO, non il DOM dopo il JavaScript: è ciò che un crawler vede al primo colpo, e
  # per la maggior parte dei motori resta ciò che conta. Il confronto col DOM renderizzato — dove
  # spesso compaiono JSON-LD e link generati a runtime — richiede un browser, che nel container
  # non c'è: è dichiarato fuori dalla prima versione, non dimenticato.
  class Extract < ApplicationService
    # Oltre questi link non è più navigazione, è una mappa del sito dentro il footer: contarli
    # tutti costa e non dice niente di più.
    MAX_LINKS = 500

    def initialize(html:, url:)
      @html = html.to_s
      @url = url
      @uri = URI.parse(url.to_s)
    rescue URI::InvalidURIError
      @uri = nil
    end

    def call
      document = Nokogiri::HTML5(@html)
      links = collect_links(document)

      {
        title: text_of(document.at_css("head > title")),
        meta_description: attribute_of(meta_named(document, "description"), "content"),
        canonical_url: absolutize(attribute_of(link_with_rel(document, "canonical"), "href")),
        robots_directives: attribute_of(meta_named(document, "robots"), "content"),
        hreflangs: hreflangs(document),
        lang: attribute_of(document.at_css("html"), "lang").presence,
        h1s: document.css("h1").map { |node| node.text.squish }.reject(&:blank?),
        h2_count: document.css("h2").size,
        word_count: word_count(document),
        jsonld_types: jsonld_types(document),
        images_total: document.css("img").size,
        images_without_alt: document.css("img").count { |img| img["alt"].to_s.strip.empty? },
        internal_links: links[:internal],
        external_links_count: links[:external].size,
        html_bytes: @html.bytesize,
        mixed_content: mixed_content?(document)
      }
    end

    private

    def text_of(node) = node&.text&.squish.presence

    def attribute_of(node, name) = node && node[name].to_s.strip.presence

    # I selettori CSS di Nokogiri non hanno il flag `i`, e i VALORI degli attributi restano come
    # scritti: `<meta name="Description">` è legale e va trovato lo stesso. Il confronto si fa qui,
    # in Ruby, dove il minuscolo è una riga.
    def meta_named(document, name)
      document.css("meta").find { |node| node["name"].to_s.strip.downcase == name }
    end

    def link_with_rel(document, rel)
      links_with_rel(document, rel).first
    end

    def links_with_rel(document, rel)
      document.css("link").select { |node| node["rel"].to_s.strip.downcase == rel }
    end

    def hreflangs(document)
      links_with_rel(document, "alternate").each_with_object({}) do |node, acc|
        locale = node["hreflang"].to_s.strip.downcase
        href = absolutize(node["href"])
        acc[locale] = href if locale.present? && href.present?
      end
    end

    # Il testo che un lettore vede: via script, style, noscript e template, che sono istruzioni per
    # la macchina e gonfierebbero il conteggio facendo sembrare piena una pagina vuota.
    def word_count(document)
      body = document.at_css("body")
      return 0 if body.nil?

      copy = body.dup
      copy.css("script, style, noscript, template, svg").remove
      copy.text.split(/\s+/).count { |word| word.match?(/\p{Alnum}/) }
    end

    def jsonld_nodes(document)
      document.css("script").select { |node| node["type"].to_s.strip.downcase == "application/ld+json" }
    end

    def jsonld_types(document)
      jsonld_nodes(document).flat_map do |node|
        parsed = JSON.parse(node.text.to_s)
        types_from(parsed)
      rescue JSON::ParserError
        # Un JSON-LD rotto non è "assente": è peggio, ed è un fatto che vale la pena registrare.
        [ "invalid" ]
      end.uniq
    end

    def types_from(parsed)
      case parsed
      when Array then parsed.flat_map { |item| types_from(item) }
      when Hash
        graph = parsed["@graph"]
        graph.is_a?(Array) ? graph.flat_map { |item| types_from(item) } : Array(parsed["@type"])
      else []
      end
    end

    def collect_links(document)
      internal = []
      external = []

      document.css("a[href]").first(MAX_LINKS).each do |node|
        href = node["href"].to_s.strip
        next if href.blank? || href.start_with?("#", "mailto:", "tel:", "javascript:")

        absolute = absolutize(href)
        next if absolute.blank?

        same_host?(absolute) ? internal << absolute : external << absolute
      end

      { internal: internal.uniq, external: external.uniq }
    end

    # Risorse in chiaro dentro una pagina cifrata: il browser le blocca o avvisa, e ciò che viene
    # bloccato per il motore semplicemente non esiste.
    def mixed_content?(document)
      return false unless @uri&.scheme == "https"

      nodes = document.css("img[src], script[src], iframe[src]").to_a + links_with_rel(document, "stylesheet")
      nodes.any? do |node|
        value = node["src"] || node["href"]
        value.to_s.strip.downcase.start_with?("http://")
      end
    end

    def absolutize(href)
      return nil if href.blank? || @uri.nil?

      URI.join(@uri, href.strip).tap { |uri| uri.fragment = nil }.to_s
    rescue URI::Error
      nil
    end

    def same_host?(url)
      URI.parse(url).host == @uri&.host
    rescue URI::InvalidURIError
      false
    end
  end
end
