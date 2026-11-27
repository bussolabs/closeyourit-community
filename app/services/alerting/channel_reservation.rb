# frozen_string_literal: true

module Alerting
  # Acquisition and compare/delete share the channel's database lock across workers.
  # A token prevents an expired delivery from releasing its successor's window. CYRA-1227
  class ChannelReservation
    def self.acquire(channel:, key:, expires_in:)
      token = SecureRandom.uuid
      channel.with_lock do
        token if Rails.cache.write(key, token, unless_exist: true, expires_in: expires_in)
      end
    end

    # Another event already owns the window: the old one ended, even if its clock says otherwise.
    def self.superseded?(key:, token:)
      held = Rails.cache.read(key)
      held.present? && held != token
    end

    def self.release(channel_id:, key:, token:)
      return if key.blank? || token.blank?

      channel = Alerting::Channel.find_by(id: channel_id)
      if channel
        channel.with_lock { Rails.cache.delete(key) if Rails.cache.read(key) == token }
      else
        # A deleted channel cannot acquire another reservation.
        Rails.cache.delete(key) if Rails.cache.read(key) == token
      end
    end
  end
end
