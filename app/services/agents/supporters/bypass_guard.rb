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

      module_function

      # The names of the patterns the text hits; empty when none.
      def match(text)
        clean = text.to_s
        PATTERNS.filter_map { |name, pattern| name if clean.match?(pattern) }
      end
    end
  end
end
