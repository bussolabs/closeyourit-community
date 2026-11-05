# frozen_string_literal: true

require "json"

module Instance
  # The signed list of insecure community versions (CYRA-1160). The file is an envelope
  # {"payload": base64 JSON, "signature": base64 Ed25519 of those bytes}; the payload carries
  # issued_at and the advisories, each insecure from `introduced` (optional) up to `fixed_in` excluded.
  class Advisories
    class Invalid < StandardError; end

    Entry = Data.define(:id, :introduced, :fixed_in, :summary)
    # What the running version should do: the lowest version that closes every advisory it is in.
    Finding = Data.define(:fixed_in, :ids)

    attr_reader :issued_at, :entries

    # Raises Invalid unless one of the trusted keys signed exactly the payload bytes.
    def self.verify(body, keys: App::SelfHosted::ADVISORIES_PUBLIC_KEYS)
      envelope = JSON.parse(body.to_s)
      payload = Base64.strict_decode64(envelope.fetch("payload").to_s)
      signature = Base64.strict_decode64(envelope.fetch("signature").to_s)
      raise Invalid, "the signature matches no trusted key" unless keys.any? { |key| signed_by?(key, signature, payload) }

      from_payload(JSON.parse(payload))
    rescue JSON::ParserError, ArgumentError, KeyError, TypeError, NoMethodError => e
      raise Invalid, "unreadable list: #{e.class}"
    end

    def self.signed_by?(key, signature, payload)
      RbNaCl::VerifyKey.new(Base64.strict_decode64(key)).verify(signature, payload)
    rescue RbNaCl::BadSignatureError, RbNaCl::LengthError, ArgumentError
      false
    end

    # Also reads back the payload stored in Settings::Global, which was verified when it arrived.
    def self.from_payload(data)
      entries = Array(data.fetch("advisories")).map do |item|
        Entry.new(id: item.fetch("id").to_s, introduced: version!(item["introduced"], optional: true),
                  fixed_in: version!(item.fetch("fixed_in")), summary: item["summary"].to_s)
      end
      new(issued_at: Time.iso8601(data.fetch("issued_at").to_s), entries:)
    end

    def self.version!(value, optional: false)
      return if optional && value.nil?
      raise Invalid, "unexpected version #{value.inspect}" unless value.to_s.match?(ReleaseFeed::VERSION_FORMAT)

      value.to_s
    end

    def initialize(issued_at:, entries:)
      @issued_at = issued_at
      @entries = entries
    end

    def finding(version)
      version = version.to_s.delete_prefix("v")
      return unless version.match?(ReleaseFeed::VERSION_FORMAT)

      hits = entries.select { |entry| affects?(entry, Gem::Version.new(version)) }
      return if hits.empty?

      Finding.new(fixed_in: hits.map(&:fixed_in).max_by { |fixed| Gem::Version.new(fixed) }, ids: hits.map(&:id))
    end

    def to_payload
      { "issued_at" => issued_at.utc.iso8601,
        "advisories" => entries.map { |entry| entry.to_h.transform_keys(&:to_s).compact } }
    end

    private

    def affects?(entry, version)
      return false unless version < Gem::Version.new(entry.fixed_in)

      entry.introduced.nil? || version >= Gem::Version.new(entry.introduced)
    end
  end
end
