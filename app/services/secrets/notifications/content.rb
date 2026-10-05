# frozen_string_literal: true

module Secrets
  module Notifications
    # Snapshot umano (title/body/url) degli eventi del vault (CYRA-138, Fase 4). MAI il valore del
    # secret in nessuna variante: solo nome, progetto, ambiente, giorni, attore.
    Content = Data.define(:title, :body, :url) do
      # Promemoria di rotazione (pezzo A2), derivato dalla VARIABILE in scadenza (ancora viva).
      def self.for(variable:)
        new(
          title: I18n.t("secrets.notifications.content.title",
                        name: variable.name, project: variable.project.name,
                        environment: variable.environment.label),
          body: body_for(variable),
          url: Rails.application.routes.url_helpers.member_vault_attention_path
        )
      end

      # Stessa formula/wording della pagina "Cosa ruotare" (member.secrets.rotation_due_soon/overdue):
      # un solo posto per la frase, notifica e vista restano coerenti.
      def self.body_for(variable)
        days = variable.rotation_days_until_due
        if variable.rotation_status == :overdue
          I18n.t("member.secrets.rotation_overdue", days: days.abs)
        else
          I18n.t("member.secrets.rotation_due_soon", days: days)
        end
      end

      # Cancellazione di un secret (pezzo B): la variabile è GIA' distrutta al momento della notifica
      # (dispatch asincrono dal job) — name/environment_label sono dati SNAPSHOTTATI dal chiamante
      # PRIMA della distruzione, mai una variabile viva. Il subject della notifica è il progetto
      # (Deliver riceve subject:/project:, non variable:) perché sopravvive.
      def self.for_deletion(project:, name:, environment_label:, actor:)
        new(
          title: I18n.t("secrets.notifications.content.deleted_title",
                        name: name, project: project.name, environment: environment_label,
                        actor: actor_label(actor)),
          body: I18n.t("secrets.notifications.content.deleted_body"),
          url: Rails.application.routes.url_helpers.member_project_secrets_path(project)
        )
      end

      # Sincronizzazione GitHub fallita (pezzo B): evento di progetto/sistema, nessuna variabile
      # coinvolta. `reason` è SEMPRE un codice errore sintetico (AppError#code, es. "R502-GITHUB-001"),
      # MAI il messaggio libero dell'eccezione: i codici sono costanti a valore garantito, i messaggi
      # di trasporto potrebbero in teoria eco-are input arbitrario.
      def self.for_sync_failure(project:, reason: nil)
        new(
          title: I18n.t("secrets.notifications.content.sync_failed_title", project: project.name),
          body: sync_failure_body(reason),
          url: Rails.application.routes.url_helpers.member_project_github_path(project)
        )
      end

      def self.sync_failure_body(reason)
        return I18n.t("secrets.notifications.content.sync_failed_body") if reason.blank?

        I18n.t("secrets.notifications.content.sync_failed_body_with_reason", reason: reason)
      end

      # Nome dell'attore o un'etichetta generica se assente (delete senza actor, es. chiamata di
      # sistema/console) — mai un nil interpolato nel testo.
      def self.actor_label(actor)
        actor&.name || I18n.t("secrets.notifications.content.unknown_actor")
      end

      # Richiesta di modifica in attesa di approvazione (pezzo C2c): notifica chi PUÒ decidere (il
      # dispatch esclude a monte il richiedente). Subject = il progetto, come gli altri secret_* — mai
      # la ChangeRequest stessa. MAI il valore proposto (set o remove che sia).
      def self.for_change_requested(change_request:)
        new(
          title: I18n.t("secrets.notifications.content.change_requested_title",
                        requester: actor_label(change_request.requested_by),
                        action: action_label(change_request.action),
                        name: change_request.name, project: change_request.project.name,
                        environment: change_request.environment.label),
          body: I18n.t("secrets.notifications.content.change_requested_body"),
          url: Rails.application.routes.url_helpers.member_vault_attention_path
        )
      end

      # Richiesta APPROVATA (pezzo C2c): notifica SOLO il richiedente (il dispatch verifica a monte che
      # risolva ancora). url = la tab Secrets del progetto, che mostra lo stato REALE — mai la
      # ChangeRequest, ormai decisa una volta per tutte.
      def self.for_change_approved(change_request:)
        new(
          title: I18n.t("secrets.notifications.content.change_approved_title",
                        name: change_request.name, project: change_request.project.name,
                        environment: change_request.environment.label),
          body: I18n.t("secrets.notifications.content.change_approved_body"),
          url: Rails.application.routes.url_helpers.member_project_secrets_path(change_request.project)
        )
      end

      # Richiesta RIFIUTATA (pezzo C2c): come for_change_approved, ma il corpo porta il motivo del
      # rifiuto (testo libero dell'approvatore, MAI un secret) — il richiedente ne ha bisogno per capire
      # cosa correggere prima di ripresentarla.
      def self.for_change_rejected(change_request:)
        new(
          title: I18n.t("secrets.notifications.content.change_rejected_title",
                        name: change_request.name, project: change_request.project.name,
                        environment: change_request.environment.label),
          body: I18n.t("secrets.notifications.content.change_rejected_body", reason: change_request.reason),
          url: Rails.application.routes.url_helpers.member_project_secrets_path(change_request.project)
        )
      end

      # Proposta di consolidamento (CYRA-777): l'unico contenuto della famiglia che NON nomina un
      # segreto. Non può: la proposta nasce dal valore, e i nomi sono diversi da progetto a progetto —
      # sceglierne uno racconterebbe come lo chiama qualcun altro. Nemmeno i progetti coinvolti, per
      # la stessa ragione per cui l'avviso della riga di comando li tace: la notifica passa da email e
      # Telegram, e «l'organizzazione ha N progetti con lo stesso valore» è tutto ciò che serve per
      # decidere di aprire la pagina.
      def self.for_consolidation(suggestion:)
        new(
          title: I18n.t("secrets.notifications.content.consolidation_title",
                        count: suggestion.projects_count, environment: suggestion.environment.label),
          body: I18n.t("secrets.notifications.content.consolidation_body"),
          url: Rails.application.routes.url_helpers.member_vault_consolidation_path(suggestion)
        )
      end

      def self.action_label(action)
        I18n.t("secrets.notifications.content.action_labels.#{action}")
      end
    end
  end
end
