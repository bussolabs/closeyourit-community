# frozen_string_literal: true

module Search
  # Reads a link: a GitHub pull request, or a page of this app by its path, whatever the host (CYRA-1145).
  # It only names what the link points to; the lookup stays with the caller, inside the visible scope.
  class Address
    PULL_REQUEST = %r{\Ahttps?://(?:www\.)?github\.com/(?<owner>[^/\s]+)/(?<repo>[^/\s]+)/pull/(?<number>\d+)}i

    def initialize(text)
      @text = text.to_s.strip
    end

    # The canonical address GitHub stores for the pull request, lowercased for the comparison.
    def pull_request_url
      match = PULL_REQUEST.match(@text)
      match && "https://github.com/#{match[:owner]}/#{match[:repo]}/pull/#{match[:number]}".downcase
    end

    def ticket_id = id_for("member/tickets")

    def project_id
      id_for("member/projects") || route&.dig(:project_id)
    end

    private

    def id_for(controller)
      route[:id] if route && route[:controller] == controller && route[:action] == "show"
    end

    def route
      return @route if defined?(@route)

      @route = recognize
    end

    def recognize
      return if pull_request_url

      path = URI.parse(@text).path
      return unless path&.start_with?("/member/")

      Rails.application.routes.recognize_path(path, method: :get)
    rescue URI::InvalidURIError, ActionController::RoutingError
      nil
    end
  end
end
