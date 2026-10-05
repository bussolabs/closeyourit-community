# frozen_string_literal: true

module Valhalla
  class DashboardController < BaseController
    # CYRA-924 — the three tables sort on their columns (C9), each on its own param. Sessions and
    # impersonations are the most recent few, sorted in memory; organizations page, sorted in SQL.
    ORGANIZATION_SORT_COLUMNS = {
      "organization" => "LOWER(organizations.name)",
      "slug" => :slug,
      "owner" => "(SELECT LOWER(accounts.email) FROM connections_memberships m JOIN accounts ON accounts.id = m.account_id " \
                 "WHERE m.organization_id = organizations.id " \
                 "AND m.role = #{Connections::Membership.roles.fetch("owner")} LIMIT 1)",
      "created" => :created_at
    }.freeze
    SESSION_SORT_COLUMNS = { "account" => ->(session) { session.account.name.to_s.downcase },
                             "ip" => ->(session) { session.ip_address.presence }, "when" => ->(session) { session.created_at } }.freeze
    IMPERSONATION_SORT_COLUMNS = { "god" => ->(event) { event.god.email.to_s }, "target" => ->(event) { event.account.email.to_s },
                                   "started" => ->(event) { event.started_at } }.freeze

    def index
      @accounts_count = Accounts::Account.count
      @organizations_count = Organizations::Organization.count
      @tickets_count = Ticketing::Ticket.count
      @god_count = Accounts::Account.where(god: true).count
      # Segnali operativi (stato org, accessi/impersonation recenti, crescita 7gg): logica nel presenter.
      @signals = DashboardSignals.new
      @recent_sessions = sorted_rows(@signals.recent_sessions.to_a, columns: SESSION_SORT_COLUMNS, param: :sessions_sort)
      @impersonations = sorted_rows(@signals.recent_impersonation_events.to_a, columns: IMPERSONATION_SORT_COLUMNS,
                                                                                param: :impersonations_sort)
      # includes(:owner): la tabella recenti mostra owner&.email per riga → senza preload una query
      # owner_membership→account per org (prosopite N+1).
      @recent_pagination = paginate(sorted(Organizations::Organization.includes(:owner).order(created_at: :desc),
                                           columns: ORGANIZATION_SORT_COLUMNS, param: :organizations_sort))
      @recent_organizations = @recent_pagination.records
    end
  end
end
