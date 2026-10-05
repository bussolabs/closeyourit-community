# frozen_string_literal: true

module Secrets
  # Ritorna la mappa decifrata { name => value } di tutte le variabili di [progetto, ambiente].
  # È il cuore consumato da `cyi secrets download`/`cyi run` (Fase 1) e dal GitHub sync (Fase 2).
  # La decifratura avviene leggendo `variable.value` (ActiveRecord::Encryption) — chiamare solo dopo
  # aver superato il gate `secrets.read` E il confine ambienti (Secrets::EnvironmentAccess).
  #
  # `account:` (CYRA-79) è CHI sta leggendo, e cambia il risultato: con un account presente si applicano
  # in coda i suoi Secrets::Override, gli scostamenti personali assegnati da chi gestisce il vault.
  # Senza account il bundle è quello "della macchina": esattamente i default del progetto. Il canale che
  # legge PER una persona (CLI) passa Current.account; quello che pubblica verso un sistema
  # (Secrets::Github::Preflight) passa `nil` ESPLICITO — un override personale non deve mai finire nei
  # secret di un repo, dove verrebbe usato da chiunque faccia girare la pipeline.
  class Bundle < ApplicationService
    def initialize(project:, environment:, account: nil)
      @project = project
      @environment = environment
      @account = account
    end

    def call
      map = @project.secret_variables
                    .where(environment: @environment)
                    .ordered
                    .each_with_object({}) { |variable, acc| acc[variable.name] = variable.value }

      ::Secrets::Shared::Delegation
        .joins(shared_value: :shared_variable)
        .includes(shared_value: :shared_variable)
        .where(project: @project, secrets_shared_values: { environment_id: @environment.id })
        # CYRA-777 — `effective_name`, non `name`: se il progetto ha accettato di consolidare
        # tenendosi il suo nome, il bundle deve consegnare quello. Leggere il nome del secret
        # dell'organizzazione gli darebbe una variabile d'ambiente che il suo codice non cerca.
        .find_each { |delegation| map[delegation.effective_name] = delegation.shared_value.value }

      apply_overrides(map)

      Result.ok(map.sort.to_h)
    end

    private

    # Gli override si applicano per ULTIMI: vincono sul default del progetto e anche su un valore
    # delegato dallo shared. È il senso stesso della funzione — «per questa persona qui vale altro» —
    # e un nome che nei default non esiste si aggiunge, invece di essere ignorato.
    def apply_overrides(map)
      return if @account.nil?

      ::Secrets::Override
        .for_read(account: @account, project: @project, environment: @environment)
        .ordered
        .find_each { |override| map[override.name] = override.value }
    end
  end
end
