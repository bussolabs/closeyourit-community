# frozen_string_literal: true

# CYRA-1330 — whose fault it was when the review of a delivery produced no verdict.
#
# The machine already says it (CYAU-335), but only inside the failure reason — a free-text line that
# also carries tracebacks. A cap that decides whether a piece of work stops cannot be counted off a
# sentence: rephrase the sentence and the count silently changes. So the fault travels in a column of
# its own, and the reason stays what it is, an audit line.
#
# No check constraint on the value: the kinds live in Agents::Attempt::REVIEW_FAULT_KINDS, mirrored
# from the automator's own list, and a list in the database would have to be migrated every time that
# list grows. Nullable because almost no attempt has one: a fault is declared only by the delivery
# channel that gives the work back without a judgement.
class AddReviewFaultToAgentsAttempts < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_attempts, :review_fault, :string
  end
end
