module Coworkers
  class Run < ApplicationRecord
    self.table_name = "coworkers_runs"
    belongs_to :puck, class_name: "Coworkers::Puck"
    belongs_to :proposal_run, class_name: "Coworkers::Run", optional: true
    has_one :approved_task, class_name: "Coworkers::Run", foreign_key: :proposal_run_id, dependent: :restrict_with_exception
    has_many :tool_calls, class_name: "Coworkers::ToolCall", dependent: :delete_all
    has_many :action_proposals, -> { chronological }, class_name: "Assistant::Proposal", foreign_key: :coworkers_run_id,
             inverse_of: :coworkers_run, dependent: :delete_all
    validate :validate_proposed_task
    belongs_to :schedule, class_name: "Coworkers::Schedule", optional: true
    # Who asked for the run; nil on runs older than CYRA-1023, which belong to the Puck's owner.
    belongs_to :account, class_name: "Accounts::Account", optional: true
    belongs_to :parent_run, class_name: "Coworkers::Run", optional: true
    has_many :child_runs, -> { order(:created_at) }, class_name: "Coworkers::Run", foreign_key: :parent_run_id,
             inverse_of: :parent_run, dependent: :nullify
    validates :kind, inclusion: { in: %w[chat task watch] }
    validates :status, inclusion: { in: %w[queued running completed failed stopped interrupted] }
    validates :input, presence: true, length: { maximum: 8000 }
    validates :output, length: { maximum: 128000 }
    scope :active, -> { where(status: %w[queued running]) }
    CHANNELS = %w[web telegram slack app].freeze
    # The latest screen of the task's browser and the proof video of a reproduction (CYRA-1016, CYRA-1028).
    has_one_attached :screen
    has_one_attached :video
    validates :channel, inclusion: { in: CHANNELS }
    after_update_commit :report_watch, if: -> { kind == "watch" && saved_change_to_status?(to: "completed") }
    # A question asked from Telegram or Slack gets its answer there (CYRA-1018, CYRA-1019).
    after_update_commit :answer_on_channel, if: -> { channel.in?(%w[telegram slack]) && saved_change_to_status? && !active? }

    def active? = status.in?(%w[queued running])
    def requester = account || puck.account

    # Stopping a run stops the work it handed to other Puckies too (CYRA-1024).
    def request_stop!
      update!(stop_requested: true) if active?
      child_runs.each(&:request_stop!)
    end

    # A chat answer that did not finish can be sent again with the same message (CYRA-992).
    def retryable? = kind == "chat" && status.in?(%w[failed interrupted])

    def self.valid_proposal?(value)
      fields = %w[objective activities limits]
      value.is_a?(Hash) && value.keys.sort == fields.sort &&
        fields.all? { |field| value[field].is_a?(String) && value[field].strip.present? && value[field].length <= 2000 }
    end

    def approvable_proposal?
      kind == "chat" && status == "completed" && !proposal_superseded? && self.class.valid_proposal?(proposed_task)
    end

    def proposal_input
      %w[objective activities limits].map { |field| "#{field.capitalize}: #{proposed_task.fetch(field)}" }.join("\n\n")
    end

    def publish
      # Both languages render the same bubble: load what it shows once.
      ActiveRecord::Associations::Preloader.new(records: [ self ], associations: [ :action_proposals, { child_runs: :puck } ]).call
      load_media if kind == "task"
      %i[it en].each do |locale|
        I18n.with_locale(locale) do
          Turbo::StreamsChannel.broadcast_replace_to(Realtime::Streams.coworker(puck, locale),
            target: "coworker_run_#{id}", partial: "member/coworkers/run", locals: { run: self, puck: puck })
        end
      end
      if proposal_run_id.present?
        parent = proposal_run
        parent.association(:approved_task).target = self
        parent.publish
      end
      parent_run&.publish # the bubble that handed this work shows its progress (CYRA-1024)
    end

    # Screen and proof video of task cards, one query for any number of runs (CYRA-1016).
    def self.load_media(runs)
      pending = runs.reject { |run| run.association(:screen_attachment).loaded? && run.association(:video_attachment).loaded? }
      return if pending.empty?

      found = ActiveStorage::Attachment.where(record_type: name, record_id: pending.map(&:id), name: %w[screen video])
                                       .includes(:blob).group_by(&:record_id)
      pending.each do |run|
        media = found.fetch(run.id, [])
        run.association(:screen_attachment).target = media.find { |attachment| attachment.name == "screen" }
        run.association(:video_attachment).target = media.find { |attachment| attachment.name == "video" }
      end
    end

    def load_media = self.class.load_media([ self ])

    private

    def report_watch = Coworkers::Notify.report_ready(self)
    def answer_on_channel = Coworkers::Channels.answer(self)

    def validate_proposed_task
      return if proposed_task == {} || (kind == "chat" && self.class.valid_proposal?(proposed_task))
      errors.add(:proposed_task, :invalid)
    end
  end
end
