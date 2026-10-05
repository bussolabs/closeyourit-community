# frozen_string_literal: true

module Projects
  module Moves
    # Per-organization lookups used by the moved rows, matched by code in the destination;
    # the missing ones are created there with the same attributes (CYRA-879).
    class LookupMap
      MODELS = {
        "types_environments" => Types::Environment,
        "types_ticket_statuses" => Types::TicketStatus,
        "types_ticket_priorities" => Types::TicketPriority,
        "types_platforms" => Types::Platform,
        "types_feature_statuses" => Types::FeatureStatus
      }.freeze

      COPIED_ATTRIBUTES = %w[code label color position active category animated review_gate
                             approval_required secrets_enabled servers_enabled uptime_enabled
                             supports_analytics supports_session_replay supports_uptime].freeze

      def initialize(subject:, destination:)
        @subject = subject
        @destination = destination
      end

      # Rows the destination lacks and apply! will create (CYRA-879).
      def missing
        used_rows.flat_map do |table, rows|
          existing = destination_ids(table)
          rows.reject { existing.key?(_1.code) }.map { { table:, code: _1.code, label: _1.label } }
        end
      end

      # { lookup_table => { source_id => destination_id } }, creating the missing rows (CYRA-879).
      def apply!
        used_rows.to_h do |table, rows|
          existing = destination_ids(table)
          [ table, rows.to_h { [ _1.id, existing[_1.code] || create_copy(table, _1) ] } ]
        end
      end

      # How a table's rows are reached from the moved subject: by project, ticket or feature category (CYRA-879).
      def scope_sql(table)
        columns = connection.columns(table).map(&:name)
        return "project_id IN (:projects)" if columns.include?("project_id")
        return "source_project_id IN (:projects)" if columns.include?("source_project_id")
        return "ticket_id IN (:tickets)" if columns.include?("ticket_id")

        return unless columns.include?("feature_id")

        "feature_id IN (SELECT id FROM product_features WHERE category_id IN " \
          "(SELECT id FROM product_categories WHERE group_id IN (:groups)))"
      end

      private

      def used_rows
        @used_rows ||= used_ids.to_h { |table, ids| [ table, MODELS.fetch(table).where(id: ids).to_a ] }
      end

      def used_ids
        ids = Hash.new { |hash, key| hash[key] = [] }
        Registry::LOOKUPS.each do |table, columns|
          columns.each do |column, lookup|
            ids[lookup] |= connection.select_values(distinct_values_sql(table, column))
          end
        end
        ids["types_environments"] |= shared_file_environment_ids
        ids
      end

      # A shared file lent to a moved project is copied with its environment, so that one counts too (CYRA-879).
      def shared_file_environment_ids
        Secrets::Asset.where(project_id: nil, id: Secrets::AssetDelegation.where(project_id: @subject.project_ids).select(:asset_id))
                      .where.not(environment_id: nil).distinct.pluck(:environment_id)
      end

      # Table and column names come from Registry::LOOKUPS, quoted anyway; ids are bound (CYRA-879).
      def distinct_values_sql(table, column)
        quoted = connection.quote_column_name(column)
        binds = { projects: @subject.project_ids, tickets: @subject.ticket_ids.presence || [ nil ],
                  groups: @subject.group_ids.presence || [ nil ] }
        ApplicationRecord.sanitize_sql_array(
          [ "SELECT DISTINCT #{quoted} FROM #{connection.quote_table_name(table)} " \
            "WHERE #{scope_sql(table)} AND #{quoted} IS NOT NULL", binds ]
        )
      end

      def destination_ids(table)
        @destination_ids ||= {}
        @destination_ids[table] ||= MODELS.fetch(table).where(organization_id: @destination.id).pluck(:code, :id).to_h
      end

      def create_copy(table, row)
        attributes = row.attributes.slice(*COPIED_ATTRIBUTES).merge("organization_id" => @destination.id)
        MODELS.fetch(table).create!(attributes).id
      end

      def connection = ApplicationRecord.connection
    end
  end
end
