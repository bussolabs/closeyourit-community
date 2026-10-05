# frozen_string_literal: true

module Member
  # CYRA-930 — the Knowledge landing: per project, the pages, the decisions among them, the proposals
  # waiting for review and the accepted ones still to file. A page counts on the projects it is
  # linked to directly; the ones written for a group or the whole organization count only in the
  # all-projects row. The projects with the most proposals waiting first.
  class KnowledgeMatrix < ProjectMatrix
    COLUMNS = %i[pages decisions review to_file].freeze

    # Pages are visible by their own rule (N:N with projects and groups): the caller passes the scopes.
    def initialize(visible_pages:, visible_review:, **)
      super(**)
      @visible_pages = visible_pages
      @visible_review = visible_review
    end

    def i18n_scope = "member.overviews.knowledge"

    def columns = COLUMNS

    def projects_scope
      waiting = ::Connections::PageProject.where(page_id: @visible_review.select(:id))
                                          .where(::Connections::PageProject.arel_table[:project_id].eq(::Projects::Project.arel_table[:id]))
                                          .select(Arel.star.count)
      @visible_projects.with_attached_icon_image.reorder(Arel.sql("(#{waiting.to_sql}) DESC"), :name)
    end

    def project_cells(project)
      filter = { project_id: [ project.id ] }
      cells(filter) { |counts| counts[project.id] }
    end

    def total_cells
      {
        pages: count_cell(:pages, @visible_pages.count, routes.member_knowledge_pages_path),
        decisions: count_cell(:decisions, @visible_pages.kind_decision.count, routes.member_knowledge_pages_path(kind: [ "decision" ])),
        review: count_cell(:review, @visible_review.count, routes.member_knowledge_reviews_path, alert: true),
        to_file: count_cell(:to_file, @visible_pages.awaiting_consolidation.count, routes.member_knowledge_reviews_path)
      }
    end

    private

    def cells(filter)
      {
        pages: count_cell(:pages, yield(by_project(@visible_pages)), routes.member_knowledge_pages_path(filter)),
        decisions: count_cell(:decisions, yield(by_project(@visible_pages.kind_decision)),
                              routes.member_knowledge_pages_path(filter.merge(kind: [ "decision" ]))),
        review: count_cell(:review, yield(by_project(@visible_review)), routes.member_knowledge_reviews_path(filter), alert: true),
        to_file: count_cell(:to_file, yield(by_project(@visible_pages.awaiting_consolidation)),
                            routes.member_knowledge_reviews_path(filter))
      }
    end

    def by_project(pages)
      @by_project ||= {}
      @by_project[pages.to_sql] ||= ::Connections::PageProject.where(page_id: pages.select(:id), project_id: project_ids)
                                                              .group(:project_id).count
    end
  end
end
