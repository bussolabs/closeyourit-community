# frozen_string_literal: true

module Member
  # What the project Settings page needs, shared with the token create action that renders it. Each
  # half follows its own permission: the settings form projects.edit, the ingest tokens tokens.manage
  # (search, state filter, sort, page and the counts by state). CYRA-883
  module ProjectSettingsPage
    extend ActiveSupport::Concern

    # Sortable#sorted contract. status sorts on revoked_at (active = NULL, last with NULLS LAST);
    # scopes is cast to text for a deterministic order.
    TOKEN_SORT_COLUMNS = {
      "name" => "LOWER(projects_tokens.name)",
      "environment" => { expr: "LOWER(types_environments.label)", joins: :environment },
      "prefix" => :token_prefix,
      "scopes" => "projects_tokens.scopes::text",
      "last_used" => :last_used_at,
      "expiry" => :expires_at,
      "status" => :revoked_at
    }.freeze

    TOKEN_STATES = %w[active expired revoked].freeze

    private

    def load_settings
      @stats = @project.ticket_tally
      @can_edit_settings = can?("projects.edit", scope: @project)
      @can_manage_tokens = can?("tokens.manage", scope: @project)
      # Default assignee candidates: the assignee must be a member of the organization.
      @accounts = @project.organization.accounts.order(:name) if @can_edit_settings
      load_tokens if @can_manage_tokens
    end

    def load_tokens
      tokens = @project.tokens
      @token_counts = token_counts(tokens)
      scope = filter_tokens(tokens.includes(:environment).order(revoked_at: :asc, created_at: :desc))
      @pagination = paginate(sorted(scope, columns: TOKEN_SORT_COLUMNS))
      @tokens = @pagination.records
      @environments = @project.environments.active.ordered.to_a
    end

    def filter_tokens(scope)
      if search_q.present?
        scope = scope.where("LOWER(projects_tokens.name) LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(search_q.downcase)}%")
      end
      states = filter_ids(:status) & TOKEN_STATES
      return scope if states.empty?

      states.map { |state| tokens_in_state(scope, state) }.reduce(:or)
    end

    # Same boundaries as Projects::Token.active and #expired?, so the filter and the badge agree.
    def tokens_in_state(scope, state)
      case state
      when "active" then scope.active
      when "expired" then scope.where(revoked_at: nil).where(expires_at: ..Time.current)
      else scope.where.not(revoked_at: nil)
      end
    end

    def token_counts(tokens)
      now = Time.current
      soon = now + Projects::Token::EXPIRY_DUE_SOON_THRESHOLD
      live = tokens.where(revoked_at: nil)
      {
        total: tokens.count,
        active: live.where("expires_at IS NULL OR expires_at > ?", now).count,
        due_soon: live.where("expires_at > ? AND expires_at <= ?", now, soon).count,
        expired: live.where(expires_at: ..now).count,
        revoked: tokens.where.not(revoked_at: nil).count
      }
    end
  end
end
