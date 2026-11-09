# frozen_string_literal: true

module Agents
  module Supporters
    # CYRA-1197 — actions that skip the system's own gates or can damage production. Releases go through CI,
    # data in production is never dropped by hand, secrets are never read out, checks are never skipped. A text
    # that proposes one of these is never approved by a machine: the server matches it here, without trusting
    # the model. Over-matching only sends more to a person, so it is the safe mistake.
    module BypassGuard
      PATTERNS = {
        "manual_deploy" => /\bkamal\s+(app\s+)?(deploy|redeploy|rollback|setup|remove)\b/i,
        "force_push" => /\bgit\s+push\b[^\n]*(--force\b|--force-with-lease\b|\s-f\b)/i,
        "push_to_main" => /\bgit\s+push\b[^\n]*\b(origin\s+)?(HEAD:)?(main|master)\b/i,
        "skip_hooks" => /--no-verify\b/i,
        "skip_ci" => /\[(skip ci|ci skip|no ci)\]/i,
        "destructive_sql" => /\b(drop\s+(table|database|schema)|truncate\s+table|delete\s+from\s+\w+\s*;)/i,
        "destructive_task" => /\b(db:(drop|reset|purge|schema:load)|DISABLE_DATABASE_ENVIRONMENT_CHECK)\b/i,
        "secret_read" => /\b(cyi\s+secrets\s+(get|download)|cat\s+\S*\.env\b|printenv\b|rails\s+credentials:show)\b/i,
        "skip_tests" => /\b(skip|disable|delete|remove)\s+(the\s+)?(failing\s+)?(tests?|specs?|checks?|ci)\b/i
      }.freeze

      # Guidance states the rules as prohibitions ("do not skip checks", "with no --no-verify"): a gate named
      # right after a negation is forbidden, not proposed. Only the few words just before the match count, and
      # any punctuation in between breaks the link, so "do not worry, commit with --no-verify" is still a hit.
      NEGATIONS = %w[not never no don't dont without avoid non mai senza nessun nessuna niente].freeze
      NEGATION_WINDOW = 3
      CLAUSE_BREAK = /[.,;:!?\n]/
      # CYRA-1197 — "do not use --no-verify or [skip ci]": a gate listed right after another gate shares its fate.
      LIST_LINK = /\s+(?:or|nor|and|o|né|e)\s*\[?\z/i

      module_function

      # The names of the patterns the text hits outside a negation; empty when none.
      def match(text)
        clean = text.to_s
        PATTERNS.filter_map do |name, pattern|
          name if clean.to_enum(:scan, pattern).any? { !negated?(clean[0...Regexp.last_match.begin(0)]) }
        end
      end

      def negated?(before)
        clause = before.split(CLAUSE_BREAK, -1).last.to_s
        return true if clause.downcase.split.last(NEGATION_WINDOW).any? { |word| NEGATIONS.include?(word) }

        head = clause.sub(LIST_LINK, "")
        return false if head == clause

        previous = previous_gate(head.rstrip)
        previous ? negated?(head[0...previous]) : false
      end

      # Where a gate ending exactly at the end of the text starts, or nil when the text does not end with one.
      def previous_gate(text)
        PATTERNS.each_value do |pattern|
          text.to_enum(:scan, pattern).each { return Regexp.last_match.begin(0) if Regexp.last_match.end(0) == text.length }
        end
        nil
      end
    end
  end
end
