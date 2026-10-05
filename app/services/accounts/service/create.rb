# frozen_string_literal: true

module Accounts
  # Namespace dei service account (Accounts::Account kind: :service). Un nome = una parola: il
  # sotto-namespace "Service" identifica il dominio, le classi restano leaf (Create, IssueToken).
  module Service
    # Crea un service account (agente AI, non-umano, CLI-only) dentro un'org e ne imposta l'accesso.
    # In UNA transazione: (1) account kind: :service con email sintetica + password random (mai usata:
    # niente login web), (2) Connections::Membership role :member (aggancio all'RBAC), (3) visibilità
    # sui progetti/gruppi concessi (SetMemberAccess), (4) ruoli diretti opzionali (SetAccountRoles) e,
    # se grant_secrets, gli override allow secrets.read+secrets.manage (SetAccountPermissions) così
    # l'agente legge/scrive i secret dei SOLI progetti visibili. Result pattern.
    class Create < ApplicationService
      SECRETS_KEYS = %w[secrets.read secrets.manage].freeze
      MAX_HANDLE_ATTEMPTS = 3

      def initialize(organization:, name:, handle: nil, project_ids: [], group_ids: [],
                     role_ids: [], grant_secrets: false, secret_environment_codes: [],
                     actor: nil, true_actor: nil)
        @organization = organization
        @name = name.to_s.strip
        @handle = handle
        @project_ids = project_ids
        @group_ids = group_ids
        @role_ids = role_ids
        @grant_secrets = grant_secrets
        @secret_environment_codes = secret_environment_codes
        @actor = actor
        @true_actor = true_actor
      end

      def call
        account = nil
        failure = nil

        ActiveRecord::Base.transaction do
          account = create_account!
          create_membership!(account)

          steps = [
            # actor: anche sullo scope (CYRA-237) — un delegato non-owner non può coniare un service account
            # con visibilità (e secret) su progetti/gruppi che lui stesso non vede.
            Connections::SetMemberAccess.call(organization: @organization, account: account,
                                              group_ids: @group_ids, project_ids: @project_ids, actor: @actor),
            Authorization::SetAccountRoles.call(organization: @organization, account: account,
                                                role_ids: @role_ids, actor: @actor, true_actor: @true_actor)
          ]
          if @grant_secrets
            steps << Authorization::SetAccountPermissions.call(
              organization: @organization, account: account,
              allow_keys: SECRETS_KEYS, actor: @actor, true_actor: @true_actor
            )
          end

          failing = steps.find(&:err?)
          if failing
            failure = failing.error
            raise ActiveRecord::Rollback
          end
        end

        return Result.err(failure) if failure

        Result.ok(account)
      rescue ActiveRecord::RecordInvalid => e
        Result.err(AppError.new(e.message, code: "R422-SERVICEACCOUNT-001", details: e.record&.errors&.to_hash))
      rescue ActiveRecord::RecordNotUnique => e
        # Backstop se anche i retry sull'handle collidono (race persistente): err pulito, mai 500.
        Result.err(AppError.new(e.message, code: "R422-SERVICEACCOUNT-001"))
      end

      private

      # check-then-insert su handle globale unico: in una race due create concorrenti possono superare
      # entrambe unique_handle e far scattare l'indice unico DB (RecordNotUnique — NON RecordInvalid).
      # Savepoint (requires_new) + retry: ricalcola l'handle e ridedup invece di far fallire (o 500).
      def create_account!
        attempts = 0
        begin
          ActiveRecord::Base.transaction(requires_new: true) do
            handle = unique_handle(@handle.presence || @name)
            Accounts::Account.create!(
              kind: :service,
              name: @name,
              handle: handle,
              email: "service+#{handle}@#{@organization.slug}.cyi.local",
              password: random_password
            )
          end
        rescue ActiveRecord::RecordNotUnique
          raise if (attempts += 1) >= MAX_HANDLE_ATTEMPTS

          retry
        end
      end

      def create_membership!(account)
        Connections::Membership.create!(account: account, organization: @organization, role: :member,
                                        secret_environment_codes: sanitized_environment_codes)
      end

      # Solo i code che esistono davvero come environment dell'org (evita di bloccare l'account fuori da
      # tutto per un code inesistente). Vuoto = nessuna restrizione. normalizes sul model ripulisce comunque.
      def sanitized_environment_codes
        wanted = Array(@secret_environment_codes).map { |c| c.to_s.strip.downcase }.reject(&:blank?)
        return [] if wanted.empty?

        wanted & @organization.environments.pluck(:code)
      end

      # Handle globale unico [a-z0-9_]. Il service account non fa @menzioni, ma la colonna è unica:
      # dedup con suffisso numerico (come Account#ensure_handle) invece di far fallire il create.
      def unique_handle(base)
        base = base.to_s.strip.downcase.gsub(/[^a-z0-9_]+/, "_").gsub(/\A_+|_+\z/, "")
        base = "service" if base.blank?
        candidate = base
        n = 0
        while Accounts::Account.exists?(handle: candidate)
          n += 1
          candidate = "#{base}#{n}"
        end
        candidate
      end

      # Password che soddisfa PASSWORD_FORMAT (min 8 + 4 classi) e non viene MAI rivelata: il service
      # account non fa login web. La suffissa "aA1!" garantisce le 4 classi qualunque sia il random.
      def random_password
        "#{SecureRandom.alphanumeric(24)}aA1!"
      end
    end
  end
end
