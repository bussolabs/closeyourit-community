# frozen_string_literal: true

module Agents
  module Hosts
    # Registra l'identità stabile di un'installazione Automator. Un retry sul fingerprint riusa
    # l'host ma ruota l'unico token attivo: così il nuovo secret può essere rivelato senza mai
    # conservare segreti reversibili. Lock + indice parziale serializzano anche retry concorrenti.
    class Register < ApplicationService
      SECRET_RANDOM_LENGTH = 40
      DISPLAY_PREFIX_LENGTH = 15

      def initialize(organization:, service_account: nil, fingerprint: nil, hostname: nil, platform: nil, arch: nil, automator_version: nil)
        @organization = organization
        @service_account = service_account
        @fingerprint = fingerprint.to_s.strip.downcase
        @attributes = { hostname:, platform: platform.to_s.strip.downcase, arch:, automator_version: }
      end

      def call
        return unsupported_platform unless @attributes[:platform] == Agents::Host::SUPPORTED_PLATFORM

        service_account_error = nil
        value = Agents::Host.transaction do
          host = resolve_host
          created = host.previously_new_record?
          host.lock!

          if host.revoked?
            next Result.err(AppError.new("Host automator revocato", code: "R403-AGENT-001", status: :forbidden))
          end

          # La macchina porta la PROPRIA identità: il service account creato dall'admin col suo scope, passato
          # dal controller (Current.account). Un host si lega a UN solo service account — un altro non può
          # rilevarlo (409). Il register NON tocca mai ruoli/permessi/ambienti del service account: lo scope
          # resta quello deciso alla creazione (il minion non può auto-ampliarsi). Verifica PRIMA di mutare.
          if @service_account && host.service_account_id.present? && host.service_account_id != @service_account.id
            next Result.err(AppError.new(
              "Host già registrato da un altro service account",
              code: "R409-AGENT-003", status: :conflict
            ))
          end

          host.update!(@attributes)

          # L'host possiede 1 solo service account (la sua identità operativa), legato una sola volta. Con
          # identità esplicita (canale API) la si adotta; senza (registrazioni di setup) si crea come prima —
          # in entrambi i casi nasce senza progetti (fail-closed): l'accesso si concede a parte, per-host.
          if host.service_account_id.nil?
            if @service_account
              # Un service account = un host (indice unico su agents_hosts.service_account_id). Se questo SA è
              # già legato a un ALTRO host, rifiuta in modo controllato (409) invece di far scattare l'unique
              # index → RecordNotUnique → 500. Il rescue RecordNotUnique sotto è il backstop per la race.
              if @organization.agent_hosts.where.not(id: host.id).exists?(service_account_id: @service_account.id)
                service_account_error = Result.err(AppError.new(
                  "Il service account è già legato a un altro host", code: "R409-AGENT-004", status: :conflict
                ))
                raise ActiveRecord::Rollback
              end
              host.update!(service_account: @service_account)
            else
              service_account_error = ensure_service_account!(host)
              raise ActiveRecord::Rollback if service_account_error
            end
          end

          now = Time.current
          host.host_tokens.active.update_all(revoked_at: now, updated_at: now)

          secret = "#{Agents::Constants::HOST_TOKEN_PREFIX}#{SecureRandom.alphanumeric(SECRET_RANDOM_LENGTH)}"
          token = host.host_tokens.create!(
            token_digest: Digest::SHA256.hexdigest(secret),
            token_prefix: secret.first(DISPLAY_PREFIX_LENGTH)
          )
          Result.ok({ host:, token:, secret:, created: })
        end
        return service_account_error if service_account_error

        value
      rescue ActiveRecord::RecordInvalid => e
        record = e.respond_to?(:record) ? e.record : nil
        Result.err(
          AppError.new(
            e.message,
            code: "R422-AGENT-004",
            details: record&.errors&.as_json
          )
        )
      rescue ActiveRecord::RecordNotUnique => e
        # Backstop concorrente SELETTIVO: solo l'unique index su service_account_id (due registrazioni per lo
        # stesso service account in parallelo) diventa un 409 controllato invece di un 500. Ogni altra unique
        # violation (es. token digest) è un errore imprevisto e va rilanciata, non inghiottita.
        raise unless e.message.include?("index_agents_hosts_on_service_account_id")

        Result.err(AppError.new(
          "Il service account è già legato a un altro host", code: "R409-AGENT-004", status: :conflict
        ))
      end

      private

      def unsupported_platform
        Result.err(
          AppError.new(
            "Piattaforma host non supportata",
            code: "R422-AGENT-004",
            status: :unprocessable_content,
            details: { platform: [ "deve essere linux" ] }
          )
        )
      end

      def resolve_host
        hosts = @organization.agent_hosts
        hosts.find_by(fingerprint: @fingerprint) || hosts.create_or_find_by!(fingerprint: @fingerprint) do |host|
          host.assign_attributes(@attributes)
        end
      end

      # Crea e collega il service account dell'host. Ritorna nil se ok, oppure il Result.err della creazione
      # (per rollback + propagazione). Handle derivato dal fingerprint (unico per org; Service::Create dedup
      # globale con suffisso). Nessun progetto concesso qui: l'accesso si configura per-host a parte.
      def ensure_service_account!(host)
        result = Accounts::Service::Create.call(
          organization: @organization,
          name: "Host #{host.hostname.presence || host.fingerprint}",
          handle: "host_#{host.fingerprint.gsub(/[^a-z0-9]/, '_').first(24)}",
          grant_secrets: false
        )
        return result if result.err?

        host.update!(service_account: result.value)
        nil
      end
    end
  end
end
