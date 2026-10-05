# frozen_string_literal: true

module Website
  # Dashboard analytics PUBBLICA / embed (read-only, NON autenticata). Accesso via slug imprevedibile
  # (capability); link inesistente o revocato → 404 (MAI 403, non si rivela l'esistenza). Se il link è
  # protetto da password mostra un form (POST per verificare). Espone SOLO aggregati (Analytics::Snapshot):
  # mai visitor_hash/IP, mai config interna. Iframe-friendly (X-Frame-Options rimosso) per l'embed.
  class AnalyticsController < BaseController
    def show
      link = ::Analytics::Link.active.find_by(slug: params[:slug])
      return head(:not_found) if link.nil?

      response.headers["Cache-Control"] = "no-store"

      if link.password_protected? && !authorized?(link)
        @slug = link.slug
        @failed = request.post?
        return render(:password, status: @failed ? :unauthorized : :ok)
      end

      allow_iframe_embedding
      @project = link.project
      @slug = link.slug
      @range = ::Analytics::Pageview::BUCKETS.key?(params[:range]) ? params[:range] : ::Analytics::Pageview::DEFAULT_RANGE
      query = ::Analytics::Query.new(project_id: @project.id, range: @range, environment: nil)
      @snapshot = ::Analytics::Snapshot.call(query: query, project: @project)
    end

    private

    def authorized?(link)
      request.post? && link.authenticate(params[:password].to_s)
    end
  end
end
