# frozen_string_literal: true

module Organizations
  module FirstSteps
    # The first-steps list the Home shows (CYRA-1159): the five steps in order, each with its day or
    # nil. `for` answers nil once the list is complete or closed, so it never comes back.
    class Checklist
      Item = Data.define(:step, :reached_at) do
        def done? = reached_at.present?
      end

      attr_reader :items

      def self.for(organization)
        return nil if organization.nil? || organization.first_steps_dismissed_at.present?

        # Through the id, not the association: the organization of the Home is strict_loading.
        reached = FirstStep.where(organization_id: organization.id).pluck(:step, :reached_at).to_h
        items = FirstStep::STEPS.map { |step| Item.new(step: step, reached_at: reached[step]) }
        items.all?(&:done?) ? nil : new(items)
      end

      # Closing hides the list from every colleague, so only owner and admin may.
      def self.dismissable_by?(membership) = membership&.role.in?(%w[admin owner])

      def initialize(items)
        @items = items
      end

      def done_count = items.count(&:done?)
      def total = items.size
    end
  end
end
