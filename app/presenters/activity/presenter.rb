# frozen_string_literal: true

module Activity
  # Frase + icona per un Activity::Event nella cronologia generica (project/group/…). Le label dei
  # campi (data["fields"]) sono già snapshottate. i18n sotto `activity.*`. Mirror leggero di
  # Ticketing::ActivityPresenter ma per il log generalizzato (solo created/updated).
  class Presenter
    ICONS = { "created" => "circle-plus", "updated" => "pen" }.freeze

    def initialize(event)
      @event = event
    end

    def icon = ICONS.fetch(@event.action, "info")

    def sentence
      return updated_sentence if @event.action == "updated"

      I18n.t("activity.actions.#{@event.action}", actor: actor_name)
    end

    # Nome dell'attore, snapshot-first (resiste alla cancellazione dell'account).
    def actor_name
      @event.actor_name.presence ||
        @event.actor&.name.presence ||
        I18n.t("activity.unknown_actor")
    end

    private

    # `updated` aggrega i campi cambiati (data["fields"]) in una frase. Fallback generico se vuoto.
    def updated_sentence
      fields = Array(@event.data["fields"]).map do |field|
        I18n.t("activity.fields.#{field}", default: field.to_s.humanize.downcase)
      end
      return I18n.t("activity.actions.updated_generic", actor: actor_name) if fields.empty?

      I18n.t("activity.actions.updated", actor: actor_name, fields: fields.join(", "))
    end
  end
end
