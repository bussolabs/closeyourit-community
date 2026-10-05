# frozen_string_literal: true

module Website
  # I tag che i motori di ricerca leggono su una pagina del sito pubblico: canonical, alternates
  # hreflang, Open Graph, Twitter card e i dati strutturati JSON-LD. L'host viene dalla request, così
  # il canonical resta onesto anche su staging (CYRA-238, CYRA-742).
  module SeoTagsHelper
    # Tag SEO per le pagine marketing (renderizzati dal layout quando @website_page è presente):
    # canonical, alternates hreflang en/it + x-default (→ EN, il default senza prefisso), Open Graph
    # e Twitter card. L'host viene dalla request: canonical onesto anche su staging.
    def website_seo_tags
      canonical = "#{request.base_url}#{website_alternate_path(I18n.locale)}"

      links = [ tag.link(rel: "canonical", href: canonical) ]
      Website::BaseController::LOCALES.each do |locale|
        links << tag.link(rel: "alternate", hreflang: locale, href: "#{request.base_url}#{website_alternate_path(locale)}")
      end
      links << tag.link(rel: "alternate", hreflang: "x-default", href: "#{request.base_url}#{website_alternate_path(I18n.default_locale)}")

      metas = [
        tag.meta(property: "og:site_name", content: "CloseYourIt"),
        tag.meta(property: "og:type", content: "website"),
        tag.meta(property: "og:url", content: canonical),
        tag.meta(property: "og:title", content: content_for(:title)),
        tag.meta(property: "og:description", content: content_for(:meta_description)),
        tag.meta(property: "og:image", content: "#{request.base_url}/og.png"),
        tag.meta(property: "og:locale", content: I18n.locale == :it ? "it_IT" : "en_US"),
        tag.meta(name: "twitter:card", content: "summary_large_image")
      ]

      safe_join(links + metas + website_structured_data_tags(canonical), "\n")
    end

    private
    # JSON-LD (CYRA-238): Organization+WebSite sulla home, SoftwareApplication+BreadcrumbList sulle
    # pagine feature. Nessun altro @website_page (es. status page, che non chiama website_seo_tags)
    # ne riceve. Dati statici/i18n, non input utente — comunque neutralizziamo "</" per non chiudere
    # il <script> in anticipo se mai comparisse in una stringa tradotta.
    def website_structured_data_tags(canonical)
      case @website_page
      when :home    then [ ld_json_tag(organization_ld_json), ld_json_tag(website_ld_json) ]
      when :feature then [ ld_json_tag(software_application_ld_json), ld_json_tag(breadcrumb_list_ld_json(canonical)) ]
      else []
      end
    end

    def organization_ld_json
      {
        "@context" => "https://schema.org",
        "@type" => "Organization",
        "name" => "CloseYourIt",
        "url" => request.base_url,
        "logo" => "#{request.base_url}/icon.svg"
      }
    end

    def website_ld_json
      {
        "@context" => "https://schema.org",
        "@type" => "WebSite",
        "name" => "CloseYourIt",
        "url" => request.base_url
      }
    end

    def software_application_ld_json
      {
        "@context" => "https://schema.org",
        "@type" => "SoftwareApplication",
        "name" => "CloseYourIt",
        "applicationCategory" => "DeveloperApplication",
        "description" => t("website.features.#{@feature.key}.meta_description")
      }
    end

    def breadcrumb_list_ld_json(canonical)
      {
        "@context" => "https://schema.org",
        "@type" => "BreadcrumbList",
        "itemListElement" => [
          { "@type" => "ListItem", "position" => 1, "name" => "CloseYourIt", "item" => "#{request.base_url}#{website_page_path(:home)}" },
          { "@type" => "ListItem", "position" => 2, "name" => t("website.features.#{@feature.key}.name"), "item" => canonical }
        ]
      }
    end

    def ld_json_tag(data)
      tag.script(raw(data.to_json.gsub("</", "<\\/")), type: "application/ld+json")
    end
  end
end
