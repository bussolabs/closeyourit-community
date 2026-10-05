# frozen_string_literal: true

Rails.application.config.to_prepare do
  Turbo::StreamsChannel.prepend(Realtime::AuthorizedStreams)
end
