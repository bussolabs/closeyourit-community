# frozen_string_literal: true

module Projects
  module Moves
    # Shared secrets and files lent to moved projects: same name and content in the
    # destination is reused, different content blocks, otherwise the current value is copied (CYRA-879).
    class SharedSecrets
      def initialize(subject:, destination:)
        @subject = subject
        @destination = destination
      end

      def conflicts = entries.select { _1[:outcome] == :conflict }.map { _1.slice(:kind, :name, :environment_code) }
      def copies = entries.select { _1[:outcome] == :copy }.map { _1.slice(:kind, :name, :environment_code) }

      def apply!(environments:, actor:)
        raise AppError.new("Shared secrets conflict with the destination", code: "R409-PROJECTMOVE-003") if conflicts.any?

        variable_delegations.each { repoint_variable(_1, environments, actor) }
        file_delegations.each { repoint_file(_1, environments, actor) }
      end

      # Execute calls this after a rollback: the stored objects outlive their rolled-back rows (CYRA-879).
      def discard_uploads!
        uploaded_blobs.each { _1.service.delete(_1.key) }
      end

      # Execute calls this once the move has committed: the copies now belong to committed rows (CYRA-879).
      def keep_uploads! = uploaded_blobs.clear

      private

      def entries
        @entries ||= variable_delegations.map { variable_entry(_1) } + file_delegations.map { file_entry(_1) }
      end

      def variable_delegations
        @variable_delegations ||= Secrets::Shared::Delegation.where(project_id: @subject.project_ids)
                                                             .includes(shared_value: %i[shared_variable environment]).to_a
      end

      def file_delegations
        @file_delegations ||= Secrets::AssetDelegation.where(project_id: @subject.project_ids)
                                                      .includes(asset: :environment).to_a
      end

      def variable_entry(delegation)
        value = delegation.shared_value
        target = destination_value(value.name, value.environment.code)
        { kind: "variable", name: value.name, environment_code: value.environment.code,
          outcome: target.nil? ? :copy : (same_value?(target, value) ? :reuse : :conflict) }
      end

      def file_entry(delegation)
        asset = delegation.asset
        target = destination_asset(asset.name, asset.environment&.code)
        { kind: "file", name: asset.name, environment_code: asset.environment&.code,
          outcome: target.nil? ? :copy : (same_file?(target, asset) ? :reuse : :conflict) }
      end

      # The fingerprint is nil for short or not yet backfilled values: then the decrypted values decide (CYRA-879).
      def same_value?(target, value)
        if target.value_fingerprint && value.value_fingerprint
          target.value_fingerprint == value.value_fingerprint
        else
          target.value == value.value
        end
      end

      # A destination file without any version cannot be reused, so it counts as a conflict (CYRA-879).
      def same_file?(target, asset)
        target_version = target.current_version
        version = asset.current_version
        return false unless target_version && version
        return target_version.fingerprint == version.fingerprint if target_version.fingerprint && version.fingerprint

        left = decrypt(target_version)
        right = decrypt(version)
        left == right
      ensure
        left&.clear
        right&.clear
      end

      # Decrypts without Download so a move is not recorded as a user download (CYRA-879).
      def decrypt(version)
        encrypted = Secrets::Assets::Crypto::Encrypted.new(ciphertext: version.ciphertext.download,
          wrapped_key: version.wrapped_key, key_iv: version.key_iv, key_tag: version.key_tag,
          payload_iv: version.payload_iv, payload_tag: version.payload_tag, fingerprint: version.fingerprint)
        Secrets::Assets::Crypto.decrypt(encrypted, aad: version.aad)
      rescue Secrets::Assets::Crypto::IntegrityError
        raise AppError.new("Shared file could not be decrypted", code: "R422-PROJECTMOVE-004")
      end

      def destination_value(name, code)
        Secrets::Shared::Value.joins(:shared_variable, :environment)
                              .find_by(secrets_shared_variables: { organization_id: @destination.id, name: },
                                       types_environments: { code: })
      end

      def destination_asset(name, code)
        scope = Secrets::Asset.where(organization_id: @destination.id, project_id: nil, name:)
        code ? scope.joins(:environment).find_by(types_environments: { code: }) : scope.find_by(environment_id: nil)
      end

      # Skips validations on purpose: the project changes organization right after (CYRA-879).
      def repoint_variable(delegation, environments, actor)
        source = delegation.shared_value
        target = destination_value(source.name, source.environment.code) || copy_value(source, environments, actor)
        delegation.update_columns(shared_value_id: target.id)
      end

      # Recorded like a value created by hand: the name and version, never the value (CYRA-879).
      def copy_value(source, environments, actor)
        variable = Secrets::Shared::Variable.find_or_create_by!(organization_id: @destination.id, name: source.name) do |created|
          created.description = source.shared_variable.description
        end
        copy = variable.values.create!(environment_id: destination_environment_id(source.environment, environments),
                                       value: source.value)
        Secrets::Shared::Event.create!(organization_id: @destination.id, shared_variable: variable, environment_id: copy.environment_id,
                                       actor:, action: "created", name: variable.name, metadata: { version: copy.version_number })
        copy
      end

      # Skips validations on purpose: the project changes organization right after (CYRA-879).
      def repoint_file(delegation, environments, actor)
        source = delegation.asset
        target = destination_asset(source.name, source.environment&.code) || copy_asset(source, environments, actor)
        delegation.update_columns(asset_id: target.id)
      end

      def copy_asset(source, environments, actor)
        version = source.current_version
        plaintext = decrypt(version)
        copy = Secrets::Asset.create!(organization_id: @destination.id, name: source.name, description: source.description,
                                      asset_type: source.asset_type,
                                      environment_id: source.environment && destination_environment_id(source.environment, environments))
        store_version(copy, version, plaintext, actor)
        copy
      ensure
        plaintext&.clear
      end

      # The ciphertext is uploaded now, not after commit, so a failed upload rolls the move back (CYRA-879).
      def store_version(copy, source_version, plaintext, actor)
        attributes = source_version.slice(:original_filename, :content_type, :byte_size).symbolize_keys
        encrypted = Secrets::Assets::Crypto.encrypt(StringIO.new(plaintext),
                                                    aad: Secrets::AssetVersion.new(asset_id: copy.id, number: 1, **attributes).aad)
        blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(encrypted.ciphertext), filename: "#{copy.id}-1.enc",
                                                      content_type: "application/octet-stream", identify: false)
        uploaded_blobs << blob
        copy.versions.create!(number: 1, **attributes, created_by: actor, ciphertext: blob,
                              **encrypted.to_h.slice(:wrapped_key, :key_iv, :key_tag, :payload_iv, :payload_tag, :fingerprint))
        Secrets::Assets::RecordEvent.call(action: "uploaded", asset: copy, actor:, metadata: { version: 1 })
      end

      def uploaded_blobs = (@uploaded_blobs ||= [])

      # The map covers the project's own rows; an environment used only by a shared value or file
      # is looked up by code in the destination (CYRA-879).
      def destination_environment_id(source_environment, environments)
        environments[source_environment.id] ||
          @destination.environments.find_by(code: source_environment.code)&.id ||
          raise(AppError.new("Destination lacks environment #{source_environment.code}", code: "R422-PROJECTMOVE-005"))
      end
    end
  end
end
