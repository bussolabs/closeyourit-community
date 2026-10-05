# frozen_string_literal: true

# Helper del sito marketing pubblico: path localizzati (EN default senza prefisso, IT con
# suffisso `_it` nei nomi route — vedi blocco marketing in config/routes/website.rb) per nav, switcher lingua
# e (Fase SEO) alternates hreflang.
#
# CYRA-742 — i tag per i motori di ricerca e il beacon di misura sono due compiti a sé e vivono nelle
# loro parti: Website::SeoTagsHelper e Website::BeaconHelper. Qui restano i percorsi.
module WebsiteHelper
  include Website::SeoTagsHelper
  include Website::BeaconHelper

  # Path di una pagina marketing nel locale richiesto.
  #   website_page_path(:home)                                  → "/" (o "/it")
  #   website_page_path(:feature, slug: "logs", locale: :it)    → "/it/funzionalita/logs"
  #   website_page_path(:integrations)                          → "/integrations"
  def website_page_path(page, locale: I18n.locale, slug: nil, **options)
    suffix = locale.to_s == I18n.default_locale.to_s ? "" : "_#{locale}"
    case page.to_sym
    when :home           then public_send(:"website_root#{suffix}_path", **options)
    when :feature        then public_send(:"website_feature#{suffix}_path", slug, **options)
    when :integrations   then public_send(:"website_integrations#{suffix}_path", **options)
    when :access_request then public_send(:"request_access#{suffix}_path", **options)
    when :privacy        then public_send(:"privacy#{suffix}_path", **options)
    else raise ArgumentError, "pagina marketing sconosciuta: #{page.inspect}"
    end
  end

  # Stessa pagina corrente nell'altro locale (per lo switcher e gli hreflang). La pagina corrente
  # è dichiarata dal controller via @website_page (+ @feature per le pagine feature).
  def website_alternate_path(locale)
    website_page_path(@website_page, locale: locale, slug: @feature&.slug)
  end
end
