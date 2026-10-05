# frozen_string_literal: true

module Member
  # CYRA-745 — le etichette del registro unificato. I verbi dei segreti NON si riscrivono qui: arrivano
  # da `secret_action_label` (CYRA-426, vocabolario unico del Vault), altrimenti la stessa azione si
  # chiamerebbe in due modi a seconda della pagina che la mostra.
  module ActivityHelper
    SOURCE_ICONS = {
      work: "square-pen",
      tickets: "ticket",
      permissions: "shield-half",
      secrets: "key"
    }.freeze

    def activity_source_label(source) = t("member.activity.sources.#{source}")

    def activity_source_icon(source) = SOURCE_ICONS.fetch(source.to_sym, "circle")

    # Il verbo dell'azione. Nessuna azione può mostrare il proprio nome inglese: senza voce si ricade
    # sulla parola generica, come fa il vocabolario del Vault.
    def activity_action_label(row)
      return secret_action_label(row.action) if row.source == :secrets

      activity_action_name(row.source, row.action)
    end

    def activity_action_name(source, action)
      return secret_action_label(action) if source.to_sym == :secrets

      t("member.activity.actions.#{source}.#{action}", default: t("member.activity.actions.unknown"))
    end

    # Le azioni offerte dal filtro. Con un registro scelto restano le sue soltanto: l'elenco intero sono
    # novanta voci di quattro vocabolari diversi, dove la maggior parte non può comparire accanto alle
    # altre.
    #
    # Il nome del registro compare come prefisso SOLO davanti a un'azione che appartiene a quel registro
    # e basta. Metterlo sempre farebbe promettere alla voce un filtro che non esiste: si filtra per
    # azione, e «created» sta sia nel lavoro sia nei ticket — «Lavoro · Creato» avrebbe mostrato anche i
    # ticket aperti, che è peggio di non dire il registro. Le azioni condivise restano col nome generico.
    def activity_action_options
      sources = params[:source].presence ? [ params[:source] ] : Activity::AuditQuery::SOURCES
      by_action = sources.flat_map { |s| Activity::AuditQuery.actions_for(s).map { |a| [ a, s ] } }
                          .group_by(&:first)

      by_action.map do |action, pairs|
        source = pairs.first.last
        label = activity_action_name(source, action)
        [ pairs.one? && sources.size > 1 ? "#{activity_source_label(source)} · #{label}" : label, action ]
      end
    end

    # «Su cosa» porta alla scheda quando il soggetto ne ha una: il ticket e il progetto; il resto è testo.
    def activity_subject_path(row)
      case row.subject
      when Ticketing::Ticket then member_ticket_path(row.subject)
      # A project moved to another organization has no page here (CYRA-879).
      when Projects::Project then member_project_path(row.subject) if row.subject.organization_id == Current.organization&.id
      end
    end

    # Chi ha agito, snapshot-first: il nome inciso sulla riga resiste alla cancellazione dell'account.
    # Nessun attore = l'ha fatto il sistema (un job, una valutazione automatica), non «qualcuno».
    def activity_actor_label(row)
      row.actor_name.presence || row.actor&.name.presence || row.actor&.email.presence ||
        t("member.activity.system")
    end
  end
end
