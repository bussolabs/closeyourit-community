# frozen_string_literal: true

require "net/http"
require "json"
require "timeout"

module Github
  module Installations
    # The setup redirect is untrusted. Require a user token and installation owner authority.
    class Verify < ApplicationService
      MAX_RESPONSE_BYTES = 1.megabyte
      MAX_PAGES = 20

      def initialize(installation_id:, code:, redirect_uri:, client_id: Settings::Integrations.value(:gh_app_client_id),
                     client_secret: Settings::Integrations.value(:gh_app_client_secret), app_id: Settings::Integrations.value(:gh_app_id))
        @installation_id = installation_id.to_s
        @code = code
        @redirect_uri = redirect_uri
        @client_id = client_id
        @client_secret = client_secret
        @app_id = app_id.to_s
      end

      def call
        return denied unless configured? && @installation_id.match?(/\A[1-9]\d*\z/) && @code.present?

        Timeout.timeout(30) do
          token = exchange_code
          return denied if token.blank?

          installation = find_installation(token)
          return denied unless installation && installation["app_id"].to_s == @app_id && installation["suspended_at"].nil?
          return denied unless owner?(token, installation.fetch("account"))

          Result.ok(installation)
        end
      rescue KeyError, JSON::ParserError, TypeError, Timeout::Error, IOError, SystemCallError, OpenSSL::SSL::SSLError
        denied
      end

      private

      def configured?
        @client_id.present? && @client_secret.present? && @app_id.present?
      end

      def exchange_code
        uri = URI("https://github.com/login/oauth/access_token")
        request = Net::HTTP::Post.new(uri)
        request.set_form_data(client_id: @client_id, client_secret: @client_secret, code: @code, redirect_uri: @redirect_uri)
        request["Accept"] = "application/json"
        perform(uri, request).fetch("access_token", nil)
      end

      def find_installation(token)
        (1..MAX_PAGES).each do |page|
          rows = get("/user/installations?per_page=100&page=#{page}", token).fetch("installations")
          raise TypeError, "Invalid installations response" unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) }
          match = rows.find { |row| row["id"].to_s == @installation_id }
          return match if match
          break if rows.size < 100
        end
        nil
      end

      def owner?(token, account)
        return false unless account.is_a?(Hash) && account["id"].is_a?(Integer) && account["id"].positive?
        return false unless account["login"].is_a?(String) && account["login"].match?(/\A[a-zA-Z0-9-]{1,100}\z/)

        case account.fetch("type")
        when "User"
          get("/user", token).fetch("id") == account.fetch("id")
        when "Organization"
          login = account.fetch("login")
          membership = get("/user/memberships/orgs/#{login}", token)
          membership["state"] == "active" && membership["role"] == "admin" &&
            membership.dig("organization", "id") == account.fetch("id")
        else
          false
        end
      end

      def get(path, token)
        uri = URI("https://api.github.com#{path}")
        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{token}"
        request["Accept"] = "application/vnd.github+json"
        request["X-GitHub-Api-Version"] = "2022-11-28"
        perform(uri, request)
      end

      def perform(uri, request)
        body = +""
        Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 5) do |http|
          http.request(request) do |response|
            raise IOError, "GitHub verification failed" unless response.code.to_i == 200

            response.read_body do |chunk|
              raise IOError, "GitHub verification response exceeded its limit" if body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES

              body << chunk
            end
          end
        end
        data = JSON.parse(body)
        raise TypeError, "Invalid GitHub response" unless data.is_a?(Hash)

        data
      end

      def denied
        Result.err(AppError.new("GitHub installation ownership could not be verified",
                                code: "R403-GITHUB-001", status: :forbidden))
      end
    end
  end
end
