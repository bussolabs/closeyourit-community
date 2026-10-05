# frozen_string_literal: true

module Authorization
  module PreviewAccess
    # Costruttori condivisi delle strutture di diff a partire da due Snapshot (current, pending).
    # Incluso da PreviewAccess::Member e ::Team. Ordine chiavi = ordine Catalog (stabile per la UI).
    module Diffing
      def diff_rows(projects, current, pending)
        projects.map do |project|
          Authorization::MatrixRow.new(
            project: project,
            current_keys: current.keys_for(project.id),
            pending_keys: pending.keys_for(project.id)
          )
        end
      end

      def diff_org_cells(current, pending)
        Authorization::AccessMatrix::ORG_KEYS.map do |key|
          Authorization::OrgCell.new(
            key: key,
            current: current.org_keys.include?(key),
            pending: pending.org_keys.include?(key)
          )
        end
      end

      def snapshot(account, projects)
        Authorization::AccessMatrix.call(account: account, organization: @organization, projects: projects)
      end
    end
  end
end
