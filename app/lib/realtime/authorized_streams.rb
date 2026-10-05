# frozen_string_literal: true

module Realtime
  # A signed stream name proves past access. Recheck current authority on every delivery.
  module AuthorizedStreams
    def subscribed
      stream = verified_stream_name_from_params
      return reject unless stream && authorized_stream?(stream)

      stream_from stream, coder: ActiveSupport::JSON do |message|
        if authorized_stream?(stream)
          transmit(message)
        else
          stop_all_streams
          connection.close(reconnect: false)
        end
      end
    end

    private

    def authorized_stream?(stream)
      account = connection.live_account
      return false unless account

      tenant = /\Aorg:([^:]+):(.+)\z/.match(stream)
      return true unless tenant
      return false unless tenant[1] == connection.current_organization&.id

      name = tenant[2]
      if (chat = /\Achat:conversation:([^:]+)\z/.match(name))
        conversation = Chat::Conversation.find_by(id: chat[1], organization_id: tenant[1])
        return conversation&.accessible_by?(account) || false
      end

      scope = Authorization::VisibleScope.new(account: account, organization: connection.current_organization)
      if (project = /:project:([^:]+)\z/.match(name))
        return scope.projects.exists?(id: project[1])
      end

      resource = /\A(ticket|monitor|error_group|metric_group|cron_monitor|seo_site):([^:]+)\z/.match(name)
      if resource
        relations = { "ticket" => :tickets, "monitor" => :monitors, "error_group" => :error_groups,
                      "metric_group" => :metric_groups, "cron_monitor" => :cron_monitors, "seo_site" => :seo_sites }
        return scope.public_send(relations.fetch(resource[1])).exists?(id: resource[2])
      end
      true
    end
  end
end
