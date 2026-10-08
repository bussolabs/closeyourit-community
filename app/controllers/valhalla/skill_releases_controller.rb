# frozen_string_literal: true

module Valhalla
  # Versions of the public cyi skills package (CYRA-912): see them, withdraw a faulty one, read
  # GitHub now instead of waiting for the hourly job. God only (BaseController).
  class SkillReleasesController < BaseController
    # Versions are digits and dots (SkillRelease::VERSION_FORMAT), so the integer array orders them
    # as versions in SQL: 1.10.0 comes after 1.9.0.
    SORT_COLUMNS = {
      "version" => "string_to_array(agents_skill_releases.version, '.')::int[]",
      "published_at" => :published_at,
      "state" => :withdrawn_at
    }.freeze
    STATES = %w[available withdrawn].freeze

    def index
      scope = Agents::SkillRelease.all
      @total = scope.count
      @withdrawn_total = scope.where.not(withdrawn_at: nil).count
      scope = scope.where("agents_skill_releases.version ILIKE ?", "%#{Agents::SkillRelease.sanitize_sql_like(search_q)}%") if search_q.present?
      scope = filter_state(scope)
      scope = sorted(scope.order(published_at: :desc, id: :desc), columns: SORT_COLUMNS)
      @pagination = paginate(scope)
      @releases = @pagination.records
    end

    def sync
      result = Agents::SkillReleases::Sync.call
      if result.ok?
        added = result.value[:added]
        notice = added.any? ? t(".added", versions: added.join(", ")) : t(".nothing_new")
        redirect_to valhalla_skill_releases_path, notice:
      else
        redirect_to valhalla_skill_releases_path, alert: t(".failed")
      end
    end

    def withdraw = change(withdrawn: true)

    def restore = change(withdrawn: false)

    private

    def change(withdrawn:)
      release = Agents::SkillRelease.find(params[:id])
      result = Agents::SkillReleases::Withdraw.call(release:, actor: Current.account, withdrawn:)
      if result.ok?
        redirect_to valhalla_skill_releases_path, notice: t(withdrawn ? ".withdrawn" : ".restored", version: release.version)
      else
        redirect_to valhalla_skill_releases_path, alert: t("valhalla.skill_releases.change_failed", version: release.version)
      end
    end

    def filter_state(scope)
      states = filter_ids(:state) & STATES
      return scope if states.empty? || states.size == STATES.size

      states.first == "withdrawn" ? scope.where.not(withdrawn_at: nil) : scope.where(withdrawn_at: nil)
    end
  end
end
