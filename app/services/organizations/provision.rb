# frozen_string_literal: true

module Organizations
  # Provisioning god-initiated: crea l'organizzazione e il suo owner. Se l'owner non esiste, viene
  # creato senza password reale e riceve un link di setup (reset). Tutto in transazione.
  class Provision < ApplicationService
    def initialize(name:, owner_email:)
      @name = name
      @owner_email = owner_email.to_s.strip.downcase
    end

    def call
      organization = nil
      owner = nil
      send_setup = false

      ActiveRecord::Base.transaction do
        owner = Accounts::Account.find_or_initialize_by(email: @owner_email)
        if owner.new_record?
          temporary = "#{SecureRandom.alphanumeric(16)}Aa1!"
          owner.name = @owner_email.split("@").first.presence || "Owner"
          owner.password = temporary
          owner.password_confirmation = temporary
          owner.save!
          send_setup = true
        end

        organization = Organizations::Organization.create!(
          name: @name,
          slug: Organizations::Organization.generate_unique_slug(@name),
          created_by: owner
        )
        Connections::Membership.create!(account: owner, organization: organization, role: :owner)
        Types::InstallDefaults.call(organization: organization, created_by: owner)
        Alerting::Rules::InstallDefaults.call(organization: organization, created_by: owner)
        # I ruoli default li installava solo la registrazione self-service, chiusa con CYRA-249: senza
        # questa riga l'unica via rimasta creerebbe org prive di Administrator/Maintainer/Triager/Viewer,
        # e l'owner non avrebbe alcun ruolo da dare a chi invita. Idempotente.
        Authorization::InstallDefaultRoles.call(organization: organization, created_by: owner)
      end

      Auth::PasswordsMailer.reset(owner).deliver_later if send_setup
      Result.ok(organization)
    rescue ActiveRecord::RecordInvalid => e
      Result.err(AppError.new(e.message, code: "R422-ORG-001", details: e.record.errors.to_hash))
    end
  end
end
