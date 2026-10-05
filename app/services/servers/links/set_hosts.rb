# frozen_string_literal: true

module Servers
  module Links
    # Sincronizza gli host collegati a una coppia [progetto, ambiente] con la lista COMPLETA
    # desiderata (multiselect della tab Environments): aggiunge i mancanti, stacca i rimossi.
    # Idempotente; riusa Attach/Detach (la validazione capability/subset/tenant resta sul model
    # Connections::EnvironmentHost). Anti-BOLA: gli host sono filtrati sull'org del progetto — id
    # sconosciuti o di un'altra org cadono. Tutto in una transazione (all-or-nothing).
    class SetHosts < ApplicationService
      def initialize(project:, environment:, host_ids:, actor: nil)
        @project = project
        @environment = environment
        @host_ids = Array(host_ids).reject(&:blank?).map(&:to_s).uniq
        @actor = actor
      end

      def call
        desired = @project.organization.server_hosts.active.where(id: @host_ids).to_a
        desired_ids = desired.map(&:id).to_set
        existing = @project.server_links.where(environment: @environment).to_a
        existing_host_ids = existing.map(&:host_id).to_set
        error = nil

        ApplicationRecord.transaction do
          existing.each { |link| Detach.call(link: link) unless desired_ids.include?(link.host_id) }
          desired.each do |host|
            next if existing_host_ids.include?(host.id)

            result = Attach.call(project: @project, environment: @environment, host:, actor: @actor)
            next if result.ok?

            error = result.error
            raise ActiveRecord::Rollback
          end
        end

        error ? Result.err(error) : Result.ok(true)
      end
    end
  end
end
