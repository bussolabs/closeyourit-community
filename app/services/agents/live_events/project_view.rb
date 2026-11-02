# frozen_string_literal: true

module Agents
  module LiveEvents
    # CYRA-1139 — every agent at work on one project: a colour each, in the order they started, and the files
    # two of them change; the live page of each agent warns about its own conflicts. Red when their changed lines touch, yellow when they do not or one side sent no line
    # numbers (the machine sends them only with live code on). Line numbers are each agent's own copy: a hint.
    class ProjectView
      PALETTE = %i[violet amber teal sky rose lime].freeze
      LEVELS = %i[lines unknown file].freeze

      Agent = Data.define(:attempt, :ticket, :color, :session) do
        def name = ticket.code
      end

      Touch = Data.define(:agent, :entry)

      ProjectFile = Data.define(:path, :touches, :level) do
        def agents = touches.map(&:agent)
        def conflict? = touches.size > 1
        # When the second agent first changed the file: the moment the conflict was born.
        def since = touches.map { it.entry.changes.first.at }.max
      end

      attr_reader :agents, :files

      # One colour per attempt, by start order inside its own project, so every page paints an agent alike.
      # attempts: with workflow: :ticket loaded.
      def self.colors(attempts)
        attempts.group_by { it.workflow.ticket.project_id }.each_value.with_object({}) do |group, colors|
          group.sort_by(&:started_at).each_with_index { |attempt, index| colors[attempt.id] = PALETTE[index % PALETTE.size] }
        end
      end

      # attempts: already filtered to what the viewer may see, with workflow: :ticket loaded.
      def initialize(attempts:)
        events = AttemptLiveEvent.where(attempt_id: attempts.map(&:id)).order(:seq).group_by(&:attempt_id)
        colors = self.class.colors(attempts)
        @agents = attempts.sort_by(&:started_at).map do |attempt|
          Agent.new(attempt:, ticket: attempt.workflow.ticket, color: colors.fetch(attempt.id),
                    session: Session.new(attempt:, events: events.fetch(attempt.id, [])))
        end
        @files = build_files
      end

      def file(path) = @files.find { it.path == path }


      def conflicts = @files.select(&:conflict?).sort_by { [ LEVELS.index(it.level), it.path ] }

      # The conflicts one agent is part of: what its live page warns about (CYRA-1138).
      def conflicts_with(attempt) = conflicts.select { |file| file.agents.any? { it.attempt.id == attempt.id } }

      private

      def build_files
        touches = Hash.new { |hash, path| hash[path] = [] }
        @agents.each do |agent|
          agent.session.files.select(&:changed?).each { touches[it.path] << Touch.new(agent:, entry: it) }
        end
        touches.sort.map { |path, list| ProjectFile.new(path:, touches: list, level: level(list)) }
      end

      def level(touches)
        return nil if touches.size < 2

        ranges = touches.map { ranges(it.entry) }
        return :unknown if ranges.any?(&:nil?)

        ranges.combination(2).any? { |left, right| overlap?(left, right) } ? :lines : :file
      end

      # nil when a change carries no line numbers at all.
      def ranges(entry)
        hunks = entry.changes.flat_map { it.hunks || [ nil ] }
        return nil if hunks.empty? || hunks.any?(&:nil?)

        hunks.map { |hunk| hunk.old_start..(hunk.old_start + [ hunk.old_lines, 1 ].max - 1) }
      end

      # Adjacent lines conflict too: Git refuses to merge two edits with no unchanged line between them.
      def overlap?(left, right)
        left.any? { |a| right.any? { |b| a.first <= b.last + 1 && b.first <= a.last + 1 } }
      end
    end
  end
end
