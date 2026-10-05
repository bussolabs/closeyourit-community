# frozen_string_literal: true

# Notifica in-app del notification center (canale CLI). title/body/url sono lo snapshot umano;
# event_type è il tipo (enum string); read = read_at presente. subject polimorfico (Errors::Group /
# Uptime::Incident / Ticketing::Ticket / Servers::Host / Chat::Message).
class AlertNotificationSerializer < ApplicationSerializer
  attributes :id, :event_type, :title, :body, :url, :project_id,
             :subject_type, :subject_id, :read_at, :created_at

  attribute :read do |notification|
    notification.read?
  end
end
