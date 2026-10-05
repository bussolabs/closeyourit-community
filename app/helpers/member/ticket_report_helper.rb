# frozen_string_literal: true

module Member
  # The work report as the Report tab shows it: bold labels become section headings, and a version
  # can be compared line by line with the one before it. CYRA-883
  module TicketReportHelper
    SECTION_LABEL = /^\*\*([^*\n]{1,40}?):\*\*[ \t]*/

    # Beyond this many line pairs the comparison is skipped: a huge report is read, not diffed.
    DIFF_CELL_LIMIT = 250_000

    def report_with_sections(body)
      body.to_s.gsub(SECTION_LABEL) { "#### #{Regexp.last_match(1)}\n\n" }
    end

    # Removed and added lines in reading order, as `[:removed | :added, line]`; blank lines are ignored.
    def report_changes(previous, current)
      before = previous.to_s.lines.map(&:rstrip).reject(&:blank?)
      after = current.to_s.lines.map(&:rstrip).reject(&:blank?)
      return [] if before.size * after.size > DIFF_CELL_LIMIT

      walk_changes(before, after, common_lengths(before, after))
    end

    private

    # lengths[i][j] = longest common run of lines between before[i..] and after[j..].
    def common_lengths(before, after)
      lengths = Array.new(before.size + 1) { Array.new(after.size + 1, 0) }
      (before.size - 1).downto(0) do |i|
        (after.size - 1).downto(0) do |j|
          lengths[i][j] = before[i] == after[j] ? lengths[i + 1][j + 1] + 1 : [ lengths[i + 1][j], lengths[i][j + 1] ].max
        end
      end
      lengths
    end

    def walk_changes(before, after, lengths)
      changes = []
      i = j = 0
      while i < before.size && j < after.size
        if before[i] == after[j]
          i += 1
          j += 1
        elsif lengths[i + 1][j] >= lengths[i][j + 1]
          changes << [ :removed, before[i] ]
          i += 1
        else
          changes << [ :added, after[j] ]
          j += 1
        end
      end
      changes + before[i..].map { |line| [ :removed, line ] } + after[j..].map { |line| [ :added, line ] }
    end
  end
end
