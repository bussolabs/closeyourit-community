# frozen_string_literal: true

module Website
  # Catalogo statico delle pagine feature del sito marketing (/features/:slug). Contenuto di
  # codice, non lookup table: ogni slug ha view-copy dedicata nei locale YAML e l'aggiunta di una
  # pagina è sviluppo (copy + eventuali sezioni), non un CRUD. Slug identici nei due locali
  # (termini di prodotto); la chiave i18n è lo slug in underscore sotto website.features.*.
  class FeaturePage
    attr_reader :slug, :icon

    def initialize(slug:, icon:)
      @slug = slug
      @icon = icon
    end

    ALL = [
      new(slug: "error-monitoring", icon: "bug"),
      new(slug: "ticketing",        icon: "list-check"),
      new(slug: "uptime",           icon: "radio-tower"),
      new(slug: "performance",      icon: "gauge"),
      new(slug: "logs",             icon: "text-align-start"),
      new(slug: "alerting-ai",      icon: "bell")
    ].freeze

    def self.all = ALL

    def self.find(slug) = ALL.find { |page| page.slug == slug }

    # Segmento chiave i18n: "error-monitoring" → website.features.error_monitoring.*
    def key = slug.tr("-", "_")
  end
end
