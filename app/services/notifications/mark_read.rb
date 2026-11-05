# frozen_string_literal: true

module Notifications
  # Opening a page marks read the viewer's own unread in-app notifications about what it shows, in one
  # update, and pushes the new bell count to the other open tabs only when something changed (CYRA-1146).
  # subjects: records, or relations for many subjects of one kind (a monitor's outages).
  class MarkRead < ApplicationService
    def initialize(account:, organization:, subjects:)
      @account = account
      @organization = organization
      @subjects = subjects
    end

    def call
      updated = own_unread.and(about_subjects).update_all(read_at: Time.current)
      Deliver.broadcast_unread_count(account: @account, organization: @organization) if updated.positive?
      updated
    end

    private

    # Same scope as the inbox and the bell: this account, this organization, in-app only.
    def own_unread
      Alerting::Notification.where(account_id: @account.id, organization_id: @organization.id, via: :in_app).unread
    end

    def about_subjects
      @subjects.map { |subject| about(subject) }.reduce(:or)
    end

    def about(subject)
      return Alerting::Notification.where(subject: subject) unless subject.is_a?(ActiveRecord::Relation)

      Alerting::Notification.where(subject_type: subject.klass.polymorphic_name, subject_id: subject.select(:id))
    end
  end
end
