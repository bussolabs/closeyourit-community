# frozen_string_literal: true

# One row of the approvals queue for the CLI (`cyi approvals list`, CYRA-1184). The row is a
# Home::Feed::Item; `deferred_until` comes from the controller, which knows this account's deferrals.
class ApprovalRowSerializer < ApplicationSerializer
  attributes :key, :state, :title, :subtitle, :code, :waiting_since, :sort_at, :bulk_approvable

  attribute(:kind) { |item| item.kind.to_s }
  attribute(:path) { |item| item.url }
  attribute(:project) { |item| item.project && { key: item.project.key, name: item.project.name } }
  attribute(:agent) { |item| item.agent && { id: item.agent.id, name: item.agent.name } }
  attribute(:deferred_until) { |item| params[:deferrals]&.[](item.key) }
end
