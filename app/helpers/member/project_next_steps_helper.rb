# frozen_string_literal: true

module Member
  # Le proposte della panoramica di progetto (CYRA-361). La pagina mostrava il problema — dodici
  # errori aperti e nessun ticket, un ambiente senza controllo di disponibilità — e lasciava che
  # fosse chi legge ad andarsi a cercare altrove il posto dove agire.
  #
  # Due regole, dal rischio dichiarato nel ticket: ogni proposta compare SOLO se la sua condizione è
  # vera, e non se ne mostrano più di MAX_STEPS per schermata. Un elenco che si accende sempre è
  # rumore, e toglie alla panoramica la calma che è la sua qualità migliore.
  module ProjectNextStepsHelper
    MAX_STEPS = 3

    def project_next_steps(project:, stats:, top_error_group:, supports_uptime:, monitors_count:,
                           environments_without_monitor: [], first_run: false, environments_count: 0,
                           active_tokens_count: 0, repository_connectable: false)
      steps = []
      if first_run
        steps.concat(first_run_steps(project, environments_count:, active_tokens_count:, repository_connectable:))
      end
      steps << error_to_ticket_step(project, top_error_group) if stats.total.zero? && top_error_group
      steps << first_monitor_step(project) if supports_uptime && monitors_count.to_i.zero?
      steps.concat(environment_monitor_steps(project, environments_without_monitor)) if supports_uptime && monitors_count.to_i.positive?
      steps.compact.first(MAX_STEPS)
    end

    private

    # CYRA-575 — I passi della PRIMA ACCENSIONE. Il progetto appena creato era l'unico a non ricevere
    # nessuna proposta: le regole di sopra chiedono tutte dei dati (un errore, un monitor, un ambiente
    # scoperto) che un progetto nuovo per definizione non ha ancora. Il consiglio arrivava a chi non ne
    # aveva bisogno e mancava a chi ne avrebbe.
    #
    # Valgono SOLO durante la prima accensione (`first_run`, deciso dal controller: nessun ticket e
    # nessuna telemetria in arrivo). Un progetto vivo che di proposito non usa GitHub leggerebbe
    # altrimenti «collega il repository» per sempre: un rimprovero fisso, non un aiuto.
    #
    # L'ordine è quello del lavoro: senza un ambiente dichiarato un token non ha a cosa legarsi, e il
    # repository viene dopo. Il tetto di MAX_STEPS resta quello di prima.
    def first_run_steps(project, environments_count:, active_tokens_count:, repository_connectable:)
      steps = []
      steps << declare_environment_step(project) if environments_count.to_i.zero?
      steps << first_token_step(project) if active_tokens_count.to_i.zero?
      steps << connect_repository_step(project) if repository_connectable
      steps
    end

    # Nessun ambiente dichiarato: è la dichiarazione da cui dipendono token, controlli e release.
    def declare_environment_step(project)
      return nil unless can?("projects.edit", scope: project)

      { key: "setup-environment",
        label: t("member.projects.next_steps.setup_environment"),
        cta: t("member.projects.next_steps.setup_environment_cta"),
        href: member_project_environments_path(project), icon: "layers" }
    end

    # Nessun token attivo: finché non ne esiste uno il progetto non può ricevere niente da fuori.
    def first_token_step(project)
      return nil unless can?("tokens.manage", scope: project)

      { key: "setup-token",
        label: t("member.projects.next_steps.setup_token"),
        cta: t("member.projects.next_steps.setup_token_cta"),
        href: member_project_tokens_path(project), icon: "key" }
    end

    # Repository non collegato. Il passo esiste solo se l'organizzazione ha davvero l'integrazione
    # GitHub (lo decide il controller): proporre un collegamento che non si può fare è peggio del
    # silenzio, perché porta a una pagina che chiede un'altra cosa ancora.
    def connect_repository_step(project)
      return nil unless can?("github.manage", scope: project)

      { key: "setup-repository",
        label: t("member.projects.next_steps.setup_repository"),
        cta: t("member.projects.next_steps.setup_repository_cta"),
        href: member_project_github_path(project), icon: "git-branch" }
    end

    # Errori aperti e nessun ticket: l'errore più frequente diventa un ticket con un clic, dallo
    # stesso gesto (e dallo stesso gate) che esiste sulla pagina dell'errore.
    def error_to_ticket_step(project, group)
      return nil unless can?("errors.promote", scope: project)

      { key: "error-to-ticket",
        label: t("member.projects.next_steps.error_to_ticket", title: group.title.to_s.truncate(70)),
        cta: t("member.projects.next_steps.error_to_ticket_cta"),
        href: promote_member_monitoring_error_group_path(group),
        method: :post, icon: "ticket", confirm: t("member.monitoring.promote_confirm") }
    end

    # Nessun controllo di disponibilità: la riga che oggi dice solo "—" porta dove si creano.
    def first_monitor_step(project)
      return nil unless can?("uptime.manage", scope: project)

      { key: "first-monitor",
        label: t("member.projects.next_steps.first_monitor"),
        cta: t("member.projects.next_steps.first_monitor_cta"),
        href: member_monitoring_monitors_path(project_id: [ project.id ]), icon: "heart-pulse" }
    end

    # Un ambiente scoperto per volta, coi filtri già impostati su progetto e ambiente.
    def environment_monitor_steps(project, environments)
      return [] unless can?("uptime.manage", scope: project)

      environments.first(MAX_STEPS).map do |environment|
        { key: "monitor-#{environment.id}",
          label: t("member.projects.next_steps.environment_monitor", environment: environment.label),
          cta: t("member.projects.next_steps.first_monitor_cta"),
          href: member_monitoring_monitors_path(project_id: [ project.id ], environment_id: [ environment.id ]),
          icon: "heart-pulse" }
      end
    end
  end
end
