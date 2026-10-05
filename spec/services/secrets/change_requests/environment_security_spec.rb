# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Change request environment authorization", type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:actor) { create(:account) }
  let(:requester) { create(:account) }
  let!(:membership) { create(:membership, account: actor, organization:, role: :owner, secret_environment_codes: [ "staging" ]) }
  let(:environment) { create(:environment, organization:, code: "production").tap { |env| project.environments << env } }
  let!(:change_request) { create(:secret_change_request, project:, organization:, environment:, requested_by: requester) }

  [ Secrets::ChangeRequests::Approve, Secrets::ChangeRequests::Reject ].each do |service|
    context service.name do
      def decide(service)
        args = { change_request:, actor: }
        args[:reason] = "Not approved" if service == Secrets::ChangeRequests::Reject
        service.call(**args)
      end

      it "denies a production decision before reading or changing the secret" do
        expect(change_request).not_to receive(:value)
        expect { expect(decide(service).error.code).to eq("R403-CHANGEREQUEST-004") }
          .not_to have_enqueued_job(Secrets::Notifications::ChangeRequestNotifyJob)
        expect(change_request.reload).to be_pending
        expect(project.secret_variables).to be_empty
      end

      it "applies the project override even when the organization allows every environment" do
        membership.update!(secret_environment_codes: [])
        create(:account_secret_access, account: actor, project:, organization:, environment_codes: [ "staging" ])

        expect(decide(service)).to be_err
        expect(change_request.reload).to be_pending
      end

      it "allows an explicitly authorized project environment" do
        create(:account_secret_access, account: actor, project:, organization:, environment_codes: [ "production" ])

        expect(decide(service)).to be_ok
        expect(change_request.reload).not_to be_pending
      end
    end
  end

  it "hides requests and decision controls for an unauthorized environment" do
    report = Secrets::ChangeRequests::Pending.new(account: actor, projects: [ project ])

    expect(report.requests).to be_empty
    expect(report.can_decide?(change_request)).to be(false)
    expect(report.decidable_count).to eq(0)
  end

  it "keeps the requester's own request visible and cancellable after access is restricted" do
    own_request = create(:secret_change_request, project:, organization:, environment:, requested_by: actor, name: "OWN_TOKEN")
    report = Secrets::ChangeRequests::Pending.new(account: actor, projects: [ project ])

    expect(report.requests).to contain_exactly(own_request)
    expect(report.can_cancel?(own_request)).to be(true)
    expect(report.can_decide?(change_request)).to be(false)
  end
end
