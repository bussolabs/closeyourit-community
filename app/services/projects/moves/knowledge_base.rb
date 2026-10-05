# frozen_string_literal: true

module Projects
  module Moves
    # Knowledge pages and books that follow the moved subject (Subject#page_ids, #book_ids): what the
    # plan shows, what blocks, and the books that change around them (CYRA-882).
    class KnowledgeBase
      def initialize(subject:, destination:)
        @subject = subject
        @destination = destination
      end

      # A publication key is unique per organization: a moved page cannot take one the destination uses (CYRA-882).
      def conflicts
        taken = ::Knowledge::Page.where(organization_id: @destination.id).where.not(publication_key: nil).select(:publication_key)
        pages.where(publication_key: taken).order(:publication_key).pluck(:publication_key)
      end

      # Staying books that would lose every link and whose staying pages offer none to replace them (CYRA-882).
      def orphaned_titles
        linked = relinks.values_at(:projects, :groups).flatten(1).map(&:first)
        ::Knowledge::Book.where(id: relinks[:ids] - linked).order(:title).pluck(:title)
      end

      def relinked_count = relinks.values_at(:projects, :groups).flatten(1).map(&:first).uniq.size

      def creations
        return [] if @subject.page_ids.empty?

        [ { table: "knowledge_pages", count: @subject.page_ids.size },
          *moving_titles.map { { table: "knowledge_books", title: _1, outcome: "moves", books: 1 } },
          *book_targets ]
      end

      # Before Detach: a staying book about to lose every link gets those of its staying pages (CYRA-882).
      def relink!
        relinks[:projects].each_slice(500) { |rows| Connections::BookProject.insert_all(rows.map { { book_id: _1, project_id: _2 } }) }
        relinks[:groups].each_slice(500) { |rows| Connections::BookGroup.insert_all(rows.map { { book_id: _1, group_id: _2 } }) }
      end

      # After the pages and books followed: a moved page whose book stayed gets the destination book
      # with the same title, created and linked to the page's subjects when missing (CYRA-882).
      def apply!(actor:)
        orphaned = pages.where.not(book_id: nil).where.not(book_id: @subject.book_ids)
        orphaned.includes(:book).group_by { _1.book.title }.each do |title, list|
          ::Knowledge::Page.where(id: list.map(&:id)).update_all(book_id: destination_book(title, list, actor).id)
        end
      end

      private

      def pages = ::Knowledge::Page.where(id: @subject.page_ids)

      def moving_titles = (@moving_titles ||= ::Knowledge::Book.where(id: @subject.book_ids).order(:title).pluck(:title))

      # Staying books of moved pages, merged by title into a destination book that exists or moves, or is created (CYRA-882).
      def book_targets
        existing = ::Knowledge::Book.where(organization_id: @destination.id).distinct.pluck(:title) | moving_titles
        staying = ::Knowledge::Book.where(id: pages.select(:book_id)).where.not(id: @subject.book_ids)
        staying.group(:title).order(:title).count.map do |title, books|
          { table: "knowledge_books", title:, outcome: existing.include?(title) ? "joined" : "created", books: }
        end
      end

      # { ids: books losing every link, projects: [[book_id, project_id]], groups: [[book_id, group_id]] } (CYRA-882).
      def relinks
        @relinks ||= begin
          ids = losing_book_ids
          { ids:, projects: staying_links(Connections::PageProject, :project_id, @subject.project_ids, ids),
            groups: staying_links(Connections::PageGroup, :group_id, @subject.group_ids, ids) }
        end
      end

      def losing_book_ids
        project_ids = @subject.project_ids
        group_ids = @subject.group_ids
        linked = ::Knowledge::Book.where(id: Connections::BookProject.where(project_id: project_ids).select(:book_id))
                                  .or(::Knowledge::Book.where(id: Connections::BookGroup.where(group_id: group_ids).select(:book_id)))
        linked.where.not(id: @subject.book_ids)
              .where.not(id: Connections::BookProject.where.not(project_id: project_ids).select(:book_id))
              .where.not(id: Connections::BookGroup.where.not(group_id: group_ids).select(:book_id)).pluck(:id)
      end

      def staying_links(model, column, moved_ids, book_ids)
        return [] if book_ids.empty?

        model.joins(:page).where(knowledge_pages: { book_id: book_ids }).where.not(page_id: @subject.page_ids)
             .where.not(column => moved_ids).distinct.order("knowledge_pages.book_id", column)
             .pluck("knowledge_pages.book_id", column)
      end

      def destination_book(title, list, actor)
        existing = ::Knowledge::Book.where(organization_id: @destination.id, title:).order(:created_at, :id).first
        return existing if existing

        ids = list.map(&:id)
        ::Knowledge::Book.create!(organization_id: @destination.id, title:, description: list.first.book.description, created_by: actor,
                                  projects: Projects::Project.where(id: Connections::PageProject.where(page_id: ids).select(:project_id)),
                                  groups: Projects::Group.where(id: Connections::PageGroup.where(page_id: ids).select(:group_id)))
      end
    end
  end
end
