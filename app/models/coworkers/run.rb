module Coworkers
  class Run < ApplicationRecord
    self.table_name = "coworkers_runs"
    belongs_to :puck, class_name: "Coworkers::Puck"
    belongs_to :proposal_run, class_name: "Coworkers::Run", optional: true
    has_one :approved_task, class_name: "Coworkers::Run", foreign_key: :proposal_run_id, dependent: :restrict_with_exception
    validate :validate_proposed_task
    validates :kind, inclusion: { in: %w[chat task] }
    validates :status, inclusion: { in: %w[queued running completed failed stopped interrupted] }
    validates :input, presence: true, length: { maximum: 8000 }
    validates :output, length: { maximum: 128000 }
    scope :active, -> { where(status: %w[queued running]) }

    def active? = status.in?(%w[queued running])

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
    end

    private

    def validate_proposed_task
      return if proposed_task == {} || (kind == "chat" && self.class.valid_proposal?(proposed_task))
      errors.add(:proposed_task, :invalid)
    end
  end
end
