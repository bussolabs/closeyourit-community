# frozen_string_literal: true

module Member
  module Vault
    # La pagina di conferma di una proposta di «valore in comune» (CYRA-777).
    #
    # È una PAGINA e non una finestrella, per la stessa ragione della fusione dei gruppi di errori
    # (CYRA-192): il gesto tocca più progetti insieme, toglie una variabile da ciascuno e non si
    # annulla. Chi conferma deve poter leggere prima cosa sparisce, da dove, e con che nome ogni
    # progetto continuerà a leggere quel valore — e poterlo cambiare.
    #
    # `show` non elenca: mostra UNA proposta. L'elenco vive in «Da sistemare», dove convive con tutto
    # il resto che chiede una mossa.
    class ConsolidationsController < Member::BaseController
      before_action :require_shared_secrets_manage
      before_action :set_suggestion

      def show
        @impact = ::Secrets::Consolidation::Impact.call(suggestion: @suggestion).value
        # Il valore che l'organizzazione tiene già, se c'è: cambia cosa dice la pagina (si delega
        # quello, non se ne crea un secondo) e toglie di mezzo la scelta del nome. Risolto qui e non
        # dentro l'impatto perché il NOME non deve entrare nel digest: rinominare il secret
        # dell'organizzazione mentre qualcuno guarda la pagina non rende obsoleta la sua conferma.
        @existing_shared = @impact["shared_value_id"] &&
                           ::Secrets::Shared::Value.includes(:shared_variable).find_by(id: @impact["shared_value_id"])
        # Quante delle copie che stanno per sparire portano una regola «ruota ogni N giorni». La regola
        # è della variabile locale e con lei se ne va: chi conferma deve saperlo prima, non scoprirlo
        # quando l'avviso di rotazione non arriva più. Contato qui e non dentro l'impatto perché non
        # cambia l'operazione: impostare una rotazione mentre qualcuno guarda la pagina non deve
        # rendere obsoleta la sua conferma.
        @rotation_policies = ::Secrets::Variable
          .where(organization_id: current_organization.id, environment_id: @suggestion.environment_id,
                 value_fingerprint: @suggestion.value_fingerprint)
          .with_rotation_policy.count
      end

      def promote
        result = ::Secrets::Consolidation::Promote.call(
          suggestion: @suggestion, actor: Current.account, name: params[:name],
          local_names: local_names, confirmation_digest: params[:confirmation_digest]
        )

        if result.ok?
          redirect_to member_vault_attention_path, notice: t("member.vault_consolidations.promoted")
        else
          # La conferma obsoleta non è un errore di chi ha cliccato: il mondo è cambiato sotto la
          # pagina. Si torna sulla pagina, che ricalcola tutto e mostra lo stato di adesso.
          redirect_to member_vault_consolidation_path(@suggestion), alert: alert_for(result.error)
        end
      end

      def dismiss
        @suggestion.update!(status: :dismissed, dismissed_at: Time.current, dismissed_by: Current.account)
        redirect_to member_vault_attention_path, notice: t("member.vault_consolidations.dismissed")
      end

      private

      # Anti-BOLA: la proposta si risolve DENTRO l'organizzazione corrente. Un id di un'altra
      # organizzazione è un 404, non un 403 — non deve nemmeno confermare che esista.
      def set_suggestion
        @suggestion = ::Secrets::Consolidation::Suggestion
                      .where(organization_id: current_organization.id)
                      .includes(:environment).find(params[:id])
      end

      # { project_id => alias } dal form. I nomi arrivano dal client: si tengono solo quelli dei
      # progetti che la proposta riguarda davvero, e la validazione del formato resta al model.
      #
      # Le chiavi ammesse si elencano una per una, e non con `permit!`: le une sono gli id dei
      # progetti che la proposta tocca — un insieme che il server conosce già — mentre `permit!`
      # accetta qualunque cosa arrivi e lascia al servizio a valle il compito di ignorarla. Il
      # secondo funziona finché quel servizio non cambia; il primo non ha bisogno che nessuno se
      # ne ricordi (rilievo Brakeman: Mass Assignment).
      def local_names
        allowed = ::Secrets::Consolidation::Impact.call(suggestion: @suggestion).value
                    .fetch("projects", []).map { |row| row["project_id"].to_s }
        return {} if allowed.empty?

        params.fetch(:local_names, ActionController::Parameters.new).permit(*allowed).to_h
      end

      def alert_for(error)
        return t("member.vault_consolidations.stale") if error.code == "R409-CONSOLIDATION-001"

        error.message
      end

      # Spostare un valore nei secret dell'organizzazione è il gesto di chi tiene quei secret: stessa
      # chiave della pagina in cui si gestiscono, non un permesso nuovo.
      def require_shared_secrets_manage
        require_permission!("shared_secrets.manage")
      end
    end
  end
end
