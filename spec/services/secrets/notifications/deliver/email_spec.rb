# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Notifications::Deliver do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:variable) { create(:secret_variable, project: project) }
  let(:account) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
  end
  let(:content) { Secrets::Notifications::Content.new(title: "Titolo", body: "Corpo", url: "/member/vault/rotation") }

  def call(dedup_key: "email:1", quiet: false, bucket: nil)
    described_class.email(account: account, variable: variable, organization: organization,
                         event_type: :secret_rotation_due, content: content, dedup_key: dedup_key,
                         quiet: quiet, bucket: bucket)
  end

  it "consegna email → Result.ok, accoda il mailer e lascia la riga :pending (CYRA-672)" do
    result = nil
    expect { result = call }.to have_enqueued_mail(Secrets::SecretNotificationsMailer, :notify)
    expect(result).to be_ok
    expect(result.value.status_pending?).to be(true)
  end

  it "quiet hours → notifica trattenuta (:held), nessuna mail accodata" do
    result = nil
    expect { result = call(quiet: true) }.not_to have_enqueued_mail(Secrets::SecretNotificationsMailer, :notify)
    expect(result).to be_ok
    expect(result.value.status_held?).to be(true)
  end

  it "bucket presente (cadenza daily/weekly) → notifica :queued, nessuna mail immediata" do
    result = nil
    expect { result = call(bucket: :daily) }.not_to have_enqueued_mail(Secrets::SecretNotificationsMailer, :notify)
    expect(result).to be_ok
    expect(result.value.status_queued?).to be(true)
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
      result = nil
      expect do
        result = described_class.email(
          account: account, subject: project, project: project, organization: organization,
          event_type: :secret_sync_failed, content: content, dedup_key: "email:generic"
        )
      end.to have_enqueued_mail(Secrets::SecretNotificationsMailer, :notify)

      expect(result).to be_ok
      expect(result.value.subject).to eq(project)
      expect(result.value.project).to eq(project)
    end
  end
end
