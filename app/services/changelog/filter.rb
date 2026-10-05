# frozen_string_literal: true

module Changelog
  # CYRA-445 — Filtra lo storico: per AREA (dove è cambiata la cosa), per TIPO di modifica
  # (aggiunto/modificato/corretto/…) e per PAROLE cercate dentro il testo delle voci.
  #
  # Filtra le VOCI, non le versioni: di una release restano solo le voci che passano, le sezioni
  # rimaste vuote spariscono e con esse le release che non hanno più niente da dire — altrimenti
  # filtrare per «Uptime» lascerebbe in pagina cinquanta intestazioni di versione vuote.
  #
  # La ricerca legge la voce come la legge chi guarda: niente asterischi del grassetto, niente
  # indirizzi delle pagine, e il nome dell'area è quello del menu. Così cercare «Uptime» trova
  # anche la voce che nel file dice «Disponibilità».
  class Filter < ApplicationService
    # I tipi di modifica del formato Keep a Changelog, nell'ordine in cui si leggono in pagina.
    KINDS = %w[added changed fixed removed deprecated security].freeze

    def initialize(releases, area: nil, kind: nil, query: nil)
      @releases = releases
      @areas = Areas.known(area)
      @kinds = self.class.kinds(kind)
      @query = normalize(query.to_s.strip)
    end

    # I tipi riconosciuti fra quelli arrivati dall'indirizzo (un valore inventato si ignora).
    def self.kinds(values)
      Array(values).map { |value| value.to_s.downcase }.select { |value| KINDS.include?(value) }.uniq
    end

    def call
      return @releases unless filtering?

      @releases.filter_map { |release| filter_release(release) }
    end

    private

    def filtering? = @areas.any? || @kinds.any? || @query.present?

    def filter_release(release)
      sections = release.sections.filter_map { |section| filter_section(section) }
      return if sections.empty?

      Release.new(version: release.version, date: release.date, sections: sections)
    end

    def filter_section(section)
      return unless kind?(section[:label])

      items = section[:items].select { |item| item?(item) }
      return if items.empty?

      { label: section[:label], items: items }
    end

    def kind?(label) = @kinds.empty? || @kinds.include?(label.to_s.downcase)

    def item?(item) = area?(item) && matches_query?(item)

    def area?(item) = @areas.empty? || Areas.in_entry(item).intersect?(@areas)

    def matches_query?(item) = @query.blank? || normalize(plain(item)).include?(@query)

    # La voce come si legge: markup del grassetto via, link interni ridotti al nome che l'area ha
    # nel menu (gli indirizzi non sono testo da cercare).
    def plain(text)
      text.gsub(Areas::INTERNAL_LINK) { Areas.label_for_path(::Regexp.last_match(2)) || ::Regexp.last_match(1) }
          .delete("*")
    end

    # Chi cerca «novita» deve trovare «novità», e «UPTIME» deve trovare «Uptime».
    def normalize(text) = I18n.transliterate(text).downcase
  end
end
