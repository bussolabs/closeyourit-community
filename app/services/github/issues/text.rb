# frozen_string_literal: true

module Github
  module Issues
    # How a text crosses between an issue and a ticket: the ticket's ceilings, the cut that keeps a link
    # to the original, and the file links CloseYourIt appends below a marker it strips on the way back. CYRA-1055
    module Text
      ATTACHMENTS_MARKER = "<!-- closeyourit:attachments -->"
      # Room left for the spelling fixes a ticket applies when it saves: they may add a character or two.
      MARGIN = 10
      TITLE_MAX = 255

      module_function

      def without_attachments(body)
        body.to_s.split(ATTACHMENTS_MARKER, 2).first.to_s.rstrip
      end

      def title(value)
        value.to_s.strip.first(TITLE_MAX).presence || "—"
      end

      # [description, cut?]. An issue without text still makes a ticket that can be saved.
      def description(body, url)
        text = LengthBudget.normalize_newlines(without_attachments(body)).strip
        return [ I18n.t("github.issues.empty_body", url:), false ] if text.blank?

        fit(text, Ticketing::Constants::DESCRIPTION_MAX_CHARS, url)
      end

      # [comment body, cut?]
      def comment(body, url)
        fit(LengthBudget.normalize_newlines(body).strip, Ticketing::Constants::COMMENT_MAX_CHARS, url)
      end

      def fit(text, limit, url)
        return [ text, false ] if text.length <= limit - MARGIN

        tail = "\n#{I18n.t('github.issues.cut', url:)}"
        [ "#{text.first(limit - MARGIN - tail.length - 1).rstrip}…#{tail}", true ]
      end

      # The issue body written from a ticket: its description, then links to its files.
      def issue_body(ticket)
        links = ticket.files_attachments.map do |attachment|
          "- [#{attachment.filename}](#{file_url(ticket, attachment)})"
        end
        return ticket.description.to_s if links.empty?

        "#{ticket.description}\n\n#{ATTACHMENTS_MARKER}\n**#{I18n.t('github.issues.attachments')}**\n#{links.join("\n")}"
      end

      # A comment written on CloseYourIt says who wrote it: on GitHub it is signed by the App.
      def comment_body(comment)
        "**#{comment.author.name}** #{I18n.t('github.issues.on_closeyourit')}\n\n#{comment.body}"
      end

      def file_url(ticket, attachment)
        path = Rails.application.routes.url_helpers.member_ticket_file_path(ticket, attachment)
        "#{App::Host.base_url}#{path}"
      end
    end
  end
end
