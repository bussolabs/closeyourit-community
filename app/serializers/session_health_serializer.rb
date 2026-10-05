# frozen_string_literal: true

class SessionHealthSerializer < ApplicationSerializer
  attributes :id, :project_id, :sid, :release, :environment, :status, :duration, :abnormal_mechanism,
    :started_at, :created_at, :updated_at, :initialization_seen, :observed_update_count
  %i[started_unix_nano update_unix_nano sequence].each do |name|
    attribute(name) { |session| session.public_send(name).to_i.to_s }
  end
  attribute(:errors) { |session| session.errors_count.to_i.to_s }
  attribute(:deduplication) { |session| session.producer_identity ? "sid" : "unavailable" }
end
