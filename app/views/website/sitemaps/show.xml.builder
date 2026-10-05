# frozen_string_literal: true

xml.instruct!
xml.urlset "xmlns" => "http://www.sitemaps.org/schemas/sitemap/0.9",
           "xmlns:xhtml" => "http://www.w3.org/1999/xhtml" do
  @entries.each do |entry|
    entry.each_value do |path|
      xml.url do
        xml.loc "#{@base_url}#{path}"
        entry.each do |locale, alt_path|
          xml.tag!("xhtml:link", rel: "alternate", hreflang: locale, href: "#{@base_url}#{alt_path}")
        end
        xml.tag!("xhtml:link", rel: "alternate", hreflang: "x-default", href: "#{@base_url}#{entry.fetch(I18n.default_locale.to_s)}")
      end
    end
  end
end
