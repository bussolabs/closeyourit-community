# frozen_string_literal: true

module Member
  # Indirizzi inesistenti dell'area (CYRA-462): la rotta catch-all `/member/*` in coda al namespace
  # atterra qui e rende la 404 di prodotto — guscio member, lingua dell'utente, via d'uscita — invece
  # della pagina statica grezza di Rails (public/404.html, inglese e senza collegamenti per tornare).
  class ErrorsController < Member::BaseController
    permission_not_required "Pagina «indirizzo inesistente» dell'area: non legge niente, dice soltanto che quella " \
                            "pagina non c'è."

    def not_found
      render status: :not_found
    end
  end
end
