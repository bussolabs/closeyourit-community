# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::Notification, type: :model do
  describe "factory" do
    it "produce un record valido" do
      expect(build(:alerting_notification)).to be_valid
    end
  end

  describe "validazioni" do
    it "richiede il titolo" do
      expect(build(:alerting_notification, title: "")).not_to be_valid
    end

    it "richiede la dedup_key" do
      expect(build(:alerting_notification, dedup_key: "")).not_to be_valid
    end

    it "richiede il subject (polimorfico)" do
      expect(build(:alerting_notification, subject: nil)).not_to be_valid
    end
  end

  describe "anti-spam: unicità [rule_id, dedup_key]" do
    it "rifiuta una seconda notifica con stessa regola e stessa dedup_key" do
      rule = create(:alerting_rule)
      create(:alerting_notification, rule: rule, dedup_key: "same")
      dup = build(:alerting_notification, rule: rule, dedup_key: "same")
      expect(dup).not_to be_valid
    end

    it "consente la stessa dedup_key su regole diverse" do
      create(:alerting_notification, rule: create(:alerting_rule), dedup_key: "same")
      other = build(:alerting_notification, rule: create(:alerting_rule), dedup_key: "same")
      expect(other).to be_valid
    end
  end

  describe "enum" do
    it "via in_app/email/telegram" do
      expect(described_class.via.keys).to contain_exactly("in_app", "email", "telegram")
    end

    it "status pending/sent/failed/skipped/queued/held" do
      expect(described_class.statuses.keys).to contain_exactly("pending", "sent", "failed", "skipped", "queued", "held")
    end

    it "digest_bucket daily/weekly (nil sulle righe immediate)" do
      expect(described_class.digest_buckets.keys).to contain_exactly("daily", "weekly")
    end

    it "gli event_type chat hanno valori interi stabili (appesi, mai riordinare)" do
      expect(described_class.event_types["chat_message"]).to eq(12)
      expect(described_class.event_types["chat_mentioned"]).to eq(13)
    end

    it "l'event_type secret_rotation_due ha un valore intero stabile (appeso, mai riordinare)" do
      expect(described_class.event_types["secret_rotation_due"]).to eq(28)
    end

    it "gli event_type secret_deleted/secret_sync_failed hanno valori interi stabili (appesi dopo secret_rotation_due)" do
      expect(described_class.event_types["secret_deleted"]).to eq(29)
      expect(described_class.event_types["secret_sync_failed"]).to eq(30)
    end

    it "gli event_type secret_change_requested/approved/rejected hanno valori interi stabili " \
       "(appesi dopo secret_sync_failed)" do
      expect(described_class.event_types["secret_change_requested"]).to eq(31)
      expect(described_class.event_types["secret_change_approved"]).to eq(32)
      expect(described_class.event_types["secret_change_rejected"]).to eq(33)
    end

    it "gli event_type database del server hanno valori interi stabili (appesi dopo secret_change_rejected)" do
      expect(described_class.event_types["server_db_down"]).to eq(34)
      expect(described_class.event_types["server_db_connections"]).to eq(35)
      expect(described_class.event_types["server_replication_lag"]).to eq(36)
    end

    it "l'event_type agents_stalled ha un valore intero stabile (appeso dopo server_replication_lag)" do
      expect(described_class.event_types["agents_stalled"]).to eq(37)
    end

    it "l'event_type server_container_down ha un valore intero stabile (appeso dopo agents_stalled)" do
      expect(described_class.event_types["server_container_down"]).to eq(38)
    end


    it "gli eventi di capacità e recovery sono appesi dopo server_container_up" do
      expect(described_class.event_types).to include(
        "server_db_connection_usage" => 53, "server_data_volume_disk" => 54, "server_inode" => 55,
        "server_replication_down" => 56, "server_replication_up" => 57,
        "server_container_restart_loop" => 58, "server_container_stable" => 59
      )
    end
  end

  describe "#read? e #mark_read!" do
    it "una notifica non letta diventa letta" do
      notification = create(:alerting_notification, :unread)
      expect(notification).not_to be_read
      freeze_time do
        notification.mark_read!
        expect(notification.read_at).to eq(Time.current)
      end
      expect(notification.reload).to be_read
    end

    it "mark_read! è idempotente: non sposta read_at se già letta" do
      first = 2.hours.ago
      notification = create(:alerting_notification, read_at: first)
      notification.mark_read!
      expect(notification.reload.read_at).to be_within(1.second).of(first)
    end
  end

  describe "scope .unread" do
    it "include solo le non lette" do
      unread = create(:alerting_notification, :unread)
      read = create(:alerting_notification, :read)
      expect(described_class.unread).to include(unread)
      expect(described_class.unread).not_to include(read)
    end
  end

  describe "#url, composed from the subject" do
    let(:routes) { Rails.application.routes.url_helpers }

    def notification(event_type, subject, project: nil)
      described_class.new(event_type:, subject:, project:, url: "/member/old_path")
    end

    it "follows the current pages for tickets, chat, secrets and ingest credentials" do
      ticket = create(:ticket)
      message = create(:chat_message)
      variable = create(:secret_variable)
      token = create(:project_token)
      project = token.project

      expect(notification(:ticket_assigned, ticket).url).to eq(routes.member_ticket_path(ticket))
      expect(notification(:chat_mentioned, message).url).to eq(routes.member_chat_conversation_path(message.conversation))
      expect(notification(:secret_rotation_due, variable).url).to eq(routes.member_vault_attention_path)
      expect(notification(:secret_deleted, project, project:).url).to eq(routes.member_project_secrets_path(project))
      expect(notification(:secret_sync_failed, project, project:).url).to eq(routes.member_project_github_path(project))
      expect(notification(:secret_change_requested, project, project:).url).to eq(routes.member_vault_attention_path)
      expect(notification(:project_token_expiring, token, project:).url).to eq(routes.member_project_tokens_path(project))
    end

    it "keeps the stored path when the subject is gone" do
      group = create(:error_group)
      stored = notification(:error_new, group)
      group.destroy!

      expect(described_class.new(event_type: :error_new, subject_type: "Errors::Group", subject_id: group.id,
                                 url: "/member/old_path").url).to eq("/member/old_path")
      expect(stored.subject_id).to eq(group.id)
    end
  end
end
