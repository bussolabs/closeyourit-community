# frozen_string_literal: true

module Member
  module Vault
    # Ricerca cross-progetto delle variabili segrete per NOME (CYRA-137, poi CYRA-424): risponde a
    # "dove è (e dove MANCA) VAR_X" tra i progetti VISIBILI dell'utente. Gate = sola visibilità progetti
    # (visible.projects, anti-BOLA come gli altri index member) — NESSUN permesso secrets.read:
    # non si espone alcun VALORE, solo la presenza del nome in [progetto, ambiente]. La logica (matrice
    # progetto × ambiente con le assenze, filtri, ordinamento, paginazione) vive in Secrets::VariableSearch.
    # Include variabili locali e condivise effettivamente delegate, con il nome usato dal progetto.
    class VariableSearchController < Member::BaseController
      permission_not_required "Cerca dove esiste il NOME di una variabile fra i progetti visibili: nessun valore " \
                              "viene mostrato."

      # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
      remembers_filters :project, :environment, :q, only: :index

      def index
        @search = ::Secrets::VariableSearch.call(
          projects: visible.projects,
          query: params[:q],
          project_id: params[:project],
          environment_code: params[:environment],
          sort: params[:sort],
          page: params[:page],
          per: params[:per]
        )
      end
    end
  end
end
