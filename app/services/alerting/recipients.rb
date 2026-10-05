# frozen_string_literal: true

module Alerting
  # Chi va avvisato per un progetto: l'INVERSO di Authorization::VisibleScope (project → accounts).
  # Sono gli account che VEDONO il progetto — owner sempre, più accesso personale (project/group) e
  # via team (project/group access). NON i "manager": chi vede. Il filtro per preferenze/canale è a
  # valle (Alerting::Evaluate). god escluso: non è membership operativa.
  # I service account hanno accesso operativo, ma non sono destinatari di notifiche personali.
  class Recipients < ApplicationService
    def self.for(project:) = new(project: project).call

    # Destinatari degli eventi server_* (org-scoped, nessun progetto): owner + membri col permesso
    # org-level servers.view/manage (Resolver, stesso gate della UI). Le org sono piccole:
    # l'iterazione sulle membership è accettabile.
    def self.for_servers(organization:)
      owner_ids = Connections::Membership.where(organization_id: organization.id, role: :owner)
                                         .pluck(:account_id)
      member_ids = Connections::Membership.where(organization_id: organization.id)
                                          .where.not(account_id: owner_ids).pluck(:account_id)
      visible_ids = Accounts::Account.human.where(id: member_ids).select do |account|
        resolver = Authorization::Resolver.new(account: account, organization: organization)
        resolver.can?("servers.view") || resolver.can?("servers.manage")
      end.map(&:id)

      Accounts::Account.human.where(id: owner_ids + visible_ids)
    end

    # Destinatari degli allarmi org-scoped sugli agenti di automazione (lavorazioni bloccate, CYRA-212):
    # owner + membri col permesso org-level agents.view/manage (stesso gate della sezione /member/agents).
    # Gemello di for_servers ma sul permesso dell'automazione, non della flotta di server.
    def self.for_agents(organization:)
      owner_ids = Connections::Membership.where(organization_id: organization.id, role: :owner)
                                         .pluck(:account_id)
      member_ids = Connections::Membership.where(organization_id: organization.id)
                                          .where.not(account_id: owner_ids).pluck(:account_id)
      visible_ids = Accounts::Account.human.where(id: member_ids).select do |account|
        resolver = Authorization::Resolver.new(account: account, organization: organization)
        resolver.can?("agents.view") || resolver.can?("agents.manage")
      end.map(&:id)

      Accounts::Account.human.where(id: owner_ids + visible_ids)
    end

    # Recipients of the "shared value" proposal (CYRA-777): owners + members with the org-level
    # shared_secrets.manage, the same gate as the page where the proposal is accepted. Org-scoped
    # because the value spans several projects: someone who sees one project could not act on it.
    def self.for_shared_secrets(organization:)
      owner_ids = Connections::Membership.where(organization_id: organization.id, role: :owner)
                                         .pluck(:account_id)
      member_ids = Connections::Membership.where(organization_id: organization.id)
                                          .where.not(account_id: owner_ids).pluck(:account_id)
      visible_ids = Accounts::Account.human.where(id: member_ids).select do |account|
        Authorization::Resolver.new(account: account, organization: organization).can?("shared_secrets.manage")
      end.map(&:id)

      Accounts::Account.human.where(id: owner_ids + visible_ids)
    end

    # Destinatari degli eventi secrets_* di progetto (rotazione in scadenza CYRA-138 Fase 4 pezzo A2, e
    # in futuro altri): owner + chi VEDE il progetto e ha il permesso project-scoped secrets.manage.
    # Si parte dai visibili (.for, sopra) invece di riscansionare la membership dell'org come for_servers:
    # un ruolo con secrets.manage SENZA alcun link al progetto (diretto/gruppo/team) non basta — niente
    # leak cross-scope. Resolver#can? fa comunque passare l'owner a prescindere dallo scope.
    def self.for_secrets(project:)
      organization = project.organization
      # `for` è keyword riservata: serve il receiver esplicito per chiamare il metodo di classe qui.
      ids = self.for(project: project).select do |account|
        Authorization::Resolver.new(account: account, organization: organization).can?("secrets.manage", scope: project)
      end.map(&:id)

      Accounts::Account.human.where(id: ids)
    end

    # Destinatari dell'avviso di scadenza di una credenziale di ingest (CYRA-716): owner + chi VEDE il
    # progetto e ha il permesso project-scoped tokens.manage — cioè chi può davvero rimediare (creare
    # la credenziale nuova e sostituirla negli SDK). Gemello esatto di for_secrets, ma sul permesso dei
    # token: mandarlo a chi tiene il vault sarebbe un avviso senza rimedio.
    def self.for_tokens(project:)
      organization = project.organization
      # `for` è keyword riservata: serve il receiver esplicito per chiamare il metodo di classe qui.
      ids = self.for(project: project).select do |account|
        Authorization::Resolver.new(account: account, organization: organization).can?("tokens.manage", scope: project)
      end.map(&:id)

      Accounts::Account.human.where(id: ids)
    end

    def initialize(project:)
      @project = project
      @organization = project.organization
    end

    def call
      Accounts::Account.human.where(id: account_ids)
    end

    private

    def account_ids
      candidate_ids = (owner_ids + direct_project_ids + group_member_ids + team_account_ids).uniq
      # Difesa in profondità (CYRA-241): solo chi è ANCORA membro dell'org riceve avvisi. Se un link
      # scoped (progetto/gruppo/team) sopravvive come residuo alla rimozione dall'org, l'intersezione
      # con le membership vive lo scarta comunque.
      candidate_ids & member_account_ids
    end

    def member_account_ids
      Connections::Membership.where(organization_id: @organization.id).pluck(:account_id)
    end

    def owner_ids
      Connections::Membership.where(organization_id: @organization.id, role: :owner).pluck(:account_id)
    end

    def direct_project_ids
      Connections::ProjectMembership.where(project_id: @project.id).pluck(:account_id)
    end

    def group_member_ids
      return [] if @project.group_id.nil?

      Connections::GroupMembership.where(group_id: @project.group_id).pluck(:account_id)
    end

    def team_account_ids
      ids = team_ids_with_access
      return [] if ids.empty?

      Connections::TeamMembership.where(team_id: ids).pluck(:account_id)
    end

    def team_ids_with_access
      project_teams = Connections::TeamProjectAccess.where(project_id: @project.id).pluck(:team_id)
      group_teams =
        if @project.group_id
          Connections::TeamGroupAccess.where(group_id: @project.group_id).pluck(:team_id)
        else
          []
        end
      (project_teams + group_teams).uniq
    end
  end
end
