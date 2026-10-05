# frozen_string_literal: true

module Projects
  module Moves
    # What a move carries: a project alone, or a group with all its projects (CYRA-879).
    class Subject
      attr_reader :record

      def initialize(record)
        @record = record
      end

      def group? = record.is_a?(Projects::Group)
      def organization = record.organization
      def label = group? ? record.name : record.key

      def group_ids = group? ? [ record.id ] : []

      def project_ids
        @project_ids ||= group? ? record.projects.pluck(:id) : [ record.id ]
      end

      def ticket_ids
        @ticket_ids ||= Ticketing::Ticket.where(project_id: project_ids).pluck(:id)
      end

      # Knowledge pages and books that follow (Registry::MOVING_PAGES/MOVING_BOOKS), evaluated once (CYRA-882).
      def page_ids = (@page_ids ||= moving_ids(::Knowledge::Page, Registry::MOVING_PAGES))
      def book_ids = (@book_ids ||= moving_ids(::Knowledge::Book, Registry::MOVING_BOOKS, pages: page_ids.presence || [ nil ]))

      # Execute calls this under its locks: the rows stay locked and the lists fixed until the commit (CYRA-882).
      def lock_knowledge!
        @page_ids = moving_ids(::Knowledge::Page, Registry::MOVING_PAGES, lock: true)
        @book_ids = moving_ids(::Knowledge::Book, Registry::MOVING_BOOKS, pages: @page_ids.presence || [ nil ], lock: true)
      end

      private

      def moving_ids(model, sql, lock: false, **binds)
        binds.merge!(organization: record.organization_id, projects: project_ids.presence || [ nil ],
                     groups: group_ids.presence || [ nil ])
        rows = model.where(sql, binds).order(:id)
        (lock ? rows.lock : rows).pluck(:id)
      end
    end
  end
end
