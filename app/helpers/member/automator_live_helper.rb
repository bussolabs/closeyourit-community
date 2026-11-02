# frozen_string_literal: true

module Member
  # CYRA-1138 — the lines of one change on the live page, numbered like a review: removed lines keep the
  # old number, added lines the new one, context lines both.
  module AutomatorLiveHelper
    Line = Data.define(:kind, :old_number, :new_number, :text)
    KINDS = { "-" => :removed, "+" => :added }.freeze
    # CYRA-1139 — one colour per agent in the project view; literal classes so Tailwind sees them. The name always
    # stands next to the colour, which is never the only way to tell two agents apart.
    AGENT_COLORS = {
      violet: { dot: "bg-violet-500", text: "text-violet-700 dark:text-violet-300", edge: "border-violet-400 dark:border-violet-500/60", tag: "bg-violet-600 text-white" },
      amber: { dot: "bg-amber-500", text: "text-amber-800 dark:text-amber-300", edge: "border-amber-400 dark:border-amber-500/60", tag: "bg-amber-400 text-amber-950" },
      teal: { dot: "bg-teal-500", text: "text-teal-700 dark:text-teal-300", edge: "border-teal-400 dark:border-teal-500/60", tag: "bg-teal-700 text-white" },
      sky: { dot: "bg-sky-500", text: "text-sky-700 dark:text-sky-300", edge: "border-sky-400 dark:border-sky-500/60", tag: "bg-sky-700 text-white" },
      rose: { dot: "bg-rose-500", text: "text-rose-700 dark:text-rose-300", edge: "border-rose-400 dark:border-rose-500/60", tag: "bg-rose-600 text-white" },
      lime: { dot: "bg-lime-600", text: "text-lime-800 dark:text-lime-300", edge: "border-lime-500 dark:border-lime-500/60", tag: "bg-lime-400 text-lime-950" }
    }.freeze

    def automator_live_lines(hunk)
      old_number = hunk.old_start
      new_number = hunk.new_start
      hunk.lines.map do |line|
        kind = KINDS.fetch(line[0], :context)
        numbers = { old_number: (old_number unless kind == :added), new_number: (new_number unless kind == :removed) }
        old_number += 1 unless kind == :added
        new_number += 1 unless kind == :removed
        Line.new(kind:, text: line[1..].to_s, **numbers)
      end
    end

    # A change or a step only animates in the few seconds after it arrived: a page opened later shows it still.
    ARRIVAL_WINDOW = 12.seconds
    # New lines of a fresh change enter one after another, this far apart, up to the cap.
    LINE_STAGGER_MS = 90
    LINE_STAGGER_CAP = 15

    def automator_live_color(agent, part) = automator_live_paint(agent.color, part)

    def automator_live_paint(color, part) = AGENT_COLORS.fetch(color).fetch(part)

    # [[folder, entries], ...]: the files under their folder, both in path order; "" for the project root.
    def automator_live_tree(entries)
      entries.group_by { ::Agents::LiveEvents::ProjectTree::Index.parent_of(it.path) }.sort.map { |folder, list| [ folder, list.sort_by(&:path) ] }
    end

    # A frame id per folder of the project tree; hex keeps "a/b" and "a-b" apart.
    def automator_live_tree_frame(dir) = "automator-live-tree-#{dir.unpack1("H*")}"

    def automator_live_indent(depth) = "padding-left: #{0.5 + (depth * 0.75)}rem"

    def automator_live_fresh?(time) = time.present? && time >= ARRIVAL_WINDOW.ago

    # m:ss, or h:mm:ss past an hour: the first value of the timer the browser then keeps ticking.
    def automator_live_elapsed(since)
      seconds = [ (Time.current - since).to_i, 0 ].max
      hours, rest = seconds.divmod(3600)
      hours.positive? ? format("%d:%02d:%02d", hours, *rest.divmod(60)) : format("%d:%02d", *rest.divmod(60))
    end

    def automator_live_stagger(index) = "animation-delay: #{[ index, LINE_STAGGER_CAP ].min * LINE_STAGGER_MS}ms"

    def automator_live_engine(runtime) = runtime.to_s.capitalize

    def automator_live_number(ticket) = ticket.code.split("-").last

    def automator_live_time(time) = l(time.in_time_zone, format: "%H:%M:%S")
  end
end
