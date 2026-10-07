module Coworkers
  # How much a Puck may do at once and for how long (CYRA-1027). Per organization, so one busy team
  # never blocks another; the worker host keeps its own slot count.
  module Limits
    ORGANIZATION_ACTIVE = 4
    ORGANIZATION_TASKS = 2
    QUEUE_TTL = 10.minutes
    GRACE = 30.seconds
    DEADLINES = { "chat" => 2.minutes, "watch" => 5.minutes, "task" => 30.minutes }.freeze
    # Each turn resends the whole conversation and the tool declarations (about 6,000 tokens), so a budget
    # counts every turn: a chat of six turns needs about 100,000.
    TOKENS = { "chat" => 120_000, "watch" => 160_000, "task" => 400_000 }.freeze

    def self.deadline(kind) = DEADLINES.fetch(kind)
    def self.tokens(kind) = TOKENS.fetch(kind)

    # Sent to the runtime inside the frozen context; it enforces both.
    def self.for_runtime(kind) = { deadlineSeconds: deadline(kind).to_i, tokenBudget: tokens(kind) }

    # Work that can no longer be running: queued too long, or past its deadline.
    def self.stale(scope)
      now = Time.current
      queued = scope.where(status: "queued").where(created_at: ...(now - QUEUE_TTL))
      running = DEADLINES.map { |kind, limit| scope.where(status: "running", kind: kind).where(started_at: ...(now - limit - GRACE)) }
      running.reduce(queued) { |all, part| all.or(part) }
    end
  end
end
