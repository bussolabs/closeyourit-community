module Coworkers
  class Puck < ApplicationRecord
    self.table_name = "coworkers_puckies"
    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :account, class_name: "Accounts::Account"
    has_many :runs, class_name: "Coworkers::Run", dependent: :restrict_with_exception
    validates :name, presence: true, length: { maximum: 80 }
    validates :instructions, presence: true, length: { maximum: 8000 }
    validates :memory, length: { maximum: 8000 }

    def context_for(kind, input)
      history = runs.where.not(status: %w[queued running]).order(created_at: :desc).limit(8).reverse
      { identity: { name: name, instructions: instructions }, approvedMemory: memory,
        memoryRevision: lock_version, mode: kind, request: input,
        history: history.map { |run| { kind: run.kind, input: run.input, output: run.output.last(6000), status: run.status, proposal: run.proposed_task } },
        activeTasks: runs.where(kind: "task", status: %w[queued running]).map { |run| { input: run.input, status: run.status, output: run.output.last(2000) } } }
    end
  end
end
