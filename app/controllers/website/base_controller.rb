# frozen_string_literal: true

module Website
  # Canale WEB PUBBLICO (non autenticato): pagine visibili senza login, es. la status page pubblica
  # di un monitor uptime. Namespace dedicato (rules/backend-channels.md) con il proprio layout.
  class BaseController < ApplicationController
    allow_unauthenticated_access
    layout "website"

    # CYRA-715 — la Content Security Policy blocca ovunque tranne qui, dove resta in sola raccolta.
    # Queste pagine vivono in casa d'altri (badge e status page dentro l'iframe del cliente,
    # dashboard analytics condivisa) e sono la vetrina del prodotto: se un blocco ne rovinasse una,
    # se ne accorgerebbe un visitatore, non noi. Le violazioni continuano ad arrivare al report-uri,
    # che è il modo per decidere anche questo passaggio con i dati invece che con l'ottimismo.
    content_security_policy_report_only

    # Lingue servite dal sito pubblico (EN default senza prefisso URL, IT sotto /it).
    LOCALES = %w[en it].freeze

    around_action :switch_locale

    private

    # Consente l'embed della pagina in un iframe di terzi. Rails serve di default
    # `X-Frame-Options: SAMEORIGIN`: senza toglierlo, uno snippet incollato sul sito del cliente
    # mostrerebbe un riquadro bianco. Si applica SOLO a pagine di questo canale, che sono pubbliche,
    # non autenticate e read-only (nessuna azione da dirottare con un clickjack).
    #
    # CYRA-715 — i due divieti vanno tolti INSIEME: dalla policy globale `frame-ancestors 'self'`
    # dice la stessa cosa di X-Frame-Options ai browser moderni, che anzi le danno la precedenza.
    # Toglierne uno solo lascerebbe l'embed rotto esattamente come prima, e la prova che guarda
    # X-Frame-Options continuerebbe a passare.
    def allow_iframe_embedding
      response.headers.delete("X-Frame-Options")

      policy = current_content_security_policy
      policy.frame_ancestors(false)
      request.content_security_policy = policy
    end

    # Locale per-request dal segmento di route (defaults del blocco marketing in config/routes/website.rb),
    # whitelistato per difesa (un ?locale=xx in query non deve poter sollevare InvalidLocale).
    # with_locale isola il cambio: nessun leak tra richieste servite dallo stesso thread.
    def switch_locale(&action)
      locale = LOCALES.include?(params[:locale].to_s) ? params[:locale] : I18n.default_locale
      I18n.with_locale(locale, &action)
    end
  end
end
