# frozen_string_literal: true

module Secrets
  # Chi può LEGGERE in chiaro i secret — risolto dalle membership reali, con nome e ruolo (CYRA-422).
  # Alimenta il pannello «Chi può vedere questi segreti» delle pagine vault: una rassicurazione onesta
  # su chi altro vedrà un segreto. Il risultato combacia col gate applicato davvero: per il progetto
  # `secrets.read` e basta (CYRA-721 — chi ha solo `secrets.manage` cambia i valori ma non li vede, e
  # includerlo qui prometterebbe a chi legge una platea più larga di quella vera); per i file di progetto
  # `secret_files.read/manage`; per l'organizzazione `shared_secrets.manage`.
  #
  # Perché NON Authorization::Resolver in loop: il resolver ha cache PER-ISTANZA (una per account); una
  # istanza per membro — come Alerting::Recipients.for_secrets, che però gira in un job — rifà tutte le
  # query e nel render della pagina scatta il guard N+1 (Prosopite, gate CI bloccante). Qui la stessa
  # gerarchia del resolver (owner → override personale allow/deny che batte i ruoli → ruoli diretti/team
  # collegati allo scope) è valutata in BATCH: poche query fisse indipendenti dal numero di membri, poi
  # la decisione per-chiave in memoria. god è escluso (non è membership operativa, come Recipients). La
  # parità con il resolver è ancorata da spec/services/secrets/readers_spec.rb.
  class Readers < ApplicationService
    # role = enum Connections::Membership (:owner/:admin/:member/:customer) del lettore nell'org.
    Reader = Data.define(:account, :role)

    ROLE_ORDER = %i[owner admin member customer].freeze

    # Lettori dei secret di PROGETTO (variabili d'ambiente): gate secrets.read.
    def self.for_project(project, keys: %w[secrets.read])
      new(organization: project.organization, project: project, keys: keys).call
    end

    # Lettori dei FILE segreti di progetto: gate secret_files.read OR secret_files.manage.
    def self.for_project_files(project)
      for_project(project, keys: %w[secret_files.read secret_files.manage])
    end

    # Lettori dei secret dell'ORGANIZZAZIONE (shared): gate org-level shared_secrets.manage.
    def self.for_organization(organization, keys: %w[shared_secrets.manage])
      new(organization: organization, project: nil, keys: keys).call
    end

    def initialize(organization:, project:, keys:)
      @organization = organization
      @project = project
      @keys = keys
    end

    def call
      granted = reader_account_ids
      memberships
        .select { |m| granted.include?(m.account_id) }
        .map { |m| Reader.new(account: m.account, role: m.role.to_sym) }
        .sort_by { |r| [ ROLE_ORDER.index(r.role) || ROLE_ORDER.size, r.account.name.to_s.downcase ] }
    end

    private

    def memberships
      @memberships ||= @organization.memberships.includes(:account).to_a
    end

    def owner_ids
      @owner_ids ||= memberships.select { |m| m.role.to_s == "owner" }.map(&:account_id).to_set
    end

    def candidate_ids
      @candidate_ids ||= memberships.map(&:account_id).to_set - owner_ids
    end

    def reader_account_ids
      granted = owner_ids.dup
      candidate_ids.each do |account_id|
        granted << account_id if @keys.any? { |key| grants?(account_id, key) }
      end
      granted
    end

    # Decisione per singola chiave, in memoria: override personale batte i ruoli; un allow richiede lo
    # scope visibile (per i secret di progetto); i ruoli sono già ristretti allo scope per costruzione.
    def grants?(account_id, key)
      effect = overrides.dig(account_id, key)
      return scope_visible?(account_id) if effect == "allow"
      return false if effect == "deny"

      role_keys_for(account_id).include?(key)
    end

    # { account_id => { permission_key => "allow"/"deny" } } — accessor .effect (mai pluck sull'enum).
    def overrides
      @overrides ||= Authorization::AccountPermission
        .where(organization_id: @organization.id, account_id: candidate_ids.to_a, permission_key: @keys)
        .each_with_object(Hash.new { |h, k| h[k] = {} }) { |ap, map| map[ap.account_id][ap.permission_key] = ap.effect }
    end

    def role_keys_for(account_id)
      role_grant_map[account_id] || Set.new
    end

    # { account_id => Set(keys) } concesse da un ruolo (diretto o di team) VALIDO per lo scope: per un
    # progetto il ruolo diretto richiede il link personale allo scope, il ruolo di team richiede che il
    # team stesso sia collegato allo scope (nessun leak cross-soggetto, come Authorization::Resolver).
    def role_grant_map
      @role_grant_map ||= build_role_grant_map
    end

    def build_role_grant_map
      map = Hash.new { |h, k| h[k] = Set.new }
      keys_by_role = keys_by_role_id
      return map if keys_by_role.empty?

      apply_direct_role_grants(map, keys_by_role)
      apply_team_role_grants(map, keys_by_role)
      map
    end

    # { role_id => Set(keys) } per i soli ruoli che concedono almeno una delle chiavi richieste.
    def keys_by_role_id
      Authorization::RolePermission.where(permission_key: @keys)
        .pluck(:role_id, :permission_key)
        .each_with_object(Hash.new { |h, k| h[k] = Set.new }) { |(role_id, key), map| map[role_id] << key }
    end

    def apply_direct_role_grants(map, keys_by_role)
      Authorization::AccountRole
        .where(organization_id: @organization.id, role_id: keys_by_role.keys, account_id: candidate_ids.to_a)
        .pluck(:account_id, :role_id).each do |account_id, role_id|
          next unless scope_linked_directly?(account_id)

          map[account_id].merge(keys_by_role[role_id])
        end
    end

    def apply_team_role_grants(map, keys_by_role)
      keys_by_team = Authorization::TeamRole.where(role_id: keys_by_role.keys)
        .pluck(:team_id, :role_id)
        .each_with_object(Hash.new { |h, k| h[k] = Set.new }) { |(team_id, role_id), acc| acc[team_id].merge(keys_by_role[role_id]) }
      team_ids = @project ? (keys_by_team.keys & scope_linked_team_ids.to_a) : keys_by_team.keys
      return if team_ids.empty?

      Connections::TeamMembership.where(team_id: team_ids, account_id: candidate_ids.to_a)
        .pluck(:team_id, :account_id).each { |team_id, account_id| map[account_id].merge(keys_by_team[team_id]) }
    end

    # --- Visibilità dello scope (solo per i secret di progetto) --------------------------------------

    def scope_visible?(account_id)
      return true if @project.nil?

      visible_ids.include?(account_id)
    end

    def scope_linked_directly?(account_id)
      return true if @project.nil?

      directly_linked_ids.include?(account_id)
    end

    def visible_ids
      @visible_ids ||= directly_linked_ids | team_linked_member_ids
    end

    # Link PERSONALE dell'account allo scope: membership diretta al progetto o al suo gruppo.
    def directly_linked_ids
      @directly_linked_ids ||= begin
        ids = Connections::ProjectMembership.where(project_id: @project.id, account_id: candidate_ids.to_a).pluck(:account_id).to_set
        if @project.group_id
          ids.merge(Connections::GroupMembership.where(group_id: @project.group_id, account_id: candidate_ids.to_a).pluck(:account_id))
        end
        ids
      end
    end

    def scope_linked_team_ids
      @scope_linked_team_ids ||= begin
        ids = Connections::TeamProjectAccess.where(project_id: @project.id).pluck(:team_id)
        ids += Connections::TeamGroupAccess.where(group_id: @project.group_id).pluck(:team_id) if @project.group_id
        ids.uniq
      end
    end

    def team_linked_member_ids
      return Set.new if scope_linked_team_ids.empty?

      Connections::TeamMembership.where(team_id: scope_linked_team_ids, account_id: candidate_ids.to_a).pluck(:account_id).to_set
    end
  end
end
