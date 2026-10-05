# frozen_string_literal: true

# CYRA-722 — la sospensione di un'organizzazione, applicata sui canali a token (API, riga di comando,
# ingest, sonde). Vive DENTRO le concern di autenticazione, subito dopo il pin di Current.organization:
# è l'unico punto che ogni canale attraversa per forza, quindi nessun controller — nemmeno uno scritto
# domani — può dimenticarsi del controllo. Un `before_action` nelle basi non andrebbe: la superclasse
# registra i propri callback PRIMA di quelli dei figli, e girerebbe con l'organizzazione ancora nil.
#
# Il rifiuto è un 403 con un codice suo, non un 401: la credenziale è valida e ripresentarla non
# cambierà niente finché l'organizzazione resta sospesa. Confondere i due esiti manderebbe un SDK a
# rinnovare all'infinito un token che non ha alcun problema.
module OrganizationSuspension
  extend ActiveSupport::Concern

  SUSPENDED_ERROR_CODE = "R403-ORGANIZATION-002"

  private

  def suspended_organization? = Current.organization&.suspended? || false

  # Rende il 403 e torna true quando l'organizzazione è sospesa: il chiamante deve fermarsi lì.
  def reject_suspended_organization!
    return false unless suspended_organization?

    render_error(SUSPENDED_ERROR_CODE, "Organizzazione sospesa", status: :forbidden)
    true
  end
end
