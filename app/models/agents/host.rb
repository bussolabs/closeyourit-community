# frozen_string_literal: true

module Agents
  # Installazione di closeyourit-automator registrata nell'organizzazione. Il fingerprint è
  # l'identità stabile e tenant-scoped; la credenziale dedicata vive separatamente in HostToken.
  class Host < ApplicationRecord
    HOST_STATUSES = %w[idle busy waiting recovery_required].freeze
    SUPPORTED_PLATFORM = "linux"
    # Which engine does the work (CYRA-921). It overrides the phase profile's runtime for this machine.
    WORK_ENGINES = %w[claude codex].freeze
    # Which engine reviews the work before delivery, by name (CYAU-226). The work engine itself means a
    # new session of the same engine, for a machine that has only one. OpenCode only reviews (CYAU-228).
    REVIEW_ONLY_ENGINES = %w[opencode].freeze
    REVIEWERS = (WORK_ENGINES + REVIEW_ONLY_ENGINES).freeze
    # CYAU-235 — the supporter may use any engine that can review.
    SUPPORTERS = REVIEWERS

    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :agent_hosts
    belongs_to :heartbeat_project,
               class_name: "Projects::Project",
               optional: true
    belongs_to :certified_by,
               class_name: "Accounts::Account",
               optional: true
    # B.1 — 1 host ↔ 1 service account (l'agente che opera): identità unica dell'host, usata per lo scope
    # della coda (B.5) e l'attribuzione degli effetti (B.6). optional durante la transizione: gli host
    # storici senza identità restano validi finché un backfill/una ri-registrazione non la popolano.
    belongs_to :service_account,
               class_name: "Accounts::Account",
               optional: true
    # CYAU-227: both null means the machine follows the organization's choice.
    validates :reviewer, inclusion: { in: REVIEWERS }, allow_nil: true
    validates :work_engine, inclusion: { in: WORK_ENGINES }, allow_nil: true
    # CYAU-235: null means the machine follows the organization's supporter engine.
    validates :supporter, inclusion: { in: SUPPORTERS }, allow_nil: true
    before_validation :complete_engine_choice
    validate :opencode_has_a_model

    has_many :host_tokens,
             class_name: "Agents::HostToken",
             foreign_key: :host_id,
             inverse_of: :host,
             dependent: :destroy
    # La cascade vive nelle FK: evita callback che prendano lease prima della riga host.
    has_many :leases,
             class_name: "Agents::Lease",
             foreign_key: :host_id,
             inverse_of: :host,
             dependent: nil
    has_many :lease_tombstones,
             class_name: "Agents::Leases::Tombstone",
             foreign_key: :host_id,
             inverse_of: :host,
             dependent: nil
    has_many :limit_reservations,
             class_name: "Agents::LimitReservation",
             foreign_key: :host_id,
             inverse_of: :host,
             dependent: :nullify
    has_many :ticket_queue_deferrals,
             class_name: "Agents::TicketQueueDeferral",
             foreign_key: :host_id,
             inverse_of: :host,
             dependent: :nullify

    normalizes :fingerprint, with: ->(value) { value.to_s.strip.downcase }
    normalizes :hostname, :platform, :arch, with: ->(value) { value.to_s.strip }
    normalizes :automator_version, with: ->(value) { value.to_s.strip.presence }

    validates :fingerprint, :hostname, :platform, :arch, presence: true
    validates :running, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :slots, numericality: { only_integer: true, greater_than: 0 }
    validates :host_status, inclusion: { in: HOST_STATUSES }
    validates :heartbeat_expected_interval_minutes, numericality: { only_integer: true, greater_than: 0 }
    validates :heartbeat_grace_minutes, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :telemetry_snapshots_are_arrays
    validate :heartbeat_project_belongs_to_organization
    validate :service_account_is_service_and_member

    scope :active, -> { where(revoked_at: nil) }

    def revoked? = revoked_at.present?

    def follows_organization? = work_engine.nil?
    def effective_work_engine = work_engine || organization_choice.work_engine
    def effective_reviewer = reviewer || organization_choice.reviewer
    def effective_supporter = supporter || organization_choice.supporter
    # CYAU-228 — the OpenRouter model OpenCode reviews with; Claude and Codex use the model the automator pins.
    def effective_reviewer_model = effective_reviewer == "opencode" ? organization_choice.opencode_model : nil
    def supported_platform? = platform == SUPPORTED_PLATFORM

    # Certificazione esplicita: un host resta ineleggibile finché un umano non lo abilita. Il gate
    # vive in Agents::Hosts::Eligibility, non nel model, per non intrecciarsi con revoca/heartbeat.
    def certified? = certified_at.present?

    # La connettività è server-side: il client dichiara solo l'attività. Lo stesso intervallo+grace del
    # monitor cron rende offline il singolo host anche quando più macchine condividono slug e token ingest.
    def heartbeat_online?(now: Time.current)
      return false if last_heartbeat_at.nil?

      last_heartbeat_at >= now - (heartbeat_expected_interval_minutes + heartbeat_grace_minutes).minutes
    end

    # CYRA-450 — l'host è "fermo" (stale): ha superato il suo intervallo atteso (offline) e per di più tace
    # da oltre la soglia di allarme. La congiunzione con l'offline è deliberata: la soglia è un pavimento di
    # grazia (un riavvio breve rientra prima di allarmare), mai un secondo, più corto, timeout che
    # contraddirebbe il badge — un host ancora online per il suo intervallo NON è fermo. Un host mai battuto
    # si ancora a created_at: appena registrato non è fermo, dimenticato acceso da giorni sì. stale ⟹ offline.
    def heartbeat_stale?(now: Time.current)
      return false if revoked? || heartbeat_online?(now:)

      reference = last_heartbeat_at || created_at
      reference.present? && reference <= now - Agents::Constants::HOST_STALE_AFTER
    end

    # CYRA-520 — da QUANDO è ferma: l'istante in cui ha superato la soglia, non l'ultimo battito.
    # È il punto fisso da cui si contano i promemoria che si diradano (Agents::Hosts::DetectStale):
    # partire dall'ultimo battito darebbe una scaletta diversa per ogni host, a seconda della soglia.
    def stale_since(now: Time.current)
      return nil unless heartbeat_stale?(now:)

      (last_heartbeat_at || created_at) + Agents::Constants::HOST_STALE_AFTER
    end

    # Per la dashboard un host idle ma vivo è "online"; gli altri stati operativi restano distinti.
    def activity_status(now: Time.current)
      return "offline" unless heartbeat_online?(now:)
      return "online" if host_status == "idle"

      host_status
    end

    # Se il battito scade non arriverà uno snapshot capace di marcare le run: per la vista ogni attività
    # ancora dichiarata da quell'host diventa quindi stalled, senza alterare lo snapshot storico salvato.
    def observable_active_runs(now: Time.current)
      structured_runs = active_runs.select { |run| run.is_a?(Hash) }
      return structured_runs if heartbeat_online?(now:)

      structured_runs.map { |run| run.merge("stalled" => true) }
    end

    private

    def organization_choice = AutomatorSetting.for(organization)

    # CYAU-227: a machine's own choice is always complete, so setting one engine on a machine that follows
    # the organization starts from the organization's other engine.
    # CYAU-226: moving the work to the engine that was reviewing would silently make the review weaker,
    # so the engine that was working becomes the reviewer.
    def complete_engine_choice
      return if work_engine.nil? && reviewer.nil?
      return keep_following if following_in_database? && choice_matches_organization?

      reviewer_chosen = will_save_change_to_reviewer?
      previous_worker = work_engine_in_database || organization_choice.work_engine
      self.work_engine ||= organization_choice.work_engine
      self.reviewer ||= organization_choice.reviewer
      return if reviewer_chosen || reviewer != work_engine || previous_worker == work_engine

      self.reviewer = previous_worker
    end

    def following_in_database? = work_engine_in_database.nil? && reviewer_in_database.nil?

    # Each engine form of a following machine sets one engine, pre-filled with the choice in force: saving it
    # unchanged is not a choice, so the machine keeps following. Setting both engines is always a choice.
    def choice_matches_organization?
      return work_engine == organization_choice.work_engine if reviewer.nil?

      work_engine.nil? && reviewer == organization_choice.reviewer
    end

    def keep_following
      self.work_engine = nil
      self.reviewer = nil
    end

    # CYAU-228 — OpenCode reviews with the organization's OpenRouter model: without one the machine would
    # never take work and no page would say why.
    def opencode_has_a_model
      return unless reviewer == "opencode" && will_save_change_to_reviewer?
      return if organization_choice.opencode_model.present?

      errors.add(:reviewer, :opencode_model_missing)
    end

    def telemetry_snapshots_are_arrays
      %i[runtimes repositories active_runs last_stops].each do |attribute|
        errors.add(attribute, :invalid) unless public_send(attribute).is_a?(Array)
      end
      errors.add(:active_runs, :invalid) if active_runs.is_a?(Array) && active_runs.any? { |run| !run.is_a?(Hash) }
    end

    def heartbeat_project_belongs_to_organization
      return if heartbeat_project.nil? || heartbeat_project.organization_id == organization_id

      errors.add(:heartbeat_project, :invalid)
    end

    # L'identità dell'host deve essere un service account della stessa organizzazione (specchia
    # Agent#command_and_service_account_belong_to_organization).
    def service_account_is_service_and_member
      return if service_account.nil?

      errors.add(:service_account, :invalid) unless service_account.service?
      return if service_account.memberships.exists?(organization_id: organization_id)

      errors.add(:service_account, :not_member)
    end
  end
end
