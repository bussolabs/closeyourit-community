# frozen_string_literal: true

module Secrets
  # CYRA-430 — lo stato REALE dei tre collegamenti automatici del Vault, per la panoramica: la
  # sincronizzazione con GitHub, la lettura dei segreti da riga di comando e direnv. La panoramica
  # scriveva «Sincronizzato · —» mentre il feed diceva «Sincronizzati con GitHub»: la funzione esisteva
  # ma l'area non la dichiarava né diceva da dove si attiva.
  #
  # I due conteggi guardano solo ciò che è successo davvero — un repository che ha spinto almeno un
  # nome, un progetto letto da riga di comando nella finestra recente. direnv NON ha un numero: si
  # abilita nel `.envrc` sul computer di chi sviluppa e non lascia traccia qui dentro. Il rischio
  # dichiarato dal ticket è esattamente questo: meglio nessun dato che un dato falso.
  class Integrations
    # «Attivo» per la CLI vuol dire in uso adesso, non «è successo una volta»: senza finestra un
    # progetto letto una sola volta un anno fa resterebbe per sempre nel conteggio.
    CLI_WINDOW = 30.days

    def initialize(organization:, visible_project_ids:)
      @organization = organization
      @visible_project_ids = Array(visible_project_ids)
    end

    # Progetti visibili il cui repository ha già sincronizzato almeno un segreto. Un repo collegato ma
    # mai sincronizzato (o svuotato dal delete-only-managed) NON conta: il collegamento c'è, la
    # sincronizzazione dei segreti no. Il filtro è in Ruby perché la condizione «almeno un nome in
    # almeno un ambiente» vive dentro il jsonb e le righe sono al più una per progetto visibile.
    def github_projects_count
      return 0 if @visible_project_ids.empty?

      ::Github::Repository.where(project_id: @visible_project_ids)
                          .pluck(:synced_secret_names)
                          .count { |tracked| tracked.to_h.values.any? { |names| Array(names).any? } }
    end

    # Progetti visibili in cui i valori sono stati letti da riga di comando negli ultimi CLI_WINDOW.
    # La lettura dalla matrice web porta `metadata.source: "web"` (Member::ProjectSecretsController):
    # tutto il resto — bundle, download, run — è la CLI. `IS DISTINCT FROM` perché per gli eventi CLI
    # quella chiave non esiste affatto e un `!=` su NULL non seleziona nulla.
    def cli_projects_count
      return 0 if @visible_project_ids.empty?

      ::Secrets::Event.where(organization_id: @organization.id, project_id: @visible_project_ids,
                             action: "read", created_at: CLI_WINDOW.ago..)
                      .where("metadata->>'source' IS DISTINCT FROM 'web'")
                      .distinct
                      .count(:project_id)
    end

    # direnv non è misurabile: la riga lo dice a parole invece di mostrare uno zero che sembrerebbe
    # «nessuno lo usa».
    def direnv_countable? = false
  end
end
