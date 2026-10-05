# frozen_string_literal: true

module Authorization
  # Crea i ruoli default EDITABILI di un'org (record normali, non costanti in codice). Le chiavi sono
  # impostate SOLO alla prima creazione (previously_new_record?), così ri-eseguire NON sovrascrive le
  # personalizzazioni dell'owner. Idempotente. Usato al provisioning dell'org, nel seed e nel backfill.
  class InstallDefaultRoles < ApplicationService
    DEFAULTS = {
      "Viewer" => [],
      "Triager" => %w[errors.triage errors.promote errors.assign vulnerabilities.triage seo.triage],
      "Maintainer" => %w[
        tickets.edit tickets.assign tickets.delete tickets.comment.delete_any
        tickets.attachments.manage tokens.manage secrets.read secrets.manage secret_files.manage uptime.manage uptime_groups.manage
        documents.manage ideas.edit ideas.delete ideas.convert ideas.comment.delete_any
        knowledge.edit knowledge.delete datasets.manage datasets.train agents.manage
        errors.destroy errors.grouping.manage artifacts.manage product_features.manage seo.manage analytics.share.manage
        helpdesk.manage
      ],
      "Administrator" => :all
    }.freeze

    def initialize(organization:, created_by: nil)
      @organization = organization
      @created_by = created_by
    end

    def call
      # Preload dei ruoli già presenti in UNA query (prima un find_or_create_by! per nome = N SELECT a
      # fingerprint identica → prosopite N+1). I mancanti si creano; i permessi si impostano SOLO sui
      # nuovi (idempotenza: non sovrascrive le personalizzazioni dell'owner).
      existing = @organization.roles.where(name: DEFAULTS.keys).index_by(&:name)
      roles = {}
      DEFAULTS.each do |name, keys|
        role = existing[name]
        if role.nil?
          role = @organization.roles.create!(name: name) { |r| r.created_by = @created_by }
          desired = keys == :all ? Authorization::Catalog.keys : keys
          # known_current: [] → ruolo appena creato, nessun permesso da confrontare (salta la pluck per-ruolo).
          # enforce_grant: false → SEED di sistema: salta il subset-check anti-escalation (GrantGuard, CYRA-156)
          # ma MANTIENE l'actor (@created_by) per l'audit `permission_granted`. Senza il bypass il guard
          # bloccherebbe i ruoli default (chiavi che il nuovo owner non possiede ancora) + N+1 nel loop → org nuova rotta.
          Authorization::SetRolePermissions.call(role: role, permission_keys: desired, actor: @created_by,
                                                 known_current: [], enforce_grant: false)
        end
        roles[name] = role
      end
      Result.ok(roles)
    end
  end
end
