# frozen_string_literal: true

module ApplicationCable
  # Base per tutti i channel applicativi. Gli stream realtime usano Turbo::StreamsChannel
  # (nomi-stream firmati da Realtime::Streams) — questa base esiste per coerenza Rails 8 e
  # per eventuali channel custom futuri.
  class Channel < ActionCable::Channel::Base
  end
end
