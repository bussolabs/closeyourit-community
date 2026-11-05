# frozen_string_literal: true

module Analytics
  # Definizione di un goal (conversione) per progetto. Due tipi: pageview_path (una visita il cui path
  # matcha un pattern — suffisso "*" = prefisso) e custom_event (un evento con un dato nome, inviato
  # da CloseYourIt.captureEvent). Le conversioni si contano a query-time (Analytics::Query#conversions),
  # nessun contatore materializzato. Config, non stream: nessun created_by in v1.
  class Goal < ApplicationRecord
    belongs_to :project, class_name: "Projects::Project", inverse_of: :analytics_goals

    enum :kind, { pageview_path: 0, custom_event: 1 }

    normalizes :display_name, with: ->(v) { v.to_s.strip }
    normalizes :event_name, with: ->(v) { v.to_s.strip.presence }
    normalizes :path_pattern, with: ->(v) { v.to_s.strip.presence }

    validates :display_name, presence: true
    validates :event_name, presence: true, uniqueness: { scope: :project_id }, if: :custom_event?
    validates :path_pattern, presence: true, uniqueness: { scope: :project_id }, if: :pageview_path?

    scope :ordered, -> { order(:display_name) }

    # Restringe una relazione di eventi (già filtrata per progetto/range dal Query) ai soli eventi che
    # soddisfano il goal. Ritorna una relation Analytics::Pageview.
    def matching(events)
      case kind
      when "pageview_path"
        events.where(name: Pageview::PAGEVIEW_NAME).merge(path_condition)
      when "custom_event"
        events.where(name: event_name)
      end
    end

    private

    # Pattern con suffisso "*" → match di prefisso (LIKE 'prefix%', wildcard SQL nel prefisso escapati);
    # altrimenti match esatto del path.
    def path_condition
      pattern = path_pattern.to_s
      return Pageview.where(path: pattern) unless pattern.end_with?("*")

      prefix = Pageview.sanitize_sql_like(pattern.delete_suffix("*"))
      Pageview.where("path LIKE ?", "#{prefix}%")
    end
  end
end
