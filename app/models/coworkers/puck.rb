module Coworkers
  class Puck < ApplicationRecord
    self.table_name = "coworkers_puckies"
    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :account, class_name: "Accounts::Account"
    # A team Puck belongs to one project and is governed by who manages the organization (CYRA-1023).
    belongs_to :project, class_name: "Projects::Project", optional: true
    has_many :runs, class_name: "Coworkers::Run", dependent: :restrict_with_exception
    has_many :rules, class_name: "Coworkers::Rule", dependent: :delete_all
    has_many :schedules, class_name: "Coworkers::Schedule", dependent: :destroy
    has_many :memory_notes, class_name: "Coworkers::MemoryNote", dependent: :delete_all
    has_many :connections, class_name: "Coworkers::Connection", dependent: :delete_all
    has_many :sites, class_name: "Coworkers::Site", dependent: :delete_all
    has_many :procedures, class_name: "Coworkers::Procedure", dependent: :delete_all
    WATCH_INTERVALS = [ 15, 60, 240 ].freeze
    validates :watch_every_minutes, inclusion: { in: WATCH_INTERVALS }, allow_nil: true
    validates :visibility, inclusion: { in: %w[personal team] }
    validates :project, presence: true, if: :team?
    validate :project_in_organization
    scope :personal, -> { where(visibility: "personal") }

    def team? = visibility == "team"

    # Personal: its owner. Team: whoever manages the organization.
    def managed_by?(account)
      return account_id == account&.id unless team?

      Authorization::Resolver.new(account: account, organization: organization).can?("organization.manage")
    end
    validates :name, presence: true, length: { maximum: 80 }
    validates :instructions, presence: true, length: { maximum: 8000 }
    validates :memory, length: { maximum: 8000 }

    # History from runs that read projects outside today's scope stays out (CYRA-1009).
    def context_for(kind, input, scope: {})
      visible = Array(scope["project_ids"])
      history = runs.where.not(status: %w[queued running]).includes(:action_proposals, :tool_calls, child_runs: :puck).order(created_at: :desc).limit(8).reverse
                    .select { |run| (Array(run.scope["project_ids"]) - visible).empty? || run.tool_calls.none? }
      { identity: { name: name, instructions: instructions }, approvedMemory: memory,
        learnedMemory: learned_memory(visible), memoryRevision: lock_version, mode: kind, request: input, railsTools: Coworkers::Tools.declarations(self, kind: kind),
        limits: Coworkers::Limits.for_runtime(kind), sites: kind == "task" ? sites.pluck(:domain) : [],
        history: history.map { |run| { kind: run.kind, input: run.input, output: run.output.last(6000), status: run.status, proposal: run.proposed_task, actions: actions_of(run),
                                   handoffs: handoffs_of(run) } },
        activeTasks: runs.where(kind: "task", status: %w[queued running]).map { |run| { input: run.input, status: run.status, output: run.output.last(2000) } } }
    end

    # What became of each action a past answer proposed: without it the model asks again for a card
    # the person already confirmed (found in the live browser test).
    def actions_of(run)
      run.action_proposals.map do |proposal|
        { kind: proposal.kind, subject: (proposal.payload["title"] || proposal.payload["ticket_code"]).to_s.first(120), status: proposal.status }
      end
    end

    # What the Puckies this run handed work to answered, so the next turn can report it (CYRA-1024).
    def handoffs_of(run)
      run.child_runs.map { |child| { puck: child.puck.name, status: child.status, output: child.output.to_s.last(1500) } }
    end

    def project_in_organization
      errors.add(:project, :invalid) if project && project.organization_id != organization_id
    end

    # Accepted notes whose source run saw nothing outside today's scope (CYRA-1012).
    def learned_memory(visible)
      memory_notes.active.order(created_at: :desc).limit(MemoryNote::MAX_ACTIVE)
                  .select { |note| (Array(note.scope["project_ids"]) - visible).empty? }.map(&:body)
    end
  end
end
