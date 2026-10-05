# frozen_string_literal: true

# Una pagina vista dal controllo SEO, sul canale CLI. Sono i fatti raccolti dal giro: cosa ha
# risposto, cosa dichiara, com'è fatta dentro. Nessun giudizio — quello sta nei rilievi.
class SeoPageSerializer < ApplicationSerializer
  attributes :id, :url, :path, :status_code, :title, :meta_description, :canonical_url,
             :robots_directives, :lang, :h1s, :word_count, :images_total, :images_without_alt,
             :internal_links_count, :html_bytes, :response_time_ms, :in_sitemap,
             :first_seen_at, :last_seen_at

  attribute(:redirect_chain) { |page| page.redirect_chain }

  attribute(:project) do |page|
    { id: page.site.project_id, key: page.site.project.key, name: page.site.project.name }
  end
end
