# frozen_string_literal: true

module Valhalla
  class OrganizationsController < BaseController
    # Whitelist ordinamento (contratto Sortable#sorted). members/projects = subquery COUNT;
    # owner via join sulla owner_membership (has_one through, role: :owner nella JOIN ON).
    SORT_COLUMNS = {
      "organization" => "LOWER(organizations.name)",
      "owner" => { expr: "LOWER(accounts.email)", joins: :owner },
      "members" => "(SELECT COUNT(*) FROM connections_memberships m WHERE m.organization_id = organizations.id)",
      "projects" => "(SELECT COUNT(*) FROM projects p WHERE p.organization_id = organizations.id)",
      "status" => :suspended_at
    }.freeze

    before_action :set_organization, only: %i[show edit update destroy suspend]

    # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
    remembers_filters :status, :q, :sort, only: :index

    def index
      scope = Organizations::Organization.includes(:owner, :memberships, :projects).order(created_at: :desc)
      scope = scope.where("name ILIKE :q OR slug ILIKE :q", q: "%#{search_q}%") if search_q.present?
      statuses = filter_ids(:status)
      scope = scope.where(suspended_at: nil) if statuses == [ "active" ]
      scope = scope.where.not(suspended_at: nil) if statuses == [ "suspended" ]
      @pagination = paginate(sorted(scope, columns: SORT_COLUMNS))
      @organizations = @pagination.records
    end

    # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
    remembers_filters :q, :sort, only: :show

    # CYRA-924 — every member column sorts (C9).
    MEMBER_SORT_COLUMNS = {
      "account" => { expr: "LOWER(accounts.name)", joins: :account },
      "email" => { expr: "LOWER(accounts.email)", joins: :account },
      "role" => :role
    }.freeze

    def show
      scope = @organization.memberships.includes(:account)
      if search_q.present?
        scope = scope.joins(:account)
                     .where("accounts.name ILIKE :q OR accounts.email ILIKE :q", q: "%#{search_q}%")
      end
      @members_pagination = paginate(sorted(scope, columns: MEMBER_SORT_COLUMNS))
      @members = @members_pagination.records
    end

    def new
      @errors = {}
    end

    def create
      result = Organizations::Provision.call(name: params[:name], owner_email: params[:owner_email])

      if result.ok?
        broadcast_prepend(result.value)
        redirect_to valhalla_organization_path(result.value), notice: t("valhalla.organizations.created")
      else
        @errors = result.error.details || {}
        flash.now[:alert] = t("valhalla.organizations.failed")
        render :new, status: :unprocessable_content
      end
    end

    def edit
      @errors = {}
    end

    def update
      if @organization.update(org_params)
        broadcast_replace(@organization)
        redirect_to valhalla_organization_path(@organization), notice: t("valhalla.organizations.updated")
      else
        @errors = @organization.errors.to_hash
        flash.now[:alert] = t("valhalla.organizations.failed")
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      @organization.destroy
      broadcast_remove(@organization)
      redirect_to valhalla_organizations_path, notice: t("valhalla.organizations.deleted")
    end

    def suspend
      if @organization.suspended?
        @organization.update!(suspended_at: nil)
        notice = t("valhalla.organizations.unsuspended")
      else
        @organization.update!(suspended_at: Time.current)
        disconnect_live_channels(@organization)
        notice = t("valhalla.organizations.suspended_done")
      end
      broadcast_replace(@organization)
      redirect_to valhalla_organizations_path, notice: notice
    end

    private

    # CYRA-722 — la sospensione chiude le porte a chi bussa, ma chi è già dentro non bussa più: una
    # pagina aperta tiene il suo canale in tempo reale e continua a ricevere finché non ricarica.
    # `reconnect: false` perché il client non deve riprovare: la porta è chiusa apposta, e alla
    # riapertura la connessione verrebbe comunque rifiutata (ApplicationCable::Connection).
    # Non deve mai far fallire la sospensione, che è la cosa importante: un canale che non si riesce
    # a chiudere è un fastidio, un'organizzazione che resta attiva è il difetto da cui si è partiti.
    def disconnect_live_channels(organization)
      ActionCable.server.remote_connections.where(current_organization: organization)
                 .disconnect(reconnect: false)
    rescue StandardError => e
      Rails.logger.warn("Disconnessione canali org sospesa — #{e.class}: #{e.message}")
    end

    def set_organization
      @organization = Organizations::Organization.find(params[:id])
    end

    def org_params
      params.permit(:name, :slug)
    end

    def broadcast_prepend(organization)
      Turbo::StreamsChannel.broadcast_prepend_to(
        "valhalla_organizations", target: "valhalla_organizations",
        partial: "valhalla/organizations/organization", locals: { organization: organization }
      )
    end

    def broadcast_replace(organization)
      Turbo::StreamsChannel.broadcast_replace_to(
        "valhalla_organizations", target: ActionView::RecordIdentifier.dom_id(organization),
        partial: "valhalla/organizations/organization", locals: { organization: organization }
      )
    end

    def broadcast_remove(organization)
      Turbo::StreamsChannel.broadcast_remove_to(
        "valhalla_organizations", target: ActionView::RecordIdentifier.dom_id(organization)
      )
    end
  end
end
