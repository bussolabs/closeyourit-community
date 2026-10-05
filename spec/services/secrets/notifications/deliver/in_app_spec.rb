# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Notifications::Deliver do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:variable) { create(:secret_variable, project: project) }
  let(:account) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
  end
  let(:content) { Secrets::Notifications::Content.new(title: "Titolo", body: "Corpo", url: "/member/vault/rotation") }

  def call(dedup_key: "in_app:1")
    described_class.in_app(account: account, variable: variable, organization: organization,
                         event_type: :secret_rotation_due, content: content, dedup_key: dedup_key)
  end

  it "consegna in-app → Result.ok con la notifica creata (via in_app, rule nil, subject = variabile)" do
    result = call
    expect(result).to be_ok
    notification = result.value
    expect(notification).to be_a(Alerting::Notification)
    expect(notification.via_in_app?).to be(true)
    expect(notification.subject).to eq(variable)
    expect(notification.project).to eq(project)
    expect(notification.rule_id).to be_nil
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

  describe "subject/project generico (CYRA-138 Fase B: eventi senza una variabile viva)" do
    it "accetta subject:/project: espliciti (es. il progetto, per secret_deleted/secret_sync_failed)" do
      result = described_class.in_app(
        account: account, subject: project, project: project, organization: organization,
        event_type: :secret_deleted, content: content, dedup_key: "in_app:generic"
      )

      expect(result).to be_ok
      notification = result.value
      expect(notification.subject).to eq(project)
      expect(notification.project).to eq(project)
      expect(notification.rule_id).to be_nil
    end
  end
end
