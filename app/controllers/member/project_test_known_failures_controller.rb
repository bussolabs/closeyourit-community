# frozen_string_literal: true

module Member
  # Marks a failing test as already known, with its ticket and an expiry, or clears the mark
  # (CYRA-1165). Gate projects.edit, like the retirement of a release. Flat controller.
  class ProjectTestKnownFailuresController < Member::BaseController
    before_action :set_test_case
    before_action -> { require_permission!("projects.edit", scope: @project) }

    def create
      result = ::Projects::KnownFailures::Mark.call(test_case: @test_case, ticket: requested_ticket,
                                                    expires_on: requested_expiry, actor: Current.account,
                                                    true_actor: Current.true_account)
      return back_to_test(alert: result.error.message) unless result.ok?

      back_to_test(notice: t("member.project_tests.known_failure.marked_notice"))
    end

    def destroy
      ::Projects::KnownFailures::Clear.call(test_case: @test_case, actor: Current.account, true_actor: Current.true_account)
      back_to_test(notice: t("member.project_tests.known_failure.cleared_notice"))
    end

    private

    # Anti-BOLA: a project out of sight, or a test of another project, is a 404.
    def set_test_case
      @project = visible.projects.find(params[:project_id])
      @test_case = @project.test_cases.find(params[:test_id])
    end

    # The ticket of this project, written as its code (KEY-12) or as its number alone.
    def requested_ticket
      raw = params[:ticket].to_s.strip
      match = raw.match(/\A(?:(?<key>[A-Za-z][A-Za-z0-9]*)-)?(?<number>\d{1,9})\z/)
      return nil if match.nil?
      return nil if match[:key] && !match[:key].casecmp?(@project.key)

      @project.tickets.find_by(number: match[:number].to_i)
    end

    def requested_expiry
      Date.iso8601(params[:expires_on].to_s)
    rescue Date::Error
      nil
    end

    def back_to_test(**flash)
      redirect_to member_project_test_path(@project, @test_case), **flash
    end
  end
end
