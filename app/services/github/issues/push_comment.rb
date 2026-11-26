# frozen_string_literal: true

module Github
  module Issues
    # A comment written on CloseYourIt goes to the linked issue, with its writer's name: on GitHub the App
    # signs it. Its GitHub id is kept, so the delivery GitHub sends back is recognised. Comments born on
    # GitHub and the automation's own lines stay where they are. CYRA-1055
    class PushComment < ApplicationService
      def initialize(comment:, client: Github::Client.new)
        @comment = comment
        @client = client
      end

      def call
        return Result.ok(nil) if skip?

        link = @comment.ticket.github_issue
        return Result.ok(nil) if link.nil? || !link.repository.issue_sync_live?

        repository = link.repository
        response = @client.create_issue_comment(repository.github_installation_id, repository.full_name,
                                                link.number, body: body)
        @comment.update_columns(github_comment_id: response["id"]) if response["id"].present?
        Result.ok(@comment)
      end

      private

      def skip? = @comment.github_comment_id.present? || @comment.from_github? || @comment.automation_generated?

      def body
        links = @comment.files_attachments.map do |attachment|
          "- [#{attachment.filename}](#{Text.file_url(@comment.ticket, attachment)})"
        end
        [ Text.comment_body(@comment), *links ].join("\n")
      end
    end
  end
end
