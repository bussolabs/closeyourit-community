# frozen_string_literal: true

module Agents
  module Workflows
    # Il freno prima della produzione (CYRA-871): un rilascio parte solo dopo WINDOW dalla prova dello
    # staging, e non parte se nel frattempo è comparso in staging un errore nuovo ancora aperto.
    # Risolvere o ignorare quell'errore toglie il freno: è la leva di chi decide.
    #
    # Come ProductionLock, il predicato è scritto in SQL per la coda e in Ruby per la presa in carico,
    # sulla stessa relazione di errori: una copia sola di cosa vuol dire «errore nuovo in staging».
    class ProductionHold
      WINDOW = 2.hours
      STAGING = "staging"

      # Vero quando il freno è libero, per la riga esterna di agents_workflows + ticketing_tickets.
      def self.released_sql(now:)
        errors = new_staging_errors(project: Ticketing::Ticket.arel_table[:project_id],
                                    since: Agents::Workflow.arel_table[:closer_staging_verified_at])
        ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, now - WINDOW ])
          agents_workflows.closer_staging_verified_at <= ?
          AND NOT EXISTS (#{errors.select(1).to_sql})
        SQL
      end

      # Perché la produzione aspetta, o nil a freno libero.
      def self.reason(workflow, now:)
        verified_at = workflow.closer_staging_verified_at
        return if verified_at.nil?
        return { reason: "staging_soak", until: verified_at + WINDOW } if now < verified_at + WINDOW

        group_id = new_staging_errors(project: workflow.ticket.project_id, since: verified_at)
                   .order(:first_seen_at).pick(:id)
        { reason: "staging_errors", error_group_id: group_id } if group_id
      end

      # `project` e `since` sono una colonna della riga esterna (coda) o un valore (presa in carico).
      def self.new_staging_errors(project:, since:)
        groups = Errors::Group.arel_table
        events = Errors::Event.arel_table
        staging_events = Errors::Event.where(events[:group_id].eq(groups[:id]))
                                      .where(environment: STAGING)
                                      .where(events[:occurred_at].gteq(since))
        Errors::Group.status_unresolved
                     .where(groups[:project_id].eq(project))
                     .where(groups[:first_seen_at].gteq(since))
                     .where(staging_events.arel.exists)
      end
      private_class_method :new_staging_errors
    end
  end
end
