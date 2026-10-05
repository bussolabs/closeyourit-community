# frozen_string_literal: true

module Ticketing
  # Conteggio dei ticket per CATEGORIA di status (Types::TicketStatus#category), così che
  # "Da fare / In corso / Concluso" e "Non chiusi" indichino lo STESSO insieme ovunque compaiano:
  # pill dell'header progetto, KPI card salute, card della lista progetti (CYRA-358).
  #
  # La categoria è il campo semantico stabile: aggrega i code (in_progress + in_review → in corso;
  # resolved + closed → concluso), regge gli status personalizzati dell'org e garantisce
  # todo + in_progress + done = total. Prima ogni punto contava per code (open/in_progress/resolved),
  # lasciando fuori in_review e closed: da qui tre numeri diversi tutti chiamati "aperti".
  class Tally
    # `group` su una colonna enum restituisce il NOME della categoria ("open"…), non l'intero;
    # normalizziamo comunque anche gli interi per non dipendere da quel dettaglio.
    CATEGORY_NAMES = Types::TicketStatus.categories.invert.freeze

    # Conteggio di UN insieme di ticket (relation), raggruppato per categoria in una sola query.
    def self.for(tickets)
      new(tickets.joins(:status).group("types_ticket_statuses.category").count)
    end

    # Conteggio per progetto in UNA query → { project_id => Tally }. Un progetto senza ticket
    # non compare nell'hash: lato chiamante usare `counts[id] || Tally.empty`.
    def self.by_project(tickets)
      grouped = Hash.new { |hash, project_id| hash[project_id] = {} }
      tickets.joins(:status).group(:project_id, "types_ticket_statuses.category").count
             .each { |(project_id, category), n| grouped[project_id][category] = n }
      grouped.transform_values { |by_category| new(by_category) }
    end

    def self.empty = new({})

    def initialize(by_category)
      @by_category = Hash.new(0)
      by_category.each { |category, n| @by_category[normalize(category)] += n }
    end

    # "Da fare": lavoro non ancora iniziato (categoria open).
    def todo = @by_category["open"]

    # "In corso": in lavorazione o in revisione (categoria in_progress).
    def in_progress = @by_category["in_progress"]

    # "Concluso": risolti o chiusi (categoria done).
    def done = @by_category["done"]

    # "Non chiusi": tutto il lavoro ancora attivo (da fare + in corso), mai i conclusi.
    def unresolved = todo + in_progress

    def total = todo + in_progress + done

    private

    def normalize(category)
      category.is_a?(Integer) ? CATEGORY_NAMES[category] : category.to_s
    end
  end
end
