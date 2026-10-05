# frozen_string_literal: true

module Search
  # Where each kind of result comes from (CYRA-900). Every source starts from the viewer's visible
  # scope, the same boundary as its own pages, and only narrows it by the query. Most return a
  # relation; people, secrets and menu entries return arrays because they are filtered in Ruby.
  class Sources
    SecretName = Data.define(:name, :projects)

    # Candidates checked against the presence cohort: enough to fill a group after filtering.
    PEOPLE_CANDIDATES = 50

    def initialize(query:, visible:, viewer:, organization:, nav_items:)
      @query = query
      @visible = visible
      @viewer = viewer
      @organization = organization
      @nav_items = nav_items
    end

    # The ticket or project whose code was typed in full, looked up on its own so newer partial
    # matches can never push it out of the group (CYRA-900).
    def exact(key)
      case key
      when :tickets then exact_ticket
      when :projects then @visible.projects.find_by("LOWER(projects.key) = LOWER(?)", @query)
      end
    end

    def nav
      needle = @query.downcase
      @nav_items.select { |entry| entry.label.downcase.include?(needle) }
    end

    def projects
      @visible.projects.where("projects.name ILIKE :q OR projects.key ILIKE :q", q: like).order(updated_at: :desc)
    end

    # LinkableTickets also knows the KEY-123 shape, which is not a column.
    def tickets
      Ticketing::LinkableTickets.call(scope: @visible.tickets, query: @query, all: true, limit: nil)
    end

    def error_groups
      @visible.error_groups.preload(:project)
              .where("errors_groups.title ILIKE :q OR errors_groups.culprit ILIKE :q", q: like)
              .order(updated_at: :desc)
    end

    def pages
      @visible.pages.where("knowledge_pages.title ILIKE :q OR knowledge_pages.body ILIKE :q " \
                           "OR knowledge_pages.tech_spec ILIKE :q", q: like).order(updated_at: :desc)
    end

    def books
      @visible.books.where("knowledge_books.title ILIKE :q", q: like).order(:title)
    end

    def ideas
      @visible.ideas.preload(:project)
              .where("ideas_ideas.title ILIKE :q OR ideas_ideas.problem ILIKE :q", q: like)
              .order(updated_at: :desc)
    end

    def monitors
      @visible.monitors.preload(:project)
              .where("uptime_monitors.name ILIKE :q OR uptime_monitors.url ILIKE :q", q: like).order(:name)
    end

    def cron_monitors
      @visible.cron_monitors.preload(:project)
              .where("crons_monitors.name ILIKE :q OR crons_monitors.slug ILIKE :q", q: like).order(:name)
    end

    def servers
      @visible.servers.where("servers_hosts.name ILIKE :q OR servers_hosts.hostname ILIKE :q", q: like).order(:name)
    end

    def groups
      @visible.groups.where("projects_groups.name ILIKE :q", q: like).order(:name)
    end

    def teams
      @visible.teams.where("teams_teams.name ILIKE :q", q: like).order(:name)
    end

    # The same rule as "who is online": owners see everyone, the others only whoever shares a
    # project, group or team with them.
    def people
      candidates = Accounts::Account
                   .where(id: Connections::Membership.where(organization_id: @organization.id).select(:account_id))
                   .where.not(id: @viewer.id)
                   .where("accounts.name ILIKE :q OR accounts.email ILIKE :q", q: like)
                   .order(:name).limit(PEOPLE_CANDIDATES).to_a
      # The cohort only knows the footprint of the accounts it is given: the viewer goes in too.
      Presence::Cohort.new(organization: @organization, online: [ @viewer, *candidates ])
                      .visible_for(@viewer) - [ @viewer ]
    end

    # Direct chats by the other person's name, channels by their project or team name.
    def conversations
      base = Chat::Conversation.visible_to(account: @viewer, organization: @organization)
      direct_ids = Chat::Participant.joins(:account).where.not(account_id: @viewer.id)
                                    .where("accounts.name ILIKE :q", q: like).select(:conversation_id)
      base.where(id: direct_ids)
          .or(base.where(contextable_type: "Projects::Project",
                         contextable_id: Projects::Project.where("projects.name ILIKE :q", q: like).select(:id)))
          .or(base.where(contextable_type: "Teams::Team",
                         contextable_id: Teams::Team.where("teams_teams.name ILIKE :q", q: like).select(:id)))
          .preload(:contextable, :accounts).ordered
    end

    # Names only, never values: the same boundary as the vault's variable search page.
    def secrets
      Secrets::Variable.where(project_id: @visible.projects.select(:id))
                       .where("secrets_variables.name ILIKE :q", q: like)
                       .group(:name).order(:name).distinct.count(:project_id)
                       .map { |name, projects| SecretName.new(name: name, projects: projects) }
    end

    private

    def exact_ticket
      match = Ticketing::LinkableTickets::CODE_QUERY.match(@query)
      return unless match && match[:key].present?

      @visible.tickets.preload(:project).joins(:project)
              .where(number: match[:number].to_i).find_by("LOWER(projects.key) = LOWER(?)", match[:key])
    end

    def like
      @like ||= "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%"
    end
  end
end
