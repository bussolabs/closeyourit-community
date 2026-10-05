# frozen_string_literal: true

module Member
  # CYRA-418 — le righe delle attività del Vault, scritte per intero. La panoramica rendeva
  # «Sincronizzato · —»: un trattino al posto di un oggetto che il sistema conosce già, perché la riga
  # mostrava solo azione e nome e certi eventi un nome non ce l'hanno (una sincronizzazione riguarda
  # tutto il progetto, non una variabile). Qui la frase si compone dai pezzi che ci sono davvero —
  # azione, oggetto, ambiente, progetto, chi l'ha fatta — e quando un pezzo manca semplicemente non
  # compare, invece di lasciare un buco.
  #
  # CYRA-430 — e il verbo di quella riga porta alla funzione che nomina: leggere che qualcosa «è stato
  # sincronizzato» senza poter scoprire da dove si attiva quella sincronizzazione era metà del difetto.
  module VaultHelper
    # Icone delle funzioni di «Cosa puoi fare qui», nell'ordine del controller.
    CAPABILITY_ICONS = {
      cli_read: "terminal",
      github_sync: "git-branch",
      personal_direnv: "folder-open",
      unlock_row: "lock-open",
      history_rollback: "history",
      four_eyes: "user-check",
      read_audit: "eye"
    }.freeze

    # Azione di un evento → funzione che quell'evento mette in atto. `imported` non ha una funzione
    # propria nell'elenco: resta senza collegamento, invece di puntare a qualcosa che non la spiega.
    EVENT_CAPABILITIES = {
      "synced" => :github_sync,
      "read" => :read_audit,
      "set" => :unlock_row,
      "deleted" => :unlock_row
    }.freeze

    def vault_event_sentence(row, projects: {}, environments: {})
      "#{secret_action_label(row.action)}#{vault_event_complement(row, projects: projects, environments: environments)}"
    end

    # La stessa riga, col verbo che porta alla funzione che nomina (CYRA-430). Le azioni senza una
    # funzione nell'elenco restano testo semplice: un collegamento che non spiega nulla è peggio della
    # sua assenza.
    def vault_event_line(row, projects: {}, environments: {})
      complement = vault_event_complement(row, projects: projects, environments: environments)
      path = vault_event_capability_path(row.action)
      return "#{secret_action_label(row.action)}#{complement}" if path.nil?

      safe_join([ link_to(secret_action_label(row.action), path,
                          class: "underline decoration-dotted decoration-gray-300 underline-offset-2 hover:text-indigo-700 dark:hover:text-indigo-300",
                          data: { test: "vault-overview-event-feature" }), complement ])
    end

    # Chi ha fatto l'azione: una persona o il sistema. Mai vuoto.
    def vault_event_actor(row) = row.actor&.name.presence || row.actor&.email.presence || t("member.vault_audit.system")

    # Indirizzo della funzione dentro «Cosa puoi fare qui», o nil se quell'azione non ne nomina una.
    def vault_event_capability_path(action)
      feature = EVENT_CAPABILITIES[action.to_s]
      feature && member_vault_capabilities_path(anchor: vault_capability_anchor(feature))
    end

    def vault_capability_anchor(feature) = "vault-capability-#{feature.to_s.dasherize}"

    def vault_capability_icon(feature) = CAPABILITY_ICONS.fetch(feature, "circle")

    # I comandi mostrati come esempio arrivano da Secrets::UsageSnippets, il punto UNICO in cui i
    # comandi `cyi` sono definiti (CYRA-401): se la CLI cambia si aggiorna lì e questa pagina si
    # allinea da sola. Le funzioni che si compiono con un gesto nella pagina non hanno comandi — il
    # loro esempio è scritto a parole nelle traduzioni.
    def vault_capability_commands(feature)
      case feature
      when :cli_read then project_usage_snippets.local
      when :github_sync then project_usage_snippets.ci_github
      when :personal_direnv then personal_usage_snippets.local + personal_usage_snippets.local_direnv
      else []
      end
    end

    # Dove si usa la funzione. Le due destinazioni gated hanno un ripiego che resta vero: senza il
    # permesso di sorveglianza le letture registrate si vedono comunque sui propri segreti personali, e
    # senza progetti da gestire la seconda approvazione si accende dalle impostazioni del progetto.
    def vault_capability_link(feature)
      case feature
      when :cli_read, :unlock_row, :history_rollback then [ member_vault_projects_path, "open_projects" ]
      when :github_sync then [ member_projects_path, "open_project_github" ]
      when :personal_direnv then [ member_personal_secrets_path, "open_personal" ]
      when :four_eyes then four_eyes_capability_link
      when :read_audit then read_audit_capability_link
      end
    end

    private

    # Tutto ciò che nella riga segue il verbo: l'oggetto quando c'è, poi ambiente e progetto. Un pezzo
    # che manca non lascia un buco — semplicemente non compare (CYRA-418).
    def vault_event_complement(row, projects: {}, environments: {})
      context = [ environments[row.environment_id]&.label, projects[row.project_id]&.name ].compact
      complement = row.name.present? ? " #{row.name}" : ""
      complement += " · #{context.join(' · ')}" if context.any?
      complement
    end

    def four_eyes_capability_link
      if vault_change_requests_nav_visible?
        [ member_vault_attention_path, "open_attention" ]
      else
        [ member_projects_path, "open_project_settings" ]
      end
    end

    def read_audit_capability_link
      if can?("secrets_audit.view")
        [ member_vault_audit_path, "open_audit" ]
      else
        [ member_personal_secrets_path, "open_personal_activity" ]
      end
    end

    def project_usage_snippets = @project_usage_snippets ||= ::Secrets::UsageSnippets.new(kind: :project)
    def personal_usage_snippets = @personal_usage_snippets ||= ::Secrets::UsageSnippets.new(kind: :personal)
  end
end
