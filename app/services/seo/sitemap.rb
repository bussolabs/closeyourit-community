# frozen_string_literal: true

module Seo
  # Le URL dichiarate dalla sitemap. È la lista che il proprietario del sito considera il proprio
  # indice: confrontarla con quello che si raggiunge davvero navigando è ciò che fa emergere le
  # pagine orfane (nella sitemap ma non linkate) e quelle dimenticate (linkate ma fuori sitemap).
  #
  # Gestisce sia `<urlset>` sia `<sitemapindex>`, quest'ultimo per UN livello: le sitemap annidate
  # più in profondità sono rare, e seguirle senza limite significherebbe farsi guidare in giro per
  # la rete da un file che non controlliamo.
  class Sitemap < ApplicationService
    MAX_CHILD_SITEMAPS = 20
    MAX_URLS = 5_000

    def initialize(url:, fetcher: Seo::Fetch)
      @url = url
      @fetcher = fetcher
    end

    Result = Data.define(:urls, :reachable, :error) do
      def reachable? = reachable
    end

    def call
      response = @fetcher.call(url: @url)
      return Result.new(urls: [], reachable: false, error: response.error || "http_#{response.status_code}") unless response.ok?

      document = parse(response.body)
      return Result.new(urls: [], reachable: false, error: "invalid_xml") if document.nil?

      urls = document.css("sitemapindex > sitemap > loc").any? ? from_index(document) : from_urlset(document)
      Result.new(urls: urls.uniq.first(MAX_URLS), reachable: true, error: nil)
    end

    private

    def from_urlset(document)
      document.css("urlset > url > loc").map { |node| node.text.strip }.reject(&:blank?)
    end

    def from_index(document)
      document.css("sitemapindex > sitemap > loc").first(MAX_CHILD_SITEMAPS).flat_map do |node|
        child = @fetcher.call(url: node.text.strip)
        next [] unless child.ok?

        child_document = parse(child.body)
        child_document ? from_urlset(child_document) : []
      end
    end

    def parse(body)
      Nokogiri::XML(body.to_s)
    rescue StandardError
      nil
    end
  end
end
