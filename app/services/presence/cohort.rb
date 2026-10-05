# frozen_string_literal: true

module Presence
  # Filtro di visibilità della presenza: dato l'insieme degli account ONLINE in un'org, decide
  # cosa vede ciascun viewer. Un utente non deve vedere l'intera org, ma solo gli online con cui
  # condivide un contesto concreto (progetto / gruppo / team).
  #
  #  - viewer UNSCOPED (owner o god) → vede TUTTI gli online (gestisce tutto).
  #  - viewer SCOPED (admin/member/customer) → vede: sé stesso + gli owner online (staff sempre
  #    visibile) + gli online con footprint intersecante (condividono progetto/gruppo/team).
  #
  # `footprint(a)` (concreto, calcolato SOLO per gli online → insieme piccolo; ~7 query bulk,
  # indipendenti dal numero di online):
  #  - projects: ProjectMembership diretti + TeamProjectAccess dei team di `a` + progetti dei
  #              gruppi in groups(a) (espansione gruppo→progetti);
  #  - groups:   GroupMembership diretti + TeamGroupAccess dei team di `a`;
  #  - teams:    TeamMembership di `a`.
  # `shares?` = intersezione non vuota su projects | groups | teams. (I gruppi con progetti sono
  # già coperti dai projects espansi; il confronto groups serve ai gruppi vuoti; teams copre lo
  # "stesso team" senza accesso a risorse.) Footprint SEMPRE concreto: nessuno shortcut
  # "owner vede tutto" lato subject — gli owner sono già sempre visibili via `owner_ids`.
  #
  # È l'inverso, ristretto agli online, di Authorization::VisibleScope (account → risorse):
  # qui componiamo le stesse relazioni di link (Connections::*Membership / Team*Access) per
  # ricavare, di ogni online, l'impronta dei contesti a cui è collegato.
  #
  # Tenant: `online` è già ri-scopato sui membri reali dell'org (Realtime::Presence.online) e
  # ogni query filtra su quegli id → nessun leak cross-organizzazione.
  class Cohort
    # Who is online right now, as this viewer may see them: the page and the channel snapshot agree.
    def self.visible_online(organization, viewer)
      new(organization:, online: Realtime::Presence.online(organization)).visible_for(viewer)
    end

    def initialize(organization:, online:)
      @organization = organization
      @online = online.to_a
    end

    # Sottoinsieme di `online` visibile a `viewer` (ordine di `online` preservato).
    def visible_for(viewer)
      return @online if unscoped?(viewer)

      viewer_footprint = footprint(viewer.id)
      @online.select do |subject|
        subject.id == viewer.id ||
          owner_ids.include?(subject.id) ||
          shares?(viewer_footprint, footprint(subject.id))
      end
    end

    private

    def unscoped?(account)
      Authorization::VisibleScope.unscoped?(account: account, organization: @organization)
    end

    def shares?(a, b)
      a[:projects].intersect?(b[:projects]) ||
        a[:groups].intersect?(b[:groups]) ||
        a[:teams].intersect?(b[:teams])
    end

    # { account_id => { projects: Set, groups: Set, teams: Set } } per i soli online.
    def footprints
      @footprints ||= build_footprints
    end

    def footprint(account_id)
      footprints[account_id] || { projects: Set.new, groups: Set.new, teams: Set.new }
    end

    def online_ids
      @online_ids ||= @online.map(&:id)
    end

    # Owner ONLINE dell'org: sempre visibili a chiunque (staff dell'org).
    def owner_ids
      @owner_ids ||= Connections::Membership
                     .where(organization_id: @organization.id, role: :owner, account_id: online_ids)
                     .pluck(:account_id).to_set
    end

    def build_footprints
      return {} if online_ids.empty?

      account_teams = group_pairs(Connections::TeamMembership.where(account_id: online_ids).pluck(:account_id, :team_id))
      all_team_ids  = account_teams.values.flat_map(&:to_a).uniq

      direct_projects = group_pairs(Connections::ProjectMembership.where(account_id: online_ids).pluck(:account_id, :project_id))
      direct_groups   = group_pairs(Connections::GroupMembership.where(account_id: online_ids).pluck(:account_id, :group_id))

      team_projects = group_pairs(Connections::TeamProjectAccess.where(team_id: all_team_ids).pluck(:team_id, :project_id))
      team_groups   = group_pairs(Connections::TeamGroupAccess.where(team_id: all_team_ids).pluck(:team_id, :group_id))

      all_group_ids  = (direct_groups.values + team_groups.values).flat_map(&:to_a).uniq
      group_projects = group_pairs(Projects::Project.where(group_id: all_group_ids).pluck(:group_id, :id))

      online_ids.index_with do |account_id|
        teams  = account_teams[account_id] || Set.new
        groups = (direct_groups[account_id] || Set.new) |
                 teams.flat_map { |team_id| (team_groups[team_id] || Set.new).to_a }
        projects = (direct_projects[account_id] || Set.new) |
                   teams.flat_map { |team_id| (team_projects[team_id] || Set.new).to_a } |
                   groups.flat_map { |group_id| (group_projects[group_id] || Set.new).to_a }
        { projects: projects, groups: groups, teams: teams }
      end
    end

    # [[k, v], ...] → { k => Set[v, ...] }
    def group_pairs(pairs)
      pairs.each_with_object({}) { |(key, value), hash| (hash[key] ||= Set.new) << value }
    end
  end
end
