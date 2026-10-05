# frozen_string_literal: true

module Agents
  module SkillBundles
    # Pinna (upsert) il bundle skill singleton dell'organizzazione: repo/ref/version/digest. Gemello di
    # SCRITTURA di Hosts::SkillManifest (lettura). Idempotente: aggiorna il record esistente o lo crea, così
    # resta sempre un solo bundle per org. Origine tipica: la CI di `closeyourit-skills` al tag di release
    # (via Cli::V1, gate agents.manage). Additivo: non tocca Command/Instruction.
    #
    # MONOTONICO per versione (CYAU-68): un rerun o un job concorrente di un tag PIÙ VECCHIO non deve far
    # regredire il pin, altrimenti gli host clonerebbero ed eseguirebbero un bundle vecchio. Di default
    # rifiuta (R409-AGENT-002) un pin la cui `version` è DIMOSTRABILMENTE più vecchia di quella già pinnata.
    # `force: true` bypassa il check per un rollback INTENZIONALE (override umano via Cli::V1, gate
    # agents.manage): la CI del repo skills non passa force → resta monotonica.
    class Pin < ApplicationService
      def initialize(organization:, repo:, ref:, version:, digest:, force: false)
        @organization = organization
        @repo = repo
        @ref = ref
        @version = version
        @digest = digest
        # `force` arriva booleano dal service o come stringa "true"/"false" dal param HTTP del controller:
        # normalizza a un booleano vero così `"false"` (stringa truthy in Ruby) non bypassa per errore.
        @force = ActiveModel::Type::Boolean.new.cast(force)
      end

      def call
        upsert_singleton
      rescue ActiveRecord::RecordInvalid => e
        Result.err(AppError.new(e.message, code: "R422-AGENT-006", details: e.record.errors.to_hash))
      end

      private

      # Upsert idempotente del singleton per-org. Se due richieste pinnano il PRIMO bundle in parallelo
      # (CI + override manuale) entrambe vedono skill_bundle nil e inseriscono: l'unique index su
      # organization_id ne rifiuta una con RecordNotUnique. Non è un 500: ricarica il vincitore e
      # riapplica l'upsert sulla riga esistente (ora UPDATE, niente conflitto). Un solo giro basta —
      # dopo il reload il record esiste, quindi non può più esserci una violazione dell'unique index.
      def upsert_singleton
        existing = @organization.skill_bundle
        return apply_locked(existing) if existing

        # Primo pin: nessuna riga da lockare. L'unique index su organization_id serializza gli INSERT
        # concorrenti; il perdente rientra dal rescue e riapplica sulla riga del vincitore, sotto lock.
        bundle = @organization.build_skill_bundle
        bundle.assign_attributes(repo: @repo, ref: @ref, version: @version, digest: @digest)
        bundle.save!
        Result.ok(bundle)
      rescue ActiveRecord::RecordNotUnique
        winner = @organization.reload.skill_bundle
        raise unless winner

        apply_locked(winner)
      end

      # Applica il pin sulla riga ESISTENTE sotto lock di riga (SELECT ... FOR UPDATE). Serializza gli
      # update concorrenti sullo stesso singleton: il guard anti-downgrade e lo UPDATE girano sul valore
      # realmente committato (with_lock ricarica il record), non su una lettura ormai sporca. Senza il
      # lock, due pin che superano entrambi il guard contro il vecchio valore si sovrascriverebbero
      # last-write-wins, lasciando vincere una versione inferiore — violando la monotonicità (CYAU-68).
      def apply_locked(record)
        record.with_lock do
          guard = downgrade_guard(record)
          return guard if guard

          record.update!(repo: @repo, ref: @ref, version: @version, digest: @digest)
        end
        Result.ok(record)
      end

      # Rifiuta (R409) solo quando, con `force` disattivo e un bundle già pinnato, la versione in arrivo è
      # DIMOSTRABILMENTE più vecchia di quella corrente. Nessun pin, force attivo o versioni non
      # confrontabili → nessun blocco (fail-open).
      def downgrade_guard(current)
        return nil if @force
        return nil if current.nil?
        return nil unless older?(@version, current.version)

        Result.err(AppError.new(
          "Downgrade dello skill bundle rifiutato: la versione #{@version} è più vecchia del bundle pinnato " \
          "#{current.version}. Usa force per un rollback intenzionale.",
          code: "R409-AGENT-002", status: :conflict
        ))
      end

      # true SOLO se possiamo dimostrare (semver) che `candidate` è più vecchia di `pinned`. Versione
      # non-semver o vuota su un lato → confronto impossibile → false (fail-OPEN: non blocchiamo un pin
      # per un confronto che non possiamo fare; il vuoto lo intercetta comunque la presence del model).
      def older?(candidate, pinned)
        candidate_version = semver(candidate)
        pinned_version = semver(pinned)
        return false if candidate_version.nil? || pinned_version.nil?

        candidate_version < pinned_version
      end

      # `Gem::Version` se il valore è semver-parsabile, altrimenti nil. Il vuoto (gestito dalla presence del
      # model) è nil silenzioso; un valore PRESENTE ma non-semver viene annotato (fail-open tracciato).
      def semver(value)
        return nil if value.blank?
        unless Gem::Version.correct?(value)
          Rails.logger.warn(
            "[Agents::SkillBundles::Pin] versione non-semver #{value.inspect}: " \
            "check anti-downgrade saltato (fail-open)"
          )
          return nil
        end

        Gem::Version.new(value)
      end
    end
  end
end
