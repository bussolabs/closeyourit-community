# frozen_string_literal: true

module Embeddings
  # Recalculates the search vectors of one organization after it changed search model (CYRA-914).
  # Queues the usual embed jobs, which skip what is already current: nothing of other organizations moves.
  class ReembedOrganizationJob < ApplicationJob
    queue_as :batch

    def perform(organization_id:)
      projects = Projects::Project.where(organization_id:).select(:id)

      Ticketing::Ticket.where(project_id: projects).find_each { |r| Ticketing::EmbedTicketJob.perform_later(ticket_id: r.id) }
      Errors::Group.where(project_id: projects).find_each { |r| Errors::EmbedGroupJob.perform_later(group_id: r.id) }
      Ideas::Idea.where(project_id: projects).find_each { |r| Ideas::EmbedIdeaJob.perform_later(idea_id: r.id) }
      Helpdesk::Request.where(project_id: projects).find_each { |r| Helpdesk::EmbedRequestJob.perform_later(request_id: r.id) }
      Knowledge::Page.where(organization_id:).find_each { |r| Knowledge::EmbedPageJob.perform_later(page_id: r.id) }
    end
  end
end
