# frozen_string_literal: true

module Projects
  module Moves
    # Rows of a moved subject that point to what the source organization keeps:
    # deleted, or their link set to NULL, as Registry::DETACH says (CYRA-879).
    module Detach
      # Chat::MessageReference::ALLOWED_TYPES: a moved target is in an id list, or its row has a
      # moved project_id, checked row by row so no moved project's table is scanned (CYRA-879).
      REFERABLE_IDS = { "Projects::Project" => ":projects", "Ticketing::Ticket" => ":tickets" }.freeze
      REFERABLE_TABLES = { "Errors::Group" => "errors_groups", "Metrics::Group" => "metrics_groups",
                           "Logs::Entry" => "logs_entries", "Uptime::Monitor" => "uptime_monitors" }.freeze

      # First matching column wins: a row with a project link belongs to the subject through it (CYRA-879).
      COLUMN_PREDICATES = [
        [ "project_id", "project_id IN (:projects)" ],
        [ "source_project_id", "source_project_id IN (:projects)" ],
        [ "ticket_id", "ticket_id IN (:tickets)" ],
        [ "group_id", "group_id IN (:groups)" ],
        [ "feature_id", "feature_id IN (SELECT id FROM product_features WHERE category_id IN " \
                        "(SELECT id FROM product_categories WHERE group_id IN (:groups)))" ]
      ].freeze

      module_function

      # Rows whose <prefix>_type/<prefix>_id point to one of the given types, among the moved ids (CYRA-879).
      def polymorphic_sql(prefix, types = Registry::SUBJECT_IDS)
        types.map { |type, ids| "(#{prefix}_type = '#{type}' AND #{prefix}_id IN (#{ids}))" }.join(" OR ")
      end

      # A reference crosses organizations when exactly one side moves: its message or its target.
      # COALESCE: an empty id list binds NULL, and NOT (NULL) would keep a crossing row (CYRA-879).
      def crossing_references_sql
        moved = "COALESCE(message_id IN (SELECT id FROM chat_messages WHERE conversation_id IN " \
                "(SELECT id FROM chat_conversations WHERE #{polymorphic_sql('contextable')})), FALSE)"
        target = "COALESCE(#{polymorphic_sql('referable', REFERABLE_IDS)} OR #{owned_referables_sql}, FALSE)"
        "((#{moved}) AND NOT (#{target})) OR (NOT (#{moved}) AND (#{target}))"
      end

      def owned_referables_sql
        REFERABLE_TABLES.map do |type, table|
          "(referable_type = '#{type}' AND EXISTS (SELECT 1 FROM #{table} t WHERE " \
            "t.id = chat_message_references.referable_id AND t.project_id IN (:projects)))"
        end.join(" OR ")
      end

      # Tables reached through a column other than the usual project, ticket or group link (CYRA-879).
      def predicates
        { "agents_hosts" => "heartbeat_project_id IN (:projects)",
          "chat_message_references" => crossing_references_sql }.merge(knowledge_predicates)
      end

      # Knowledge links detach only where one side moves and the other stays; :pages and :books are
      # Subject's fixed lists. The OR in front of each crossing test keeps it on indexed rows (CYRA-882).
      def knowledge_predicates
        page_moves = "COALESCE(%s IN (:pages), FALSE)"
        feature_moves = "category_id IN (SELECT id FROM product_categories WHERE group_id IN (:groups))"
        { "connections_page_projects" => "project_id IN (:projects) AND NOT #{format(page_moves, 'page_id')}",
          "connections_page_groups" => "group_id IN (:groups) AND NOT #{format(page_moves, 'page_id')}",
          "connections_book_projects" => "project_id IN (:projects) AND NOT COALESCE(book_id IN (:books), FALSE)",
          "connections_book_groups" => "group_id IN (:groups) AND NOT COALESCE(book_id IN (:books), FALSE)",
          "connections_page_links" => "(page_id IN (:pages) OR related_id IN (:pages)) AND " +
                                      crossing_sql("page_id IN (:pages)", "related_id IN (:pages)"),
          "knowledge_sample_questions" => "(project_id IN (:projects) OR knowledge_page_id IN (:pages)) AND " +
                                          crossing_sql("project_id IN (:projects)", "knowledge_page_id IN (:pages)"),
          "product_features" => "(#{feature_moves} OR knowledge_page_id IN (:pages)) AND " +
                                crossing_sql(feature_moves, "knowledge_page_id IN (:pages)") }
      end

      # True when exactly one of the two conditions holds; NULL counts as false (CYRA-882).
      def crossing_sql(left, right) = "COALESCE(#{left}, FALSE) <> COALESCE(#{right}, FALSE)"

      def scope(table, subject) = rows(table, predicate(table), subject)

      # Rows of any table matching an SQL condition written with :projects, :groups and :tickets (CYRA-879),
      # and :pages or :books, bound only when used so a plain rule never computes them (CYRA-882).
      def rows(table, sql, subject)
        model = Class.new(ApplicationRecord) do
          self.table_name = table
          self.inheritance_column = nil
        end
        binds = { projects: subject.project_ids, groups: subject.group_ids, tickets: subject.ticket_ids }
        binds[:pages] = subject.page_ids if sql.include?(":pages")
        binds[:books] = subject.book_ids if sql.include?(":books")
        model.where(sql, binds.transform_values { _1.presence || [ nil ] })
      end

      # Rows a detach really changes: for a nullify rule, only those still holding one of the links (CYRA-879).
      def affected(table, subject)
        rule = Registry::DETACH.fetch(table)
        return scope(table, subject) if rule == :delete

        scope(table, subject).where(rule[:nullify].map { "#{_1} IS NOT NULL" }.join(" OR "))
      end

      # Host exclusions have no cascade on their rule, so they go first (CYRA-879).
      def apply!(subject)
        Alerting::RuleHostExclusion.where(rule_id: scope("alerting_rules", subject).select(:id)).delete_all
        Registry::DETACH.each do |table, rule|
          relation = scope(table, subject)
          rule == :delete ? relation.delete_all : relation.update_all(rule[:nullify].index_with(nil))
        end
      end

      def predicate(table)
        return predicates[table] if predicates.key?(table)

        columns = ApplicationRecord.connection.columns(table).map(&:name)
        COLUMN_PREDICATES.find { |column, _| columns.include?(column) }&.last || Registry::FOLLOW.fetch(table)
      end
    end
  end
end
