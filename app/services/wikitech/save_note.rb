# frozen_string_literal: true

module Wikitech
  # Stores a note sent by a member (CYRA-1128). Sending the same text from the same source again
  # returns the stored note instead of a duplicate, so a script can resend without harm.
  class SaveNote < ApplicationService
    Outcome = Data.define(:note, :duplicate)

    def initialize(organization:, author:, params:)
      @organization = organization
      @author = author
      @params = params
    end

    def call
      body = LengthBudget.normalize_newlines(@params[:body]).strip
      return err("R422-WIKITECH-001", t(:body_blank)) if body.blank?
      if body.length > Wikitech::Constants::NOTE_BODY_MAX_CHARS
        return err("R422-WIKITECH-002", t(:body_too_long, count: Wikitech::Constants::NOTE_BODY_MAX_CHARS))
      end

      invalid = urls.find { |url| !http_url?(url) }
      return err("R422-WIKITECH-003", t(:url_invalid, url: invalid)) if invalid

      checksum = Wikitech::Note.checksum_for(body: body, source_url: source_url)
      existing = @organization.wikitech_notes.find_by(checksum: checksum)
      return Result.ok(Outcome.new(note: existing, duplicate: true)) if existing

      create(body, checksum)
    end

    private

    def create(body, checksum)
      note = @organization.wikitech_notes.new(
        created_by: @author, body: body, checksum: checksum,
        source_label: @params[:source_label], source_url: source_url,
        source_published_at: @params[:source_published_at].presence,
        links: links
      )
      return err("R422-WIKITECH-005", note.errors.full_messages.to_sentence) unless note.save

      Wikitech::ProcessNoteJob.perform_later(note_id: note.id)
      Result.ok(Outcome.new(note: note, duplicate: false))
    rescue ActiveRecord::RecordNotUnique
      # Two identical sends at the same moment: the other one won, return it.
      Result.ok(Outcome.new(note: @organization.wikitech_notes.find_by!(checksum: checksum), duplicate: true))
    end

    def source_url = @params[:source_url].to_s.strip.presence

    def links
      Array(@params[:links]).map { |link| link.to_s.strip }.compact_blank.uniq
                            .first(Wikitech::Constants::NOTE_LINKS_MAX)
    end

    def urls = [ source_url, *links ].compact

    def http_url?(value)
      uri = URI.parse(value)
      uri.is_a?(URI::HTTP) && uri.host.present?
    rescue URI::InvalidURIError
      false
    end

    def t(key, **options) = I18n.t("wikitech.errors.#{key}", **options)

    def err(code, message) = Result.err(AppError.new(message, code: code, status: :unprocessable_content))
  end
end
