module Coworkers
  # A task a Puck repeats at a fixed time (CYRA-1001). Saving it authorizes the recurrence, not
  # the writes: every run still goes through the Puck's rules.
  class Schedule < ApplicationRecord
    self.table_name = "coworkers_schedules"
    FREQUENCIES = %w[hourly daily weekdays weekly].freeze

    belongs_to :puck, class_name: "Coworkers::Puck"
    belongs_to :created_by, class_name: "Accounts::Account"
    has_many :runs, class_name: "Coworkers::Run", dependent: :nullify

    validates :input, presence: true, length: { maximum: 8000 }
    validates :frequency, inclusion: { in: FREQUENCIES }
    validates :hour, inclusion: { in: 0..23 }
    validates :minute, inclusion: { in: 0..59 }
    validates :weekday, inclusion: { in: 0..6 }, if: -> { frequency == "weekly" }
    validate :known_time_zone

    before_validation :normalize_time_zone
    validate :plan_next_run, if: -> { new_record? || (changed & %w[frequency hour minute weekday time_zone]).any? }

    scope :due, ->(at = Time.current) { where(paused: false).where(next_run_at: ..at) }

    def cron
      case frequency
      when "hourly" then "#{minute} * * * *"
      when "daily" then "#{minute} #{hour} * * *"
      when "weekdays" then "#{minute} #{hour} * * 1-5"
      when "weekly" then "#{minute} #{hour} * * #{weekday}"
      end
    end

    # Fugit applies the time zone, daylight saving included; nil when the fields cannot make a cron.
    # The time goes in as UTC: a local Time carries only an abbreviation, and "CEST" is ambiguous
    # in the hour the autumn clock change repeats.
    # On the autumn change the wall clock repeats an hour: a daily slot in it comes back as a second copy one
    # hour later, which is skipped. An hourly schedule keeps both, because they are an hour apart.
    def next_after(time)
      return next_hourly_after(time) if frequency == "hourly"

      parsed = Fugit::Cron.parse("#{cron} #{time_zone}")
      slot = parsed&.next_time(time.utc)&.to_t
      return slot if slot.nil? || wall_clock(slot - 1.hour) != wall_clock(slot)

      parsed.next_time(slot.utc).to_t
    end

    # The slot just served and every slot missed while busy collapse into one: the next is after now.
    def advance!(at = Time.current) = update!(next_run_at: next_after(at))

    private

    def wall_clock(time) = time.in_time_zone(time_zone).strftime("%F %R")

    # Hourly slots walk real minutes instead of asking Fugit: on the autumn change its answer
    # depended on the process time zone and could skip the repeated hour.
    def next_hourly_after(time)
      candidate = time.utc.change(sec: 0) + 1.minute
      120.times do
        return candidate if candidate.in_time_zone(time_zone).min == minute

        candidate += 1.minute
      end
      nil
    end

    # Runs after the field validations, so a broken field never reaches the cron parser.
    def plan_next_run
      return if errors.any?

      self.next_run_at = next_after(Time.current)
      errors.add(:frequency, :invalid) if next_run_at.nil?
    end

    # "Rome" and "Europe/Rome" both become the IANA name that Fugit understands.
    def normalize_time_zone
      self.time_zone = ActiveSupport::TimeZone[time_zone.to_s]&.tzinfo&.name || time_zone
    end

    def known_time_zone
      errors.add(:time_zone, :invalid) unless time_zone.present? && ActiveSupport::TimeZone[time_zone]
    end
  end
end
