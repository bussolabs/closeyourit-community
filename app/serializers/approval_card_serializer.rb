# frozen_string_literal: true

# One approvals card for the CLI (`cyi approvals show`, CYRA-1184): what the web decision panel shows,
# as text. A Home::Approvals::Detail::Card; never carries a secret value (only name and intent).
class ApprovalCardSerializer < ApplicationSerializer
  attributes :key, :kind, :phase

  attribute(:decisions) { |card| card.decisions.map(&:to_s) }
  attribute(:path) { |card| Rails.application.routes.url_helpers.member_home_approvals_item_path(kind: card.kind, id: card.id) }
  attribute(:project) { |card| card.project && { key: card.project.key, name: card.project.name } }

  attribute(:ticket) do |card|
    ticket = card.ticket
    ticket && { id: ticket.id, code: ticket.code, title: ticket.title, description: ticket.description,
                technical_analysis: ticket.technical_analysis, status: ticket.status&.label }
  end

  attribute(:plan) do |card|
    card.plan && { version: card.plan.version, markdown: Agents::Plans::Markdown.call(plan: card.plan, ticket: card.ticket) }
  end

  attribute(:report) do |card|
    report = card.report
    report && { version: report.version, author: report.author_name, body: report.body, created_at: report.created_at }
  end

  attribute(:questions) do |card|
    next [] unless card.kind == "clarification"

    card.record.questions.map do |question|
      { position: question.position, body: question.body, options: question.choice_options }
    end
  end

  attribute(:blocked_review) { |card| card.attempt&.review.presence&.dig("summary").presence }

  attribute(:secret_change) do |card|
    next nil unless card.kind == "secret_change"

    change = card.record
    { action: change.action, name: change.name, environment: change.environment&.label,
      project: change.project&.name, requested_by: change.requested_by&.name, reason: change.reason }
  end
end
