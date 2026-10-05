# frozen_string_literal: true

# Localizza ogni richiesta del controller nella lingua dell'utente corrente.
# `around_action` per non far mai "colare" il locale tra richieste servite dallo stesso thread
# (I18n.with_locale lo isola). La sorgente di default è la preferenza dell'account autenticato
# (Current.account impostato dall'autenticazione, che gira prima); i canali pre-login (Auth)
# sovrascrivono #request_locale con una sorgente diversa (es. Accept-Language).
module Localizable
  extend ActiveSupport::Concern

  included do
    around_action :switch_locale
  end

  private

  def switch_locale(&action)
    I18n.with_locale(request_locale, &action)
  end

  # Locale della richiesta: la preferenza dell'account corrente, con fallback al default I18n
  # (nessun account, o preferenza non impostata/non ammessa). Override nei canali pre-login.
  def request_locale
    Current.account&.effective_locale || I18n.default_locale
  end

  # Prima lingua di Accept-Language che combacia con le locali supportate (App::Constants::LOCALES),
  # o nil. Sorgente best-effort (nessuna gem) per i canali senza account: pre-login (Auth) e pagine di
  # errore aperte da sloggati. La whitelist rende innocuo un header non attendibile (mai InvalidLocale).
  def browser_locale
    Localizable.browser_locale(request)
  end

  # Stessa sorgente per chi non include il concern: Authentication#request_authentication.
  def self.browser_locale(request)
    request.env["HTTP_ACCEPT_LANGUAGE"].to_s.scan(/[a-z]{2}/i)
           .map(&:downcase).find { |tag| App::Constants::LOCALES.include?(tag) }
  end
end
