# frozen_string_literal: true

module Ticketing
  # Confronto campo-per-campo tra il ticket preesistente e il draft (pagina del gate duplicati).
  # Produce righe display-ready (label umane, valori formattati) con flag `changed` per
  # l'evidenziazione: tutto il branching vive qui, il partial resta puro rendering.
  class ComparisonPresenter
    Row = Data.define(:key, :old_value, :new_value, :changed)

    # Ordine di presentazione: prima il contenuto, poi la classificazione.
    FIELDS = %w[title kind description scenarios conditions technical_analysis
                status priority milestone platforms weight].freeze

    def initialize(existing:, draft:)
      @existing = existing
      @draft = draft
    end

    # Righe del confronto: i campi vuoti su ENTRAMBI i lati vengono omessi (niente rumore).
    def rows
      FIELDS.filter_map do |field|
        old_value = display_value(@existing, field)
        new_value = display_value(@draft, field)
        next if old_value.blank? && new_value.blank?

        Row.new(key: field, old_value: old_value, new_value: new_value,
                changed: old_value.to_s.strip != new_value.to_s.strip)
      end
    end

    private

    def display_value(ticket, field)
      case field
      when "kind" then I18n.t("member.tickets.kind.#{ticket.kind}", default: ticket.kind.to_s)
      when "scenarios" then Ticketing::BodyText.scenarios(ticket.scenarios)
      when "conditions" then Ticketing::BodyText.conditions(ticket.conditions)
      when "status" then ticket.status&.label
      when "priority" then ticket.priority&.label
      when "milestone" then ticket.milestone&.label
      when "platforms" then ticket.platforms.map(&:label).sort.join(" · ")
      when "weight" then ticket.weight&.to_s
      else ticket.public_send(field)
      end
    end
  end
end
