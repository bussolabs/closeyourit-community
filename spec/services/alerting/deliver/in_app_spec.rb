# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::Deliver do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:group) { create(:error_group, project: project) }
  let(:account) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
  end
  let(:rule) { create(:alerting_rule, organization: organization, event_type: :error_new) }
  let(:content) { Alerting::Content.new(title: "Titolo", body: "Corpo", url: "/x", project: project) }

  def call(dedup_key: "in_app:1")
    described_class.in_app(rule: rule, account: account, event_type: "error_new",
                         subject: group, content: content, dedup_key: dedup_key)
  end

  it "consegna in-app → Result.ok con la notifica (via in_app, regola valorizzata)" do
    result = call
    expect(result).to be_ok
    expect(result.value.via_in_app?).to be(true)
    expect(result.value.rule).to eq(rule)
  end

  it "duplicato sulla dedup_key (save = false per uniqueness) → Result.err(:duplicate)" do
    call
    expect(call).to be_err
  end

  it "race concorrente: save solleva RecordNotUnique → Result.err(:duplicate) (rescue)" do
    allow_any_instance_of(Alerting::Notification).to receive(:save).and_raise(ActiveRecord::RecordNotUnique)

    result = call

    expect(result).to be_err
    expect(result.error).to eq(:duplicate)
  end
end
