# frozen_string_literal: true

require "net/http"

module Wikitech
  # Reads the public data of a GitHub repository (CYRA-1129) through the unauthenticated REST API:
  # any repository a card names, not only the ones an organization connected. That API allows 60
  # calls per hour, so a refused call says how long to wait instead of failing.
  class GithubRepo < ApplicationService
    API = "https://api.github.com/repos/"
    NOT_FOUND = "R404-WIKITECH-002"
    UNAVAILABLE = "R503-WIKITECH-001"

    # Asks the job to come back later: GitHub refused for now, the fact was not observed.
    class RateLimited < StandardError
      attr_reader :retry_after

      def initialize(retry_after)
        super("GitHub rate limit, retry in #{retry_after}s")
        @retry_after = retry_after
      end
    end

    def initialize(repo_url:)
      @repo_url = repo_url
    end

    def call
      response = request
      case response.code.to_i
      when 200 then Result.ok(meta(JSON.parse(response.body)))
      when 404, 451 then Result.err(AppError.new("Repository not found", code: NOT_FOUND, status: :not_found))
      when 403, 429 then raise RateLimited, retry_after(response)
      else Result.err(AppError.new("GitHub answered #{response.code}", code: UNAVAILABLE, status: :service_unavailable))
      end
    end

    private

    def request
      uri = URI("#{API}#{Wikitech::RepoUrl.full_name(@repo_url)}")
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) do |http|
        http.get(uri.request_uri, "Accept" => "application/vnd.github+json", "User-Agent" => "CloseYourIt-Wikitech")
      end
    end

    def meta(repo)
      { "full_name" => repo["full_name"], "stars" => repo["stargazers_count"],
        "license" => license(repo),
        "language" => repo["language"], "pushed_at" => repo["pushed_at"],
        "archived" => repo["archived"], "description" => repo["description"],
        "fetched_at" => Time.current.iso8601 }
    end

    # GitHub says NOASSERTION when it cannot tell the license: that is no license to show.
    def license(repo)
      spdx = repo.dig("license", "spdx_id").presence
      spdx unless spdx == "NOASSERTION"
    end

    def retry_after(response)
      seconds = response["retry-after"].to_i
      return seconds if seconds.positive?

      reset = response["x-ratelimit-reset"].to_i
      reset.positive? ? [ reset - Time.current.to_i, 60 ].max : 3600
    end
  end
end
