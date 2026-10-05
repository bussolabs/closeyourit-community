# frozen_string_literal: true

module Uptime
  module Monitors
    # Crea o aggiorna un monitor uptime. Service di dominio CONDIVISO da tutti i canali (Member/Cli) —
    # la logica vive qui sola (`rules/backend-channels.md`). project ed environment si fissano SOLO alla
    # creazione (immutabili dopo: 1 monitor per [progetto, environment]); environment risolto DENTRO il
    # progetto (`@project.environments` → subset dichiarato, anti-BOLA: id fuori scope cade su nil).
    # name NON va impostato: è auto-derivato dal model ("progetto · environment").
    # group_id è MUTABILE (create e update): risolto anti-BOLA dentro l'org del progetto; blank =
    # nessun gruppo. Sentinel :unchanged = non passato (es. canale CLI) → il gruppo resta com'è.
    class Save < ApplicationService
      def initialize(monitor:, attributes:, project: nil, environment_id: nil, group_id: :unchanged, actor: nil)
        @monitor = monitor
        @attributes = attributes
        @project = project
        @environment_id = environment_id
        @group_id = group_id
        @actor = actor
      end

      def call
        @monitor.assign_attributes(@attributes)
        if @monitor.new_record?
          @monitor.project = @project
          @monitor.environment = @project&.environments&.find_by(id: @environment_id)
          @monitor.created_by = @actor
        end
        assign_group unless @group_id == :unchanged

        if @monitor.save
          Result.ok(@monitor)
        else
          Result.err(AppError.new(@monitor.errors.full_messages.to_sentence,
                                  code: "R422-MONITOR-001", status: :unprocessable_content,
                                  details: @monitor.errors.to_hash))
        end
      end

      private

      # Gruppo risolto DENTRO l'org del progetto del monitor (anti-BOLA: un id di un'altra org cade
      # su nil, non su un leak). blank → nessun gruppo.
      def assign_group
        org = @monitor.project&.organization
        @monitor.group = @group_id.present? ? org&.uptime_groups&.find_by(id: @group_id) : nil
      end
    end
  end
end
