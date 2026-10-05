# frozen_string_literal: true

module Auth
  # Controller pubblici (login, reset password, accept invito): nessuna autenticazione richiesta.
  # La registrazione self-service non è fra questi: le rotte /signup sono state rimosse (CYRA-249).
  # Pre-login non c'è Current.account → la lingua si deduce dall'header Accept-Language del browser
  # (best-effort, nessuna gem), con fallback al default I18n.
  class BaseController < ApplicationController
    include Localizable

    allow_unauthenticated_access
    layout "auth"

    private

    # Override di Localizable#request_locale: pre-login non esiste una preferenza account. Prende la
    # lingua dichiarata dal browser (Localizable#browser_locale), altrimenti il default I18n.
    def request_locale
      browser_locale || I18n.default_locale
    end
  end
end
