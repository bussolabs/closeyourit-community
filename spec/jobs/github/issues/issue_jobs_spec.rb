# frozen_string_literal: true

require "rails_helper"

# CYRA-1055 — the issue jobs: a record gone does nothing, a refusal from GitHub is logged and not
# retried, a broken channel is raised so the queue retries it.
RSpec.describe "Github::Issues jobs", type: :job do
  let(:refused) { Github::Client::Error.new("not found", code: "R404-GITHUB-010", status: :not_found) }
  let(:broken) { Github::Client::Error.new("timeout", code: "R502-GITHUB-001") }

  before { allow(Rails.logger).to receive(:warn) }

  describe Github::Issues::PushJob do
    let(:link) { create(:github_issue) }

    it "does nothing when the ticket is gone" do
      allow(Github::Issues::Push).to receive(:call)

      described_class.perform_now(ticket_id: SecureRandom.uuid)

      expect(Github::Issues::Push).not_to have_received(:call)
    end

    it "pushes the ticket" do
      allow(Github::Issues::Push).to receive(:call)

      described_class.perform_now(ticket_id: link.ticket_id)

      expect(Github::Issues::Push).to have_received(:call).with(ticket: link.ticket)
    end

    it "logs a refusal from GitHub without retrying" do
      allow(Github::Issues::Push).to receive(:call).and_raise(refused)

      expect { described_class.perform_now(ticket_id: link.ticket_id) }.not_to raise_error
      expect(Rails.logger).to have_received(:warn).with(a_string_including("[github.issues.push]", "R404-GITHUB-010"))
    end

    it "requeues the ticket when the channel is broken" do
      allow(Github::Issues::Push).to receive(:call).and_raise(broken)

      expect { described_class.perform_now(ticket_id: link.ticket_id) }
        .to have_enqueued_job(described_class).with(ticket_id: link.ticket_id).exactly(:once)
    end
  end

  describe Github::Issues::PushCommentJob do
    let(:link) { create(:github_issue) }
    let(:comment) { create(:ticket_comment, ticket: link.ticket, author: link.ticket.reporter) }

    it "does nothing when the comment is gone" do
      allow(Github::Issues::PushComment).to receive(:call)

      described_class.perform_now(comment_id: SecureRandom.uuid)

      expect(Github::Issues::PushComment).not_to have_received(:call)
    end

    it "sends the comment" do
      allow(Github::Issues::PushComment).to receive(:call)

      described_class.perform_now(comment_id: comment.id)

      expect(Github::Issues::PushComment).to have_received(:call).with(comment:)
    end

    it "logs a refusal from GitHub without retrying" do
      allow(Github::Issues::PushComment).to receive(:call).and_raise(refused)

      expect { described_class.perform_now(comment_id: comment.id) }.not_to raise_error
      expect(Rails.logger).to have_received(:warn).with(a_string_including("[github.issues.comment]"))
    end

    it "requeues the comment when the channel is broken" do
      allow(Github::Issues::PushComment).to receive(:call).and_raise(broken)

      expect { described_class.perform_now(comment_id: comment.id) }
        .to have_enqueued_job(described_class).with(comment_id: comment.id).exactly(:once)
    end
  end

  describe Github::Issues::DeleteCommentJob do
    let(:link) { create(:github_issue) }
    let(:client) { instance_double(Github::Client) }

    before { allow(Github::Client).to receive(:new).and_return(client) }

    it "does nothing when the ticket has no issue" do
      allow(client).to receive(:delete_issue_comment)

      described_class.perform_now(ticket_id: SecureRandom.uuid, github_comment_id: 9)

      expect(client).not_to have_received(:delete_issue_comment)
    end

    it "deletes the twin comment on the issue" do
      allow(client).to receive(:delete_issue_comment)

      described_class.perform_now(ticket_id: link.ticket_id, github_comment_id: 9)

      expect(client).to have_received(:delete_issue_comment)
        .with(link.repository.github_installation_id, link.repository.full_name, 9)
    end

    it "logs a refusal from GitHub without retrying" do
      allow(client).to receive(:delete_issue_comment).and_raise(refused)

      expect { described_class.perform_now(ticket_id: link.ticket_id, github_comment_id: 9) }.not_to raise_error
      expect(Rails.logger).to have_received(:warn).with(a_string_including("[github.issues.comment_delete]"))
    end

    it "requeues the deletion when the channel is broken" do
      allow(client).to receive(:delete_issue_comment).and_raise(broken)

      expect { described_class.perform_now(ticket_id: link.ticket_id, github_comment_id: 9) }
        .to have_enqueued_job(described_class).with(ticket_id: link.ticket_id, github_comment_id: 9).exactly(:once)
    end
  end

  describe Github::Issues::ReconcileRepositoryJob do
    let(:repository) { create(:github_repository, issue_sync: :all_issues) }

    it "does nothing when the repository is gone" do
      allow(Github::Issues::Reconcile).to receive(:call)

      described_class.perform_now(repository_id: SecureRandom.uuid)

      expect(Github::Issues::Reconcile).not_to have_received(:call)
    end

    it "checks the repository" do
      allow(Github::Issues::Reconcile).to receive(:call)

      described_class.perform_now(repository_id: repository.id)

      expect(Github::Issues::Reconcile).to have_received(:call).with(repository:)
    end

    it "logs a refusal from GitHub without retrying" do
      allow(Github::Issues::Reconcile).to receive(:call).and_raise(refused)

      expect { described_class.perform_now(repository_id: repository.id) }.not_to raise_error
      expect(Rails.logger).to have_received(:warn).with(a_string_including("[github.issues.reconcile]"))
    end

    it "requeues the repository when the channel is broken" do
      allow(Github::Issues::Reconcile).to receive(:call).and_raise(broken)

      expect { described_class.perform_now(repository_id: repository.id) }
        .to have_enqueued_job(described_class).with(repository_id: repository.id).exactly(:once)
    end
  end

  describe Github::Issues::ReconcileJob do
    it "queues one check per repository whose issues are synced" do
      synced = create(:github_repository, issue_sync: :all_issues)
      create(:github_repository, issue_sync: :off)

      expect { described_class.perform_now }
        .to have_enqueued_job(Github::Issues::ReconcileRepositoryJob).with(repository_id: synced.id).exactly(:once)
    end
  end

  describe Github::Issues::FirstImportJob do
    let(:repository) { create(:github_repository, issue_sync: :all_issues) }

    it "does nothing when the repository is gone" do
      allow(Github::Issues::FirstImport).to receive(:call)

      described_class.perform_now(repository_id: SecureRandom.uuid)

      expect(Github::Issues::FirstImport).not_to have_received(:call)
    end

    it "queues the next page while there is more to read" do
      allow(Github::Issues::FirstImport).to receive(:call).and_return(Result.ok(2))

      expect { described_class.perform_now(repository_id: repository.id) }
        .to have_enqueued_job(described_class).with(repository_id: repository.id, page: 2)
    end

    it "stops after the last page" do
      allow(Github::Issues::FirstImport).to receive(:call).and_return(Result.ok(nil))

      expect { described_class.perform_now(repository_id: repository.id, page: 3) }
        .not_to have_enqueued_job(described_class)
    end
  end

  describe Github::Issues::EventJob do
    it "ignores an event it does not handle" do
      expect(described_class.perform_now(event: "push", payload: {}, key: "I_1")).to be_nil
    end
  end
end
