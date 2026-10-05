# frozen_string_literal: true

# CYRA-883 — h1–h3 of a markdown text get stable ids (`<prefix>-<slug>`), so a page can offer an index
# of the sections of a long text and link to each one.
module MarkdownAnchorsHelper
  def anchor_headings(html, prefix:)
    fragment = Nokogiri::HTML5.fragment(html)
    headings_with_ids(fragment, prefix).each do |node, id|
      node["id"] = id
      node["class"] = [ node["class"], "scroll-mt-6" ].compact.join(" ")
    end
    fragment.to_html.html_safe
  end

  def markdown_headings(text, prefix:)
    fragment = Nokogiri::HTML5.fragment(render_markdown(text))
    headings_with_ids(fragment, prefix).map { |node, id| { title: node.text.strip, id: } }
  end

  private

  def headings_with_ids(fragment, prefix)
    seen = Hash.new(0)
    fragment.css("h1, h2, h3").map do |node|
      slug = node.text.parameterize.presence || "section"
      seen[slug] += 1
      [ node, [ prefix, slug, (seen[slug] if seen[slug] > 1) ].compact.join("-") ]
    end
  end
end
