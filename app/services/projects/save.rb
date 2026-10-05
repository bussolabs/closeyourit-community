# frozen_string_literal: true

module Projects
  # Crea o aggiorna un progetto: attributi base + dimensioni org-scoped (group/platforms/environments).
  # Service di dominio CONDIVISO da tutti i canali (Member/Cli) — la logica vive qui sola
  # (`rules/backend-channels.md`). Le dimensioni sono opzionali col sentinel `UNSET` = "non toccare"
  # (update parziale); passare un valore (anche blank/array vuoto) le riscrive. Anti-BOLA:
  # group/platforms/environments sono filtrati sull'`organization` (id di altre org cadono).
  class Save < ApplicationService
    UNSET = :__unset__

    def initialize(project:, organization:, attributes:, actor: nil, true_actor: nil,
                   group_id: UNSET, platform_ids: UNSET, environment_ids: UNSET)
      @project = project
      @organization = organization
      @attributes = attributes
      @actor = actor
      @true_actor = true_actor
      @group_id = group_id
      @platform_ids = platform_ids
      @environment_ids = environment_ids
    end

    def call
      was_new = @project.new_record?
      # Salvataggio + evento di attività atomici (audit all-or-nothing).
      ApplicationRecord.transaction do
        # Protocollo dispatch: il project è l'ultimo lock di Reserve
        # (policy → host → agent → project). Le modifiche del gruppo prendono soltanto questo lock,
        # così la verifica dei target di gruppo vede sempre uno stato serializzato senza ordine inverso.
        @project.lock! unless was_new
        @project.assign_attributes(@attributes)
        @project.created_by ||= @actor if was_new
        assign_group unless @group_id == UNSET
        @project.platform_ids = scoped_ids(@organization.platforms, @platform_ids) unless @platform_ids == UNSET
        @project.environment_ids = scoped_ids(@organization.environments, @environment_ids) unless @environment_ids == UNSET
        @project.save!
        grant_creator_access if was_new
        record_activity(was_new)
      end
      Result.ok(@project)
    rescue ActiveRecord::RecordInvalid
      Result.err(AppError.new(@project.errors.full_messages.to_sentence,
                              code: "R422-PROJECT-001", status: :unprocessable_content,
                              details: @project.errors.to_hash))
    end

    private

    # Creating a project grants its visibility, never new permissions or access to other projects.
    def grant_creator_access
      return unless @actor&.member_of_organization?(@organization.id)

      @actor.project_memberships.find_or_create_by!(project: @project)
    end

    # Emette l'evento nel log generalizzato: "created" alla creazione; "updated" solo se sono
    # cambiate colonne reali (niente evento-rumore su submit senza modifiche). I campi cambiati
    # finiscono in data["fields"] per la frase della cronologia.
    def record_activity(was_new)
      if was_new
        Activity::Record.call(subject: @project, action: "created", actor: @actor, true_actor: @true_actor)
      else
        changed = @project.saved_changes.keys - %w[updated_at created_at]
        return if changed.empty?

        Activity::Record.call(subject: @project, action: "updated", data: { fields: changed },
                              actor: @actor, true_actor: @true_actor)
      end
    end

    # Group accettato solo se è un gruppo dell'org corrente, altrimenti nil. Blank → nil.
    def scoped_group_id
      @organization.groups.where(id: @group_id.presence).pick(:id)
    end

    def assign_group
      requested_group_id = scoped_group_id
      group_ids = [ @project.group_id, requested_group_id ].compact.uniq
      locked_group_ids = @organization.groups.where(id: group_ids).order(:id).lock.ids
      @project.group_id = locked_group_ids.include?(requested_group_id) ? requested_group_id : nil
    end

    def scoped_ids(relation, ids)
      relation.where(id: Array(ids).reject(&:blank?)).ids
    end
  end
end
