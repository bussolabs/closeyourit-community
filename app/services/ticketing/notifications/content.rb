# frozen_string_literal: true

module Ticketing
  module Notifications
    # Snapshot umano (title/body/url) di una notifica ticket, derivato dall'evento. Lo snapshot è
    # congelato sulla notifica → resta leggibile anche se il ticket cambia in seguito. Twin di
    # Alerting::Content per il dominio ticket, ma NON solleva (gli event_type sono filtrati a monte).
    Content = Data.define(:title, :body, :url) do
      def self.for(event:)
        ticket = event.ticket
        new(
          title: title_for(event, ticket),
          body: ticket.title,
          url: Rails.application.routes.url_helpers.member_ticket_path(ticket)
        )
      end

      # Snapshot dedicato del ping "pronto per la revisione" (ingresso in uno status review_gate).
      # Title diverso (call-to-action) dallo status_changed generico; body/url come gli altri.
      def self.review(event:)
        ticket = event.ticket
        new(
          title: I18n.t("ticketing.notifications.content.review_requested", code: ticket.code),
          body: ticket.title,
          url: Rails.application.routes.url_helpers.member_ticket_path(ticket)
        )
      end

      # Snapshot dedicato del ping "review respinta" all'assignee: il body È il motivo del rifiuto
      # (l'informazione azionabile per chi deve sistemare), non il titolo del ticket.
      def self.review_rejected(event:)
        ticket = event.ticket
        new(
          title: I18n.t("ticketing.notifications.content.review_rejected", code: ticket.code),
          body: event.data["reason"].presence || ticket.title,
          url: Rails.application.routes.url_helpers.member_ticket_path(ticket)
        )
      end

      # Titolo umano per azione, attinto da event.data (label già snapshottate da RecordActivity).
      def self.title_for(event, ticket)
        code = ticket.code
        data = event.data || {}
        case event.action
        when "created"
          I18n.t("ticketing.notifications.content.created", code: code)
        when "assigned"
          I18n.t("ticketing.notifications.content.assigned", code: code, name: data.dig("assignee", "to"))
        when "unassigned"
          I18n.t("ticketing.notifications.content.unassigned", code: code)
        when "status_changed"
          I18n.t("ticketing.notifications.content.status_changed",
                 code: code, from: data.dig("status", "from"), to: data.dig("status", "to"))
        when "milestone_changed"
          milestone_title(code, data.dig("milestone", "to"))
        when "review_rejected"
          I18n.t("ticketing.notifications.content.review_rejected", code: code)
        when "question_asked"
          I18n.t("ticketing.notifications.content.question_asked", code: code, name: event.actor_name)
        when "question_answered"
          I18n.t("ticketing.notifications.content.question_answered", code: code, name: event.actor_name)
        when "review_approved"
          I18n.t("ticketing.notifications.content.review_approved",
                 code: code, to: data.dig("status", "to"))
        else
          code
        end
      end

      # milestone_changed può essere un set (to presente) o una rimozione (to nil).
      def self.milestone_title(code, name)
        key = name.present? ? "milestone_set" : "milestone_removed"
        I18n.t("ticketing.notifications.content.#{key}", code: code, name: name)
      end
    end
  end
end
