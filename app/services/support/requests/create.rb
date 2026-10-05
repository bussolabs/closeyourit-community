# frozen_string_literal: true

module Support
  module Requests
    # Saves a support request and announces it by email (CYRA-935). What the server knows goes in
    # by itself; from the browser only the listed details are kept, each cut to a safe length.
    class Create < ApplicationService
      def initialize(account:, organization:, body:, client_context: {}, request_details: {})
        @account = account
        @organization = organization
        @body = body
        @client_context = client_context.to_h
        @request_details = request_details
      end

      def call
        record = Request.new(account: @account, organization: @organization, body: @body, context:)
        return Result.err(AppError.new(record.errors.full_messages.to_sentence, code: "R422-SUP-001",
                                                                                status: :unprocessable_content)) unless record.save

        RequestsMailer.created(record).deliver_later
        Result.ok(record)
      end

      private

      def context
        client = @client_context.slice(*Constants::CLIENT_CONTEXT_KEYS)
                                .transform_values { |value| value.to_s.first(Constants::CONTEXT_VALUE_MAX_CHARS) }
        client.merge(server_context).compact_blank
      end

      def server_context
        { "role" => @request_details[:role], "locale" => I18n.locale.to_s,
          "version" => "#{App::Version.tag} · #{App::Version.short_sha}",
          "user_agent" => @request_details[:user_agent].to_s.first(Constants::CONTEXT_VALUE_MAX_CHARS),
          "request_id" => @request_details[:request_id] }
      end
    end
  end
end
