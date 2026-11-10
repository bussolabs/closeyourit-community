# frozen_string_literal: true

module Ops
  # Is the configured sender really allowed to send? (CYRA-233)
  #
  # Every product email (alerts, digests, invitations, password resets) leaves from ApplicationMailer's
  # `from`. Amazon SES refuses to send from an identity that is not verified in the account, and the refusal
  # shows up nowhere: the send runs inside a job, the failure is one failed job among others, and the
  # recipient simply gets nothing. It stayed that way until a person noticed by hand: the "something
  # breaks -> an alert arrives" path was broken exactly in the stretch that should have raised the alert.
  #
  # This check closes the loop: it asks SES for the identity of the real sender's domain. OBSERVATION only:
  # it sends no email (the broken channel would have to report itself), sends nothing as a test, repairs
  # nothing. Callers turn it into a signal: Ops::MailSenderCheckJob logs it, Valhalla::ProbeServices shows
  # it on /valhalla/health.
  #
  # It NEVER raises: the caller is a recurring run, and an exception would make it retry for nothing,
  # turning a provider outage into queue noise.
  class MailSenderCheck < ApplicationService
    # verified       -> the sender's domain is verified and enabled for sending: emails can leave.
    # unverified     -> the identity exists but is not verified or not enabled for sending (missing or
    #                   not yet propagated DNS records, sending paused).
    # unknown_domain -> the domain is not an SES identity at all: the CYRA-233 failure.
    # unconfigured   -> no SES credentials. In production the app turns delivery off
    #                   (config/environments/production.rb): not one mail leaves, even with perfect DNS.
    # invalid_sender -> the configured sender is not a readable email address.
    # error          -> SES does not answer: the sender's state stays unknown.
    # restricted_key -> SES REFUSES the read: the credentials may send but not read identities (CYRA-771).
    #                   The sender's state stays unknown, and the refusal says nothing about it.
    Result = Data.define(:status, :from, :domain, :detail) do
      def deliverable? = status == :verified

      # "I cannot check" is not "the sender does not send" (CYRA-771). Both cases used to end in the same
      # red: send-only credentials made the read fail, the rescue turned it into :error and the health card
      # showed mail down while emails were really leaving. An alarm that cries wolf teaches people to
      # ignore the real ones.
      #
      # Only :restricted_key, NEVER :error: the refusal is an explicit, narrow answer from the provider,
      # while :error is the bucket of everything we do not know, from a passing network timeout to revoked
      # or invalid credentials, which REALLY stop delivery because ApplicationMailer sends with them.
      def unverifiable? = status == :restricted_key
    end

    # The identity status SES considers good for sending. The others (PENDING, FAILED, TEMPORARY_FAILURE,
    # NOT_STARTED) all mean "it does not send today".
    VERIFIED = "SUCCESS"

    # Same region as the delivery settings in config/environments/production.rb.
    REGION = "eu-central-1"

    # No argument = the sender the emails will REALLY use. It does not read MAIL_FROM on its own:
    # ApplicationMailer's default already holds that value (or the fallback), and reading from two places
    # is how you check one sender and send from another.
    def initialize(from: ApplicationMailer.default[:from])
      @from = from.to_s
    end

    def call
      domain = sender_domain
      return result(:invalid_sender, nil, "sender is not a parsable address: #{@from.inspect}") if domain.blank?
      return result(:unconfigured, domain, "no provider credentials: delivery is off") if credentials.nil?

      identity = client.get_email_identity(email_identity: domain)
      return result(:verified, domain, nil) if identity.verification_status == VERIFIED && identity.verified_for_sending_status

      result(:unverified, domain,
             "domain #{domain} is in status #{identity.verification_status.presence || "unknown"} " \
             "(sending enabled: #{identity.verified_for_sending_status.inspect}), not verified")
    rescue Aws::SESV2::Errors::NotFoundException
      result(:unknown_domain, domain, "domain #{domain} is not among the identities configured at the provider")
    rescue StandardError => e
      return restricted_key_result if access_denied?(e)

      # The SDK error message never carries the credentials (they travel signed in headers): only class +
      # message ends up in the result anyway.
      result(:error, sender_domain, "#{e.class}: #{e.message}")
    end

    private

    # Same ENV pair the delivery method reads in config/environments/production.rb.
    def credentials
      access_key_id = ENV["AWS_SES_ACCESS_KEY_ID"]
      secret_access_key = ENV["AWS_SES_SECRET_ACCESS_KEY"]
      return if access_key_id.blank? || secret_access_key.blank?

      Aws::Credentials.new(access_key_id, secret_access_key)
    end

    def client = Aws::SESV2::Client.new(region: REGION, credentials:)

    # The SESv2 model declares no AccessDeniedException class: the SDK builds it on the fly from the error
    # code, so the code is what we match.
    def access_denied?(error)
      error.is_a?(Aws::SESV2::Errors::ServiceError) && error.code == "AccessDeniedException"
    end

    def restricted_key_result
      result(:restricted_key, sender_domain,
             "the provider credentials are not allowed to read identities: the sender's state stays unknown")
    end

    # `Mail::Address` is the parser ActionMailer itself uses, so it reads exactly what delivery will read:
    # display name, comments in parentheses (the staging sender has one), bare address. An unparsable value
    # raises: here it becomes `nil` and, above, :invalid_sender.
    def sender_domain
      Mail::Address.new(@from).domain.presence
    rescue StandardError
      nil
    end

    def result(status, domain, detail) = Result.new(status:, from: @from, domain:, detail:)
  end
end
